"""Durable content-addressed directory inventory publication."""
import datetime
import gzip
import hashlib
import json
import os
import contextlib
import tempfile
import heapq
from pathlib import Path

SCHEMA_VERSION = 1
MAX_CHUNK_RAW_BYTES = 1024 * 1024
MAX_DAILY_COMPRESSED_BYTES = 32 * 1024 * 1024  # unique compressed objects admitted per UTC day
MAX_STORE_BYTES = int(0.8 * 2 * 1024 * 1024 * 1024)
MAX_INDEX_BYTES = 256 * 1024 * 1024
MAX_METADATA_BYTES = 512 * 1024 * 1024
MEASUREMENT_RETENTION_DAYS = 35
IDENTITY_RETENTION_DAYS = 90


def _canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()


def _sha(data):
    return hashlib.sha256(data).hexdigest()


def _atomic(path, data, failure_hook=None, stage="write"):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix=".stage-", dir=str(path.parent))
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        if failure_hook:
            failure_hook(stage + ".staged")
        os.replace(name, path)
        dfd = os.open(str(path.parent), os.O_RDONLY)
        try:
            os.fsync(dfd)
        finally:
            os.close(dfd)
        if failure_hook:
            failure_hook(stage + ".published")
    except BaseException:
        # A staged file is harmless and never referenced by current.json.
        raise


def _record(record):
    r = dict(record)
    r.setdefault("path_generation", {"id": None, "status": "uncertain"})
    r.setdefault("observation", {})
    o = r["observation"]
    o.setdefault("allocated_bytes", None)
    o.setdefault("apparent_bytes", None)
    o.setdefault("size_semantics", "inclusive")
    o.setdefault("measurement_status", "unknown")
    o.setdefault("subtree_coverage_status", "unknown")
    o.setdefault("comparable", False)
    r.setdefault("attribution", {"basis": "unknown", "capability": "unknown", "comparability": "unknown", "reason": None})
    if not isinstance(r.get("canonical_path"), str) or not r["canonical_path"].startswith("/"):
        raise ValueError("canonical_path must be an absolute path")
    return r


def _stage_inventory_chunks(records, objects, indexes):
    """Write bounded, independently hashed measurement/identity/index chunks."""
    chunks=[]; batch=[]; raw_size=0
    def flush():
        nonlocal batch, raw_size
        if not batch and chunks: return
        fd, name=tempfile.mkstemp(prefix=".stage-", dir=str(objects)); measurement_stage=Path(name)
        raw_bytes=b"".join(item[0] for item in batch)
        with os.fdopen(fd,"wb") as raw:
            with gzip.GzipFile(fileobj=raw,mode="wb",mtime=0) as gz: gz.write(raw_bytes)
            raw.flush(); os.fsync(raw.fileno())
        measurement_sha=_file_sha(measurement_stage)
        identity_rows=[{"filesystem_id":r.get("filesystem_id"),"canonical_path":r["canonical_path"],"path_generation":r["path_generation"]} for _,r in batch]
        identity_data=_canonical(identity_rows); identity_sha=_sha(identity_data)
        measurement_index={"schema_version":SCHEMA_VERSION,"records":[{"filesystem_id":r.get("filesystem_id"),"canonical_path":r["canonical_path"],"measurement_object_sha256":measurement_sha,"identity_object_sha256":identity_sha} for _,r in batch]}
        measurement_index_data=_canonical(measurement_index); measurement_index_sha=_sha(measurement_index_data)
        identity_index={"schema_version":SCHEMA_VERSION,"records":[{"filesystem_id":r.get("filesystem_id"),"canonical_path":r["canonical_path"],"path_generation":r["path_generation"],"identity_object_sha256":identity_sha} for _,r in batch]}
        identity_index_data=_canonical(identity_index); identity_index_sha=_sha(identity_index_data)
        chunks.append({"measurement_sha256":measurement_sha,"measurement_raw_bytes":len(raw_bytes),"measurement_compressed_bytes":measurement_stage.stat().st_size,"row_count":len(batch),"identity_sha256":identity_sha,"measurement_index_sha256":measurement_index_sha,"identity_index_sha256":identity_index_sha,"measurement_stage":measurement_stage,"identity_stage":identity_data,"measurement_index_stage":measurement_index_data,"identity_index_stage":identity_index_data})
        batch=[]; raw_size=0
    for record in records:
        row=_canonical(record)+b"\n"
        if batch and raw_size+len(row)>MAX_CHUNK_RAW_BYTES: flush()
        batch.append((row,record)); raw_size+=len(row)
    flush()
    return chunks


def _file_sha(path):
    digest=hashlib.sha256()
    with Path(path).open("rb") as stream:
        for block in iter(lambda:stream.read(1024*1024),b""): digest.update(block)
    return digest.hexdigest()


def _external_sorted_records(records, spool_dir, *, run_bytes=4 * 1024 * 1024):
    """Normalize and sort records using bounded in-memory runs on disk."""
    spool = tempfile.TemporaryDirectory(prefix="inventory-sort-", dir=spool_dir)
    root = Path(spool.name)
    runs = []
    batch = []
    batch_bytes = 0
    count = 0
    serialized_bytes = 0

    def flush():
        nonlocal batch, batch_bytes
        if not batch:
            return
        batch.sort(key=lambda item: item[0])
        run = root / ("run-%06d.jsonl" % len(runs))
        with run.open("wb") as stream:
            for _, encoded in batch:
                stream.write(encoded)
                stream.write(b"\n")
            stream.flush()
            os.fsync(stream.fileno())
        runs.append(run)
        batch = []
        batch_bytes = 0

    for source_record in records:
        record = _record(source_record)
        encoded = _canonical(record)
        serialized_bytes += len(encoded) + 1
        count += 1
        batch.append(((record.get("filesystem_id") or "", record["canonical_path"]), encoded))
        batch_bytes += len(encoded) + 1
        if batch_bytes >= run_bytes:
            flush()
    flush()

    def merged():
        streams = [path.open("rb") for path in runs]
        heap = []
        try:
            for index, stream in enumerate(streams):
                line = stream.readline()
                if line:
                    record = json.loads(line)
                    key = (record.get("filesystem_id") or "", record["canonical_path"])
                    heapq.heappush(heap, (key, index, record))
            while heap:
                _, index, record = heapq.heappop(heap)
                yield record
                line = streams[index].readline()
                if line:
                    following = json.loads(line)
                    key = (following.get("filesystem_id") or "", following["canonical_path"])
                    heapq.heappush(heap, (key, index, following))
        finally:
            for stream in streams:
                stream.close()

    return spool, merged(), count, serialized_bytes


class PublicationResult(dict):
    """JSON-compatible publication receipt."""


def validate_state_separation(state_dir, git_state_repo):
    state=Path(state_dir).expanduser().resolve(); repo=Path(git_state_repo).expanduser().resolve()
    if state==repo or repo in state.parents or state in repo.parents: raise ValueError("inventory state must be separate from Git state repository")
    return True

@contextlib.contextmanager
def publication_lock(state_dir, *, blocking=True):
    import fcntl
    inv=Path(state_dir).expanduser().resolve()/"inventory"; inv.mkdir(parents=True,exist_ok=True)
    with open(inv/"publish.lock","a+b") as lock:
        fcntl.flock(lock.fileno(),fcntl.LOCK_EX|(0 if blocking else fcntl.LOCK_NB))
        try: yield lock
        finally: fcntl.flock(lock.fileno(),fcntl.LOCK_UN)



class InventoryAdmissionError(RuntimeError):
    def __init__(self, report):
        self.report = report
        super().__init__("inventory admission blocked: " + str(report.get("reason")))


def _physical_tree(path, *, grace_after=None, exclude_paths=()):
    total = 0
    selected = 0
    stack = [Path(path)]
    seen_inodes = set()
    while stack:
        directory = stack.pop()
        if directory in exclude_paths:
            continue
        try:
            entries = list(os.scandir(directory))
        except OSError as exc:
            raise ValueError("unreadable inventory quota path: " + str(directory)) from exc
        for entry in entries:
            p = Path(entry.path)
            st = entry.stat(follow_symlinks=False)
            if entry.is_symlink():
                raise ValueError("symlink in inventory quota path: " + str(p))
            if entry.is_dir(follow_symlinks=False):
                stack.append(p)
            elif entry.is_file(follow_symlinks=False):
                inode_key = (st.st_dev, st.st_ino)
                if inode_key in seen_inodes:
                    continue
                seen_inodes.add(inode_key)
                allocated = int(getattr(st, "st_blocks", 0)) * 512
                if not allocated:
                    allocated = int(st.st_size)
                total += allocated
                if grace_after is not None and st.st_mtime >= grace_after:
                    selected += allocated
    return total, selected


def inventory_quota_status(*, aggregate_roots=None, now=None, low_space_bytes=0, prospective_bytes=0, prospective_index_bytes=0, prospective_metadata_bytes=0):
    """Measure physical blocks across fixed root, user, and spool stores.

    Aggregate roots must be passed as {"root": ..., "user": ..., "spool": ...}.
    Missing, overlapping, unreadable, or symlinked roots fail closed.
    """
    report = {"status": "report_only", "admission_allowed": False,
              "reason": "aggregate_roots_unknown", "physical_bytes": None,
              "index_bytes": None, "metadata_grace_bytes": None,
              "domains": {}}
    if not isinstance(aggregate_roots, dict) or set(aggregate_roots) != {"root", "user", "spool"}:
        return report
    try:
        roots = {name: Path(value).expanduser() for name, value in aggregate_roots.items()}
        if any(p.is_symlink() or not p.is_dir() for p in roots.values()):
            raise ValueError("aggregate root missing or symlinked")
        resolved = {name: p.resolve(strict=True) for name,p in roots.items()}
        values = list(resolved.values())
        for i, first in enumerate(values):
            for second in values[i+1:]:
                if first == second:
                    raise ValueError("aggregate roots overlap")
        # The fixed root store may contain its bounded spool. Count the spool once,
        # as a separate domain, while excluding it from the root-store walk.
        # The only permitted overlap is the spool nested inside the fixed root.
        # User state must stay disjoint from both domains.
        root_contains_spool = resolved["root"] in resolved["spool"].parents
        for name in ("root", "spool"):
            path = resolved[name]
            if resolved["user"] in path.parents or path in resolved["user"].parents:
                raise ValueError("user inventory root overlaps fixed root or spool")
        if not root_contains_spool and (
            resolved["spool"] in resolved["root"].parents
            or resolved["root"] in resolved["spool"].parents
        ):
            raise ValueError("aggregate roots overlap outside the fixed root spool")
        total = indexes = metadata = grace = 0
        cutoff = (now or datetime.datetime.now(datetime.timezone.utc)).timestamp() - 86400
        domains = {}
        for name, root in resolved.items():
            excluded = (resolved["spool"],) if name == "root" and resolved["root"] in resolved["spool"].parents else ()
            blocks, _ = _physical_tree(root, exclude_paths=excluded)
            total += blocks
            domain = {"physical_bytes": blocks}
            domains[name] = domain
            inventory = root / "inventory"
            if name != "spool" and inventory.exists():
                if inventory.is_symlink() or not inventory.is_dir():
                    raise ValueError("inventory subtree is not a real directory")
                idx = inventory / "indexes"
                manifests = inventory / "manifests"
                pins = inventory / "pins"
                if idx.exists(): indexes += _physical_tree(idx)[0]
                meta_bytes = 0
                for p in (manifests, pins):
                    if p.exists(): meta_bytes += _physical_tree(p)[0]
                # Include 24-hour grace/staging files and recently allocated immutable objects.
                objects = inventory / "objects"
                object_grace = _physical_tree(objects, grace_after=cutoff)[1] if objects.exists() else 0
                staged_bytes = 0
                for base, _, files in os.walk(inventory, followlinks=False):
                    for filename in files:
                        if filename.startswith(".stage-"):
                            fp = Path(base) / filename
                            st = fp.lstat()
                            if fp.is_symlink(): raise ValueError("staging symlink in inventory quota path")
                            staged_bytes += int(getattr(st, "st_blocks", 0))*512 or int(st.st_size)
                metadata += meta_bytes + object_grace + staged_bytes
                domain["index_bytes"] = _physical_tree(idx)[0] if idx.exists() else 0
                domain["metadata_grace_bytes"] = meta_bytes + object_grace + staged_bytes
            elif name == "spool":
                metadata += blocks
                domain["metadata_grace_bytes"] = blocks
        report.update(status="measured", admission_allowed=True, reason=None,
                      physical_bytes=total, index_bytes=indexes,
                      metadata_grace_bytes=metadata, domains=domains)
        # Include filesystem allocation rounding and the duplicate staging copy
        # that exists while immutable destinations are being atomically installed.
        block = 4096
        prospective = ((int(prospective_bytes) + block - 1) // block) * block
        staged_high_water = prospective * 2
        if total + staged_high_water > MAX_STORE_BYTES:
            report.update(admission_allowed=False, status="blocked", reason="prospective_total_high_water_exceeds_80pct")
        elif indexes + int(prospective_index_bytes) > MAX_INDEX_BYTES:
            report.update(admission_allowed=False, status="blocked", reason="prospective_index_sublimit_exceeded")
        elif metadata + int(prospective_metadata_bytes) > MAX_METADATA_BYTES:
            report.update(admission_allowed=False, status="blocked", reason="prospective_metadata_sublimit_exceeded")
        elif low_space_bytes and any(os.statvfs(p).f_bavail * os.statvfs(p).f_frsize < low_space_bytes for p in values):
            report.update(admission_allowed=False, status="blocked", reason="low_space_threshold")
    except (OSError, ValueError) as exc:
        report.update(status="report_only", admission_allowed=False, reason="aggregate_unavailable",
                      detail=str(exc), physical_bytes=None, index_bytes=None,
                      metadata_grace_bytes=None, domains={})
    return report


def publish_inventory(records, *, state_dir, git_state_repo=None, complete=False,
                      unresolved_frontier=None, scan_metadata=None, now=None,
                      failure_hook=None, merge_existing=False, merge_policy='incoming_wins',
                      require_admission=False, aggregate_roots=None, low_space_bytes=0):
    state = Path(state_dir).expanduser().resolve()
    if require_admission:
        quota = inventory_quota_status(aggregate_roots=aggregate_roots, low_space_bytes=low_space_bytes)
        if not quota["admission_allowed"]:
            raise InventoryAdmissionError(quota)
        if Path(aggregate_roots["user"]).expanduser().resolve() != state:
            raise InventoryAdmissionError({"status":"report_only","admission_allowed":False,
                "reason":"user_state_root_mismatch"})
        raise InventoryAdmissionError({"status":"report_only","admission_allowed":False,
            "reason":"cross_domain_concurrency_unproven",
            "detail":"root and user inventory trust domains cannot share a writable quota lock"})
    if git_state_repo:
        validate_state_separation(state, git_state_repo)
    inventory = state / "inventory"
    objects, manifests, indexes = (inventory / n for n in ("objects", "manifests", "indexes"))
    inventory.mkdir(parents=True, exist_ok=True)
    sort_spool, normalized, normalized_count, serialized_bytes = _external_sorted_records(records, inventory)
    lock_path = inventory / "publish.lock"
    with publication_lock(state):
        if merge_existing and (inventory / "current.json").exists():
            if merge_policy not in ("incoming_wins", "existing_wins"):
                raise ValueError("unsupported inventory merge policy")
            pointer = json.loads((inventory / "current.json").read_bytes())
            current_sha = _validated_sha(pointer.get("manifest_sha256"))
            current_manifest = read_manifest(state, current_sha)
            if bool(pointer.get("complete")) != bool(current_manifest.get("complete")):
                raise ValueError("pointer/manifest completeness mismatch")
            prior_records = iter(iter_publication_records(state, current_sha))
            incoming_records = iter(normalized)
            prior = next(prior_records, None)
            incoming = next(incoming_records, None)
            merged_count = [0]

            def merge_sorted_records():
                prior_row, incoming_row = prior, incoming
                while prior_row is not None or incoming_row is not None:
                    prior_key = ((prior_row.get("filesystem_id") or "", prior_row["canonical_path"])
                                 if prior_row is not None else None)
                    incoming_key = ((incoming_row.get("filesystem_id") or "", incoming_row["canonical_path"])
                                    if incoming_row is not None else None)
                    if prior_row is None:
                        selected = incoming_row
                        incoming_row = next(incoming_records, None)
                    elif incoming_row is None:
                        selected = prior_row
                        prior_row = next(prior_records, None)
                    elif prior_key < incoming_key:
                        selected = prior_row
                        prior_row = next(prior_records, None)
                    elif incoming_key < prior_key:
                        selected = incoming_row
                        incoming_row = next(incoming_records, None)
                    elif merge_policy == "incoming_wins":
                        selected = incoming_row
                        prior_row = next(prior_records, None)
                        incoming_row = next(incoming_records, None)
                    else:
                        selected = prior_row
                        prior_row = next(prior_records, None)
                        incoming_row = next(incoming_records, None)
                    merged_count[0] += 1
                    yield selected

            normalized = merge_sorted_records()
            normalized_count = None
            serialized_bytes = None
            prior_metadata = current_manifest.get("scan_metadata", {})
            incoming_metadata = scan_metadata or {}
            scan_metadata = dict(prior_metadata)
            scan_metadata.update({k: v for k, v in incoming_metadata.items() if k != "provenance"})
            prior_provenance = prior_metadata.get("provenance") or {}
            incoming_provenance = incoming_metadata.get("provenance") or {}
            provenance = dict(prior_provenance)
            provenance.update({k: v for k, v in incoming_provenance.items() if k != "historical_events"})
            events_by_key = {}
            for event in [*prior_provenance.get("historical_events", []), *incoming_provenance.get("historical_events", [])]:
                event_id = event.get("event_id")
                import_row_key = event.get("import_row_key")
                dedupe_key = ("event", event_id) if event_id is not None else ("import", import_row_key) if import_row_key is not None else None
                if dedupe_key is None:
                    # Unkeyed rows cannot be safely deduplicated; preserve them as supplied.
                    dedupe_key = ("unkeyed", len(events_by_key), _sha(_canonical(event)))
                events_by_key[dedupe_key] = event
            provenance["historical_events"] = sorted(events_by_key.values(), key=lambda e: (str(e.get("event_id", "")), str(e.get("import_row_key", "")), _canonical(e)))
            if provenance:
                scan_metadata["provenance"] = provenance
        objects.mkdir(parents=True, exist_ok=True)
        chunks = _stage_inventory_chunks(normalized, objects, indexes)
        sort_spool.cleanup()
        if normalized_count is None:
            normalized_count = merged_count[0]
        measured_bytes = sum(chunk["measurement_raw_bytes"] for chunk in chunks)
        compressed_size = sum(chunk["measurement_compressed_bytes"] for chunk in chunks)
        object_sha = chunks[0]["measurement_sha256"]
        index_sha = chunks[0]["measurement_index_sha256"]
        event_sha = chunks[0]["identity_sha256"]
        identity_index_sha = chunks[0]["identity_index_sha256"]
        staged_graph = []
        for chunk in chunks:
            staged_graph.extend([
                (objects / (chunk["measurement_sha256"] + ".jsonl.gz"), chunk["measurement_stage"], "object"),
                (objects / (chunk["identity_sha256"] + ".identity.json"), chunk["identity_stage"], "identity"),
                (indexes / (chunk["measurement_index_sha256"] + ".json"), chunk["measurement_index_stage"], "index"),
                (indexes / (chunk["identity_index_sha256"] + ".identity.json"), chunk["identity_index_stage"], "identity_index"),
            ])
        timestamp = now or datetime.datetime.now(datetime.timezone.utc).isoformat()
        unresolved = sorted(set(unresolved_frontier or []))
        if complete and unresolved:
            raise ValueError("complete inventory cannot have unresolved frontier")
        if not complete and not unresolved:
            unresolved = ["/"]
        manifest = {"schema_version": SCHEMA_VERSION, "published_at": timestamp,
                    "complete": bool(complete), "unresolved_frontier": unresolved,
                    "records_count": normalized_count, "selected_filesystems": (scan_metadata or {}).get("selected_filesystems", []),
                    "measurement_manifest_sha256": object_sha, "measurement_index_sha256": index_sha,
                    "identity_event_manifest_sha256": event_sha, "identity_event_index_sha256": identity_index_sha,
                    "measurement_bytes": measured_bytes, "measurement_compressed_bytes": compressed_size,
                    "chunks": [{k: v for k, v in chunk.items() if not k.endswith("_stage")} for chunk in chunks],
                    "scan_metadata": scan_metadata or {},
                    "provenance": scan_metadata.get("provenance") if scan_metadata else None}
        manifest_data = _canonical(manifest)
        manifest_sha = _sha(manifest_data)
        manifest_path = manifests / (manifest_sha + ".json")
        # Account for the complete chunk graph before writing any immutable object.
        manifest_data = _canonical(manifest)
        manifest_sha = _sha(manifest_data)
        manifest_path = manifests / (manifest_sha + ".json")
        graph = [(path, staged, stage) for path, staged, stage in staged_graph]
        graph.append((manifest_path, manifest_data, "manifest"))
        additions = 0
        index_additions = metadata_additions = 0
        for path, staged, _ in graph:
            if not path.exists():
                size = staged.stat().st_size if isinstance(staged, Path) else len(staged)
                additions += size
                if path.parent == indexes: index_additions += size
                if path.parent == manifests: metadata_additions += size
        if require_admission:
            quota = inventory_quota_status(aggregate_roots=aggregate_roots,
                low_space_bytes=low_space_bytes, prospective_bytes=additions,
                prospective_index_bytes=index_additions * 2,
                prospective_metadata_bytes=metadata_additions * 2)
            if not quota["admission_allowed"]: raise InventoryAdmissionError(quota)
        else:
            occupied = sum(item.stat().st_size for item in inventory.rglob("*") if item.is_file())
            if occupied + additions > MAX_STORE_BYTES:
                raise ValueError("inventory store high-water limit exceeded (0.8 x 2 GiB)")
        daily_hashes = set()
        daily_bytes = 0
        for prior_path in manifests.glob("*.json"):
            prior = json.loads(prior_path.read_text())
            if str(prior.get("published_at", ""))[:10] == str(timestamp)[:10]:
                prior_chunks = prior.get("chunks") or [{"measurement_sha256": prior.get("measurement_manifest_sha256"),
                    "measurement_compressed_bytes": prior.get("measurement_compressed_bytes", 0)}]
                for item in prior_chunks:
                    digest = _validated_sha(item.get("measurement_sha256"))
                    if digest not in daily_hashes:
                        daily_hashes.add(digest)
                        daily_bytes += int(item.get("measurement_compressed_bytes", 0))
        for chunk in chunks:
            if chunk["measurement_sha256"] not in daily_hashes:
                daily_hashes.add(chunk["measurement_sha256"])
                daily_bytes += chunk["measurement_compressed_bytes"]
        if daily_bytes > MAX_DAILY_COMPRESSED_BYTES:
            raise ValueError("inventory daily compressed measurement limit exceeded (32 MiB)")
        for path, staged, stage in graph:
            if path.exists(): continue
            if isinstance(staged, Path):
                if failure_hook: failure_hook(stage + ".staged")
                os.replace(staged, path)
                dfd = os.open(str(path.parent), os.O_RDONLY)
                try: os.fsync(dfd)
                finally: os.close(dfd)
                if failure_hook: failure_hook(stage + ".published")
            else:
                _atomic(path, staged, failure_hook, stage)
        for path, staged, stage in graph:
            if stage != "manifest" and _sha(path.read_bytes()) != path.name.split(".")[0]:
                raise ValueError("inventory dependency hash mismatch: " + stage)
        pointer = {"schema_version": SCHEMA_VERSION, "generation": timestamp,
                   "manifest_sha256": manifest_sha, "published_at": timestamp, "complete": bool(complete)}
        _atomic(inventory / "current.json", _canonical(pointer), failure_hook, "pointer")
        return PublicationResult(pointer=pointer, manifest=manifest, records_count=normalized_count)


def read_manifest(state_dir, manifest_sha256, *, verify=True):
    if len(manifest_sha256) != 64 or any(c not in "0123456789abcdef" for c in manifest_sha256):
        raise ValueError("invalid manifest hash")
    inventory = Path(state_dir).expanduser().resolve() / "inventory"
    raw = (inventory / "manifests" / (manifest_sha256 + ".json")).read_bytes()
    if verify and _sha(raw) != manifest_sha256:
        raise ValueError("manifest hash mismatch")
    return json.loads(raw)


def _read_manifest_chunks(inventory, manifest, *, verify=True):
    dependencies = {}
    chunks = manifest.get("chunks")
    if not isinstance(chunks, list) or not chunks:
        chunks = [{"measurement_sha256": manifest.get("measurement_manifest_sha256"),
                   "identity_sha256": manifest.get("identity_event_manifest_sha256"),
                   "measurement_index_sha256": manifest.get("measurement_index_sha256"),
                   "identity_index_sha256": manifest.get("identity_event_index_sha256")}]
    records = []
    for chunk in chunks:
        refs = (("measurement_sha256", "objects", ".jsonl.gz"),
                ("identity_sha256", "objects", ".identity.json"),
                ("measurement_index_sha256", "indexes", ".json"),
                ("identity_index_sha256", "indexes", ".identity.json"))
        for key, directory, suffix in refs:
            digest = _validated_sha(chunk.get(key))
            path = inventory / directory / (digest + suffix)
            if verify and _file_sha(path) != digest:
                legacy_names = {"measurement_sha256": "measurement_manifest_sha256",
                    "identity_sha256": "identity_event_manifest_sha256",
                    "measurement_index_sha256": "measurement_index_sha256",
                    "identity_index_sha256": "identity_event_index_sha256"}
                raise ValueError(legacy_names[key] + " hash mismatch")
            if not dependencies:
                dependencies[key] = path.read_bytes()
        with gzip.open(inventory / "objects" / (chunk["measurement_sha256"] + ".jsonl.gz"), "rb") as stream:
            records.extend(json.loads(line) for line in stream if line.strip())
    return records, dependencies


def _iter_manifest_chunks(inventory, manifest, *, verify=True):
    chunks = manifest.get("chunks")
    dependencies = {}
    if not isinstance(chunks, list) or not chunks:
        chunks = [{"measurement_sha256": manifest.get("measurement_manifest_sha256"),
                   "identity_sha256": manifest.get("identity_event_manifest_sha256"),
                   "measurement_index_sha256": manifest.get("measurement_index_sha256"),
                   "identity_index_sha256": manifest.get("identity_event_index_sha256")}]
    for index, chunk in enumerate(chunks):
        refs = (("measurement_sha256", "objects", ".jsonl.gz"),
                ("identity_sha256", "objects", ".identity.json"),
                ("measurement_index_sha256", "indexes", ".json"),
                ("identity_index_sha256", "indexes", ".identity.json"))
        paths = {}
        for key, directory, suffix in refs:
            digest = _validated_sha(chunk.get(key))
            path = inventory / directory / (digest + suffix)
            if verify and _file_sha(path) != digest:
                legacy_names = {"measurement_sha256": "measurement_manifest_sha256",
                    "identity_sha256": "identity_event_manifest_sha256",
                    "measurement_index_sha256": "measurement_index_sha256",
                    "identity_index_sha256": "identity_event_index_sha256"}
                raise ValueError(legacy_names[key] + " hash mismatch")
            paths[key] = path
            if index == 0:
                dependencies[key] = path.read_bytes()
        import gzip as gzip_module
        with gzip_module.open(paths["measurement_sha256"], "rb") as stream:
            for line in stream:
                if line.strip():
                    yield json.loads(line)
    return dependencies


def iter_publication_records(state_dir, manifest_sha256, *, verify=True):
    """Stream records from one immutable, hash-addressed publication."""
    digest = _validated_sha(manifest_sha256)
    manifest = read_manifest(state_dir, digest, verify=verify)
    inventory = Path(state_dir).expanduser().resolve() / "inventory"
    records = _iter_manifest_chunks(inventory, manifest, verify=verify)
    count = 0
    for record in records:
        count += 1
        yield record
    if count != manifest.get("records_count"):
        raise ValueError("inventory chunk row count mismatch")


def iter_current_records(state_dir, *, verify=True):
    """Stream the publication named by current.json."""
    inventory = Path(state_dir).expanduser().resolve() / "inventory"
    pointer = json.loads((inventory / "current.json").read_bytes())
    digest = _validated_sha(pointer.get("manifest_sha256"))
    manifest = read_manifest(state_dir, digest, verify=verify)
    if verify and bool(pointer.get("complete")) != bool(manifest.get("complete")):
        raise ValueError("pointer/manifest completeness mismatch")
    yield from iter_publication_records(state_dir, digest, verify=verify)



def read_current(state_dir, *, verify=True):
    inventory=Path(state_dir).expanduser().resolve()/"inventory"
    pointer=json.loads((inventory/"current.json").read_bytes())
    digest=_validated_sha(pointer.get("manifest_sha256"))
    manifest=read_manifest(state_dir,digest,verify=verify)
    if verify and bool(pointer.get("complete"))!=bool(manifest.get("complete")):
        raise ValueError("pointer/manifest completeness mismatch")
    records,dependencies=_read_manifest_chunks(inventory,manifest,verify=verify)
    if len(records)!=manifest.get("records_count"):
        raise ValueError("inventory chunk row count mismatch")
    return {"pointer":pointer,"manifest":manifest,"records":records,"dependencies":dependencies}


def read_publication(state_dir, manifest_sha256, *, verify=True):
    """Read an immutable generation by exact manifest hash, never via current."""
    manifest=read_manifest(state_dir,manifest_sha256,verify=verify)
    inventory=Path(state_dir).expanduser().resolve()/"inventory"
    records,dependencies=_read_manifest_chunks(inventory,manifest,verify=verify)
    if len(records)!=manifest.get("records_count"):
        raise ValueError("inventory chunk row count mismatch")
    return {"manifest_sha256":manifest_sha256,"manifest":manifest,"records":records,"dependencies":dependencies}


def import_root_publication(root_state_dir, *, state_dir, now=None, retries=3, trusted_uid=0):
    """Copy one stable, trusted root generation into the user-owned store."""
    root_state = Path(root_state_dir).expanduser().resolve()
    root_inventory = root_state / "inventory"
    for attempt in range(max(1, retries)):
        _verify_trusted_root_tree(root_inventory, trusted_uid)
        pointer_path = root_inventory / "current.json"
        pointer_before = json.loads(pointer_path.read_text())
        source_sha = _validated_sha(pointer_before["manifest_sha256"])
        source_manifest = read_manifest(root_state, source_sha)
        _verify_trusted_root_tree(root_inventory, trusted_uid)
        metadata = dict(source_manifest.get("scan_metadata", {}))
        metadata["provenance"] = {"source_manifest_sha256": source_sha,
                                  "source_pointer": pointer_before, "imported_at": now}

        def stable_records():
            yield from iter_publication_records(root_state, source_sha)
            _verify_trusted_root_tree(root_inventory, trusted_uid)
            if json.loads(pointer_path.read_text()) != pointer_before:
                raise RuntimeError("root inventory pointer changed during bounded import")

        return publish_inventory(stable_records(), state_dir=state_dir,
            complete=source_manifest.get("complete", False),
            unresolved_frontier=source_manifest.get("unresolved_frontier", []),
            scan_metadata=metadata, now=now, merge_existing=True, merge_policy='incoming_wins')
    raise RuntimeError("root inventory pointer changed during bounded import")


def _verify_trusted_root_tree(inventory, trusted_uid):
    """Fail closed unless the root-owned publication graph has safe file modes."""
    inventory = Path(inventory)
    for path in (inventory, inventory / "current.json", inventory / "manifests",
                 inventory / "objects", inventory / "indexes"):
        st = path.lstat()
        if path.is_symlink() or st.st_uid != trusted_uid or st.st_mode & 0o022:
            raise PermissionError("root inventory store ownership or mode is unsafe: " + str(path))
    for directory in (inventory / "manifests", inventory / "objects", inventory / "indexes"):
        for path in directory.iterdir():
            st = path.lstat()
            if path.is_symlink() or not path.is_file() or st.st_uid != trusted_uid or st.st_mode & 0o022:
                raise PermissionError("root inventory object ownership or mode is unsafe: " + str(path))


def pin_publication(state_dir, manifest_sha256, owner, *, expires_at):
    _validated_sha(manifest_sha256)
    expiry=datetime.datetime.fromisoformat(expires_at.replace("Z","+00:00"))
    if expiry.tzinfo is None or expiry>datetime.datetime.now(datetime.timezone.utc)+datetime.timedelta(hours=2): raise ValueError("pin expiry must be timezone-aware and within two hours")
    inv=Path(state_dir).expanduser().resolve()/"inventory"; path=inv/"pins"/(manifest_sha256+"."+_sha(owner.encode())+".json")
    with publication_lock(state_dir):
        read_publication(state_dir,manifest_sha256); path.parent.mkdir(parents=True,exist_ok=True)
        val={"manifest_sha256":manifest_sha256,"owner":owner,"expires_at":expiry.isoformat()}; _atomic(path,_canonical(val),stage="pin"); return val

def _validated_sha(value):
    if not isinstance(value,str) or len(value)!=64 or any(c not in "0123456789abcdef" for c in value): raise ValueError("invalid manifest hash")
    return value

def unpin_publication(state_dir, manifest_sha256, owner):
    _validated_sha(manifest_sha256); path=Path(state_dir).expanduser().resolve()/"inventory"/"pins"/(manifest_sha256+"."+_sha(owner.encode())+".json")
    with publication_lock(state_dir):
        try: os.remove(path)
        except FileNotFoundError: return False
        d=os.open(str(path.parent),os.O_RDONLY); os.fsync(d); os.close(d); return True

def retention_status(state_dir, *, now=None):
    now=now or datetime.datetime.now(datetime.timezone.utc)
    if now.tzinfo is None: raise ValueError("retention clock must be timezone-aware")
    inv=Path(state_dir).expanduser().resolve()/"inventory"
    cur=json.loads((inv/"current.json").read_text())["manifest_sha256"]
    pins=set()
    for p in (inv/"pins").glob("*.json") if (inv/"pins").exists() else []:
        x=json.loads(p.read_text()); exp=datetime.datetime.fromisoformat(x["expires_at"])
        if exp>now:pins.add(_validated_sha(x["manifest_sha256"]))
    rows=[]
    for p in sorted((inv/"manifests").glob("*.json")):
        m=read_manifest(state_dir,p.stem); t=datetime.datetime.fromisoformat(m["published_at"].replace("Z","+00:00")); age=(now-t).total_seconds()/86400
        rows.append({"sha256":p.stem,"age_days":age,"current":p.stem==cur,"pinned":p.stem in pins,"measurement_retained":age<=35 or p.stem==cur or p.stem in pins,"identity_retained":age<=90 or p.stem==cur or p.stem in pins})
    return {"measurement_retention_days":35,"identity_retention_days":90,"manifests":rows}

def _logged_remove(path):
    import subprocess
    library = Path(__file__).resolve().parent / "safety_lib.sh"
    if not library.is_file():
        raise RuntimeError("canonical deletion logger is unavailable")
    subprocess.run(["bash", "-c", 'source "$1" && DM_ACTUATOR=directory_inventory rm_logged "$2"',
                    "directory-inventory-retain", str(library), str(path)], check=True)
    if Path(path).exists():
        raise OSError("canonical removal primitive left inventory object in place")
    fd = os.open(str(Path(path).parent), os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)



def _contained_regular_file(path, parent):
    path = Path(path)
    parent = Path(parent).resolve(strict=True)
    if path.is_symlink() or parent not in path.resolve(strict=True).parents:
        raise ValueError("inventory reference escapes trusted store or is a symlink")
    if not path.is_file():
        raise ValueError("inventory reference is not a regular file")
    return path


def _manifest_chunk_refs(manifest):
    chunks=manifest.get("chunks")
    if isinstance(chunks,list) and chunks:
        return chunks
    return [{"measurement_sha256":manifest.get("measurement_manifest_sha256"),
        "measurement_index_sha256":manifest.get("measurement_index_sha256"),
        "identity_sha256":manifest.get("identity_event_manifest_sha256"),
        "identity_index_sha256":manifest.get("identity_event_index_sha256")}]


def prune_retained(state_dir, *, now=None):
    now=now or datetime.datetime.now(datetime.timezone.utc); inv=Path(state_dir).expanduser().resolve()/"inventory"; removed=[]
    with publication_lock(state_dir):
        _contained_regular_file(inv/"current.json", inv)
        status=retention_status(state_dir,now=now)["manifests"]; pins={x["sha256"] for x in status if x["pinned"]}; cur=next(x["sha256"] for x in status if x["current"])
        ms={}
        for item in status:
            digest = _validated_sha(item["sha256"])
            _contained_regular_file(inv/"manifests"/(digest+".json"), inv/"manifests")
            manifest = read_manifest(state_dir,digest)
            for chunk in _manifest_chunk_refs(manifest):
                for key, directory, suffix in (("measurement_sha256","objects",".jsonl.gz"),
                        ("measurement_index_sha256","indexes",".json"),
                        ("identity_sha256","objects",".identity.json"),
                        ("identity_index_sha256","indexes",".identity.json")):
                    dep = _validated_sha(chunk.get(key))
                    dep_path = _contained_regular_file(inv/directory/(dep+suffix), inv/directory)
                    if _sha(dep_path.read_bytes()) != dep:
                        raise ValueError("inventory reference hash mismatch: "+key)
            ms[digest]=manifest
        keepm=set(); keepi=set()
        for x in status:
            m=ms[x["sha256"]]
            refs=_manifest_chunk_refs(m)
            if x["measurement_retained"]: keepm.update(v for r in refs for v in (r["measurement_sha256"],r["measurement_index_sha256"]))
            if x["identity_retained"]: keepi.update(v for r in refs for v in (r["identity_sha256"],r["identity_index_sha256"]))
        for x in status:
            sha=x["sha256"]; m=ms[sha]
            pairs=[]
            refs=_manifest_chunk_refs(m)
            if not x["measurement_retained"]:
                for r in refs: pairs += [("objects",r["measurement_sha256"],".jsonl.gz",keepm),("indexes",r["measurement_index_sha256"],".json",keepm)]
            if not x["identity_retained"]:
                for r in refs: pairs += [("objects",r["identity_sha256"],".identity.json",keepi),("indexes",r["identity_index_sha256"],".identity.json",keepi)]
            for d,h,suf,keep in pairs:
                h=_validated_sha(h)
                path=inv/d/(h+suf)
                if path.exists(): _contained_regular_file(path, inv/d)
                if h not in keep and path.exists(): _logged_remove(path); removed.append(str(path))
            if not x["identity_retained"] and sha!=cur and sha not in pins:
                sha=_validated_sha(sha)
                path=inv/"manifests"/(sha+".json")
                if path.exists(): _contained_regular_file(path, inv/"manifests")
                if path.exists(): _logged_remove(path); removed.append(str(path))
        referenced = {v for m in ms.values() for r in _manifest_chunk_refs(m) for v in (
            r["measurement_sha256"], r["measurement_index_sha256"],
            r["identity_sha256"], r["identity_index_sha256"])}
        cutoff = now.timestamp() - 86400
        suffixes = {"objects": (".jsonl.gz", ".identity.json"),
                    "indexes": (".json", ".identity.json")}
        for directory, endings in suffixes.items():
            for path in (inv/directory).iterdir():
                if path.is_symlink():
                    raise ValueError("untrusted symlink in inventory object store")
                if not path.is_file() or not path.name.endswith(endings):
                    continue
                digest = path.name.split(".", 1)[0]
                _validated_sha(digest)
                _contained_regular_file(path, inv/directory)
                if digest in referenced or path.stat().st_mtime > cutoff:
                    continue
                _logged_remove(path)
                removed.append(str(path))
    return removed


def main(argv=None):
    import argparse
    parser = argparse.ArgumentParser(description="Inspect or prune retained directory inventory publications")
    parser.add_argument("--state-dir", default=os.environ.get("DISK_MAGICIAN_STATE_DIR", str(Path.home()/".disk_magician_state")))
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--apply", action="store_true", help="prune expired immutable inventory data")
    args = parser.parse_args(argv)
    result = retention_status(args.state_dir)
    if args.apply:
        removed = prune_retained(args.state_dir)
        result = {**result, "removed": removed, "removed_count": len(removed)}
    print(json.dumps(result, indent=2 if args.json else None, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
