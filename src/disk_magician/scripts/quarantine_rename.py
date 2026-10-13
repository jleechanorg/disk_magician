#!/usr/bin/env python3
"""C14 quarantine phase 1: bind the parent before verdict, then `phase1 <path> <inventory.json> <parent-binding.json>`."""
import ctypes, hashlib, json, math, os, secrets, stat, subprocess, sys, tempfile, time
from pathlib import Path
ENV, KEYS, DIRFL = os.environ, ("path", "type", "dev", "ino", "size", "sha256", "target"), os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
UPDATE_COUNT = 0
def renamex(srcfd, src, dstfd, dst):  # flag 0x4 = RENAME_EXCL; a missing symbol raises LookupError
    try: fn = ctypes.CDLL(None, use_errno=True)[ENV.get("DISK_MAGICIAN_TEST_RENAMEX_SYMBOL", "renameatx_np")]
    except (AttributeError, OSError): raise LookupError
    if fn(srcfd, os.fsencode(src), dstfd, os.fsencode(dst), ctypes.c_uint(4)): raise OSError(ctypes.get_errno(), "renameatx_np")
def hook(name, path, dest):
    if ENV.get(name): subprocess.run(["bash", "-c", ENV[name]], env=dict(ENV, DM_Q_PATH=path, DM_Q_DEST=dest), stdout=subprocess.DEVNULL)
def kill_at(point):
    if os.environ.get("DISK_MAGICIAN_TEST_KILL_AT") == point: os.kill(os.getpid(), 9)
def bind_parent(path, out):  # called by quarantine.sh before artifact_removal_verdict
    absolute = os.path.abspath(path); parent = os.path.dirname(absolute); base = os.path.basename(absolute)
    resolved = os.path.realpath(parent); fd = os.open(resolved, DIRFL)
    try: st = os.fstat(fd)
    finally: os.close(fd)
    with open(out, "w") as f: json.dump({"parent_path": resolved, "parent_input": parent, "candidate_path": os.path.join(resolved, base), "parent_dev": st.st_dev, "parent_ino": st.st_ino, "base": base}, f)
    return "ok"
def bound_candidate(binding_file):
    with open(binding_file) as f: binding = json.load(f)
    candidate = binding.get("candidate_path")
    parent, base = binding.get("parent_path"), binding.get("base")
    if (not isinstance(candidate, str) or not os.path.isabs(candidate) or
            not isinstance(parent, str) or not os.path.isabs(parent) or
            candidate != os.path.join(parent, base)):
        raise ValueError("missing frozen candidate")
    return candidate
def visit(dfd, name, p, out):  # one entry read through its parent's fd; every descent opens O_DIRECTORY | O_NOFOLLOW
    st = os.stat(name, dir_fd=dfd, follow_symlinks=False); e = {"path": p, "type": "other", "dev": st.st_dev, "ino": st.st_ino}
    if stat.S_ISLNK(st.st_mode): e.update(type="symlink", target=os.readlink(name, dir_fd=dfd))
    elif stat.S_ISDIR(st.st_mode):
        e["type"], fd = "dir", os.open(name, DIRFL, dir_fd=dfd)
        try: [visit(fd, n, n if p == "." else f"{p}/{n}", out) for n in os.listdir(fd)]
        finally: os.close(fd)
    elif stat.S_ISREG(st.st_mode):
        h = hashlib.sha256()
        with os.fdopen(os.open(name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=dfd), "rb") as f:
            for chunk in iter(lambda: f.read(1 << 20), b""): h.update(chunk)
        e.update(type="file", size=st.st_size, sha256=h.hexdigest())
    out.append(e); return out
def same_entry(fd, name, st):
    try: current = os.stat(name, dir_fd=fd, follow_symlinks=False)
    except OSError: return False
    return (current.st_dev, current.st_ino) == (st.st_dev, st.st_ino)
def update_sidecar(qfd, side, rec):
    global UPDATE_COUNT
    UPDATE_COUNT += 1
    if ENV.get("DISK_MAGICIAN_TEST_SIDECAR_UPDATE_FAIL_AT") == str(UPDATE_COUNT): raise OSError("injected sidecar update failure")
    temp = side + ".update." + secrets.token_hex(8)
    fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=qfd)
    try:
        data = json.dumps(rec, separators=(",", ":")).encode()
        view = memoryview(data)
        while view:
            written = os.write(fd, view)
            if written <= 0: raise OSError("short sidecar write")
            view = view[written:]
        os.fsync(fd)
        if rec.get("root_removed") is True: kill_at("before_root_removed_replace")
    except Exception:
        os.close(fd)
        try: os.unlink(temp, dir_fd=qfd)
        except OSError: pass
        raise
    else: os.close(fd)
    try: os.rename(temp, side, src_dir_fd=qfd, dst_dir_fd=qfd)
    except OSError:
        try: os.unlink(temp, dir_fd=qfd)
        except OSError: pass
        raise
    os.fsync(qfd)
def index_dir():
    root = Path(os.environ.get("DISK_MAGICIAN_STATE_DIR", Path.home() / ".disk_magician_state")).expanduser()
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    path = root / "quarantine-index"
    path.mkdir(mode=0o700, exist_ok=True)
    st = path.lstat()
    if not stat.S_ISDIR(st.st_mode) or st.st_uid != os.getuid() or st.st_mode & 0o077:
        raise OSError("unsafe quarantine index directory")
    return path
def index_record(qid, parent, pstat, qstat):
    return {"schema": 1, "id": qid, "parent_path": parent,
            "parent_dev": pstat.st_dev, "parent_ino": pstat.st_ino,
            "quarantine_path": os.path.join(parent, ".dm-quarantine"),
            "quarantine_dev": qstat.st_dev, "quarantine_ino": qstat.st_ino}
def index_write(qid, record):
    if ENV.get("DISK_MAGICIAN_TEST_INDEX_WRITE_FAIL"): raise OSError("injected index write failure")
    directory = index_dir(); temp = "." + qid + "." + secrets.token_hex(8) + ".tmp"
    dfd = os.open(directory, DIRFL)
    try:
        fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=dfd)
        try:
            data = json.dumps(record, separators=(",", ":")).encode()
            view = memoryview(data)
            while view:
                written = os.write(fd, view)
                if written <= 0: raise OSError("short quarantine index write")
                view = view[written:]
            os.fsync(fd)
        finally: os.close(fd)
        os.link(temp, qid + ".json", src_dir_fd=dfd, dst_dir_fd=dfd, follow_symlinks=False)
        os.unlink(temp, dir_fd=dfd)
        os.fsync(dfd)
    except Exception:
        try: os.unlink(temp, dir_fd=dfd)
        except OSError: pass
        raise
    finally: os.close(dfd)
def index_read(qid):
    directory = index_dir(); dfd = os.open(directory, DIRFL)
    try:
        fd = os.open(qid + ".json", os.O_RDONLY | os.O_NOFOLLOW, dir_fd=dfd)
        with os.fdopen(fd, "r") as f: record = json.load(f)
    finally: os.close(dfd)
    if (not isinstance(record, dict) or record.get("schema") != 1 or record.get("id") != qid or
            not isinstance(record.get("parent_path"), str) or not os.path.isabs(record["parent_path"]) or
            record.get("quarantine_path") != os.path.join(record["parent_path"], ".dm-quarantine") or
            any(type(record.get(k)) is not int for k in ("parent_dev", "parent_ino", "quarantine_dev", "quarantine_ino"))):
        raise ValueError("invalid quarantine index entry")
    return record
def index_drop(qid):
    try: directory = index_dir()
    except OSError: return False
    dfd = os.open(directory, DIRFL)
    try:
        try: os.unlink(qid + ".json", dir_fd=dfd)
        except FileNotFoundError: return True
        os.fsync(dfd); return True
    except OSError: return False
    finally: os.close(dfd)
def verify(pfd, qfd, qentry, qid, rec, qdir):  # "" = identity, live-user and re-hash checks all pass
    canon = lambda es: sorted(json.dumps([None if k == "size" and e.get("type") != "file" else e.get(k) for k in KEYS]) for e in es)
    try:
        d = os.stat(qid, dir_fd=qfd, follow_symlinks=False)
        if (d.st_dev, d.st_ino) != (rec["dev"], rec["ino"]): return "identity-mismatch"
        if not same_entry(qfd, qid, d): return "identity-mismatch"
        if not same_entry(pfd, ".dm-quarantine", qentry): return "quarantine-dir-changed"
        lsof = subprocess.run(["lsof", "-nP", "+D" if stat.S_ISDIR(d.st_mode) else "--", os.path.join(qdir, qid)], capture_output=True, timeout=120)  # +D is dirs-only
        if lsof.stdout or lsof.returncode != 1 or lsof.stderr.strip(): return "live-user" if lsof.stdout or not lsof.returncode else "check-failed"
        if not same_entry(pfd, ".dm-quarantine", qentry): return "quarantine-dir-changed"
        if not same_entry(qfd, qid, d): return "identity-mismatch"
        return "" if canon(visit(qfd, qid, ".", [])) == canon(rec["inventory"]) else "rehash-mismatch"
    except Exception: return "check-failed"
def phase1(path, inv_file, binding_file):
    path = os.path.abspath(path)
    parent, base = os.path.dirname(path), os.path.basename(path)
    pfd = qfd = -1
    try:
        with open(binding_file) as f: binding = json.load(f)
        parent_id = (binding.get("parent_dev"), binding.get("parent_ino"))
        if any(type(v) is not int for v in parent_id) or binding.get("base") != base or binding.get("parent_input") != parent:
            return "kept:parent-identity-missing"
        hook("DISK_MAGICIAN_TEST_AFTER_VERDICT", path, "")
        parent = os.path.realpath(parent)
        if parent != binding.get("parent_path"): return "kept:parent-identity-mismatch"
        with open(inv_file) as f: inv = [e for e in json.load(f) if isinstance(e, dict)]
        root = next(e for e in inv if e.get("path") == ".")
        if any(type(root.get(k)) is not int for k in ("dev", "ino")): return "kept:identity-mismatch"
        path = os.path.join(parent, base)
        pfd = os.open(parent, DIRFL)
        bound_parent = os.fstat(pfd)
        if (bound_parent.st_dev, bound_parent.st_ino) != parent_id: return "kept:parent-identity-mismatch"
        try: os.mkdir(".dm-quarantine", 0o700, dir_fd=pfd)
        except FileExistsError: pass
        qpath_st = os.stat(".dm-quarantine", dir_fd=pfd, follow_symlinks=False)
        if not stat.S_ISDIR(qpath_st.st_mode): return "kept:quarantine-dir-unsafe"
        qfd = os.open(".dm-quarantine", DIRFL, dir_fd=pfd); q = os.fstat(qfd); st = os.stat(base, dir_fd=pfd, follow_symlinks=False)
        if not stat.S_ISDIR(q.st_mode) or q.st_uid != os.getuid() or q.st_mode & 0o777 != 0o700: return "kept:quarantine-dir-unsafe"
        if not same_entry(pfd, ".dm-quarantine", q): return "kept:quarantine-dir-unsafe"
        if [(st.st_dev, st.st_ino)] != [(e.get("dev"), e.get("ino")) for e in inv if e.get("path") == "."]: return "kept:identity-mismatch"
        if q.st_dev != st.st_dev: return "kept:cross-device"  # never copy
    except Exception: return "kept:check-failed"
    qdir = os.path.join(parent, ".dm-quarantine"); qid = secrets.token_hex(8); side = qid + ".json"
    try: index_write(qid, index_record(qid, parent, bound_parent, q))
    except Exception: return "kept:quarantine-index-write-failed"
    rec = {"id": qid, "original": path, "dev": st.st_dev, "ino": st.st_ino,
           "parent_dev": bound_parent.st_dev, "parent_ino": bound_parent.st_ino,
           "quarantine_dev": q.st_dev, "quarantine_ino": q.st_ino,
           "inventory": inv, "phase": "intent"}
    try:
        with os.fdopen(os.open(side, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=qfd), "w") as f:
            if ENV.get("DISK_MAGICIAN_TEST_INTENT_ERRNO"): raise OSError(int(ENV["DISK_MAGICIAN_TEST_INTENT_ERRNO"]), "test")
            f.write(json.dumps(rec)); f.flush(); os.fsync(f.fileno())
        os.fsync(qfd)
    except OSError:  # ENOSPC aborts before the rename; the artifact stays in place
        try: os.unlink(side, dir_fd=qfd)
        except OSError: pass
        index_drop(qid)
        return "kept:intent-write-failed"
    kill_at("after_intent")
    dest = os.path.join(qdir, qid)
    hook("DISK_MAGICIAN_TEST_BEFORE_QUARANTINE_RENAME", path, dest)
    if not same_entry(pfd, ".dm-quarantine", q): return f"quarantine_conflict:{qid}"
    if not same_entry(pfd, base, st):
        try: os.unlink(side, dir_fd=qfd)
        except OSError: pass
        index_drop(qid)
        return "kept:identity-mismatch"
    try: renamex(pfd, base, qfd, qid)  # commit point; both directory bindings stay pinned
    except (LookupError, OSError) as e:
        try: os.unlink(side, dir_fd=qfd)
        except OSError: pass
        index_drop(qid)
        return "kept:exclusive_rename_unavailable" if isinstance(e, LookupError) else "kept:rename-failed"
    try:
        os.fsync(pfd); os.fsync(qfd)
    except OSError: return f"quarantine_conflict:{qid}"
    kill_at("after_rename")
    hook("DISK_MAGICIAN_TEST_AFTER_QUARANTINE", path, dest)
    why = verify(pfd, qfd, q, qid, rec, qdir)
    if not why: return f"quarantined:{qid}"
    if why in ("identity-mismatch", "quarantine-dir-changed"): return f"quarantine_conflict:{qid}"  # preserve uncertain identity and recovery record
    rec["phase"] = "rollback_pending"
    rec["rollback"] = {"from": dest, "to": path, "reason": why,
                       "expected": {"dev": rec["dev"], "ino": rec["ino"]}}
    try: update_sidecar(qfd, side, rec)
    except OSError: return f"quarantine_conflict:{qid}:rollback-intent-write-failed"
    try:
        current = os.stat(qid, dir_fd=qfd, follow_symlinks=False)
        if (current.st_dev, current.st_ino) != (rec["dev"], rec["ino"]): return f"quarantine_conflict:{qid}"
        hook("DISK_MAGICIAN_TEST_BEFORE_ROLLBACK_RENAME", path, dest)
        kill_at("before_rollback")
        renamex(qfd, qid, pfd, base)
    except OSError: return f"quarantine_conflict:{qid}"  # conflict: preserve quarantined entry and sidecar
    try:
        restored = os.stat(base, dir_fd=pfd, follow_symlinks=False)
        restored_identity = (restored.st_dev, restored.st_ino)
        expected_identity = (rec["dev"], rec["ino"])
        if restored_identity != expected_identity:
            locations = []
            relative_locations = []
            for name in os.listdir(qfd):
                try: found = os.stat(name, dir_fd=qfd, follow_symlinks=False)
                except OSError: continue
                if (found.st_dev, found.st_ino) == expected_identity:
                    relative_locations.append(name)
            qfd_stat = os.fstat(qfd)
            q_bound = same_entry(pfd, ".dm-quarantine", q) and (qfd_stat.st_dev, qfd_stat.st_ino) == (q.st_dev, q.st_ino)
            try: parent_stat = os.stat(parent, follow_symlinks=False)
            except OSError: parent_stat = None
            parent_fd_stat = os.fstat(pfd)
            parent_bound = parent_stat is not None and (parent_stat.st_dev, parent_stat.st_ino) == (parent_fd_stat.st_dev, parent_fd_stat.st_ino)
            if q_bound and parent_bound: locations = [os.path.join(qdir, name) for name in relative_locations]
            rec["phase"] = "rollback_conflict"
            rec["rollback_conflict"] = {
                "expected": {"dev": expected_identity[0], "ino": expected_identity[1]},
                "original_path": path if parent_bound else None,
                "parent_path_bound": parent_bound,
                "parent_identity": {"dev": parent_fd_stat.st_dev, "ino": parent_fd_stat.st_ino},
                "original_observed": {"dev": restored.st_dev, "ino": restored.st_ino},
                "quarantine_path": dest if parent_bound and q_bound else None,
                "quarantine_dir_bound": q_bound,
                "quarantine_identity": {"dev": qfd_stat.st_dev, "ino": qfd_stat.st_ino},
                "quarantine_observed": None,
                "expected_locations_in_quarantine": locations,
                "expected_entry_names_in_bound_quarantine": relative_locations,
            }
            try:
                quarantined = os.stat(qid, dir_fd=qfd, follow_symlinks=False)
                rec["rollback_conflict"]["quarantine_observed"] = {"dev": quarantined.st_dev, "ino": quarantined.st_ino}
            except FileNotFoundError: pass
            try: update_sidecar(qfd, side, rec)
            except OSError: return f"quarantine_conflict:{qid}:rollback-state-update-failed"
            return f"quarantine_conflict:{qid}"
    except OSError: return f"quarantine_conflict:{qid}"
    try: os.fsync(qfd); os.fsync(pfd)
    except OSError: return f"quarantine_conflict:{qid}"
    if not same_entry(pfd, base, restored): return f"quarantine_conflict:{qid}"
    try: os.unlink(side, dir_fd=qfd)
    except OSError: return f"quarantine_conflict:{qid}"
    try: os.fsync(qfd)
    except OSError: return f"quarantine_conflict:{qid}"
    if not index_drop(qid): return f"quarantine_conflict:{qid}:index-cleanup-failed"
    return f"kept:{why}"

def entry_kind(st):
    if stat.S_ISDIR(st.st_mode): return "dir"
    if stat.S_ISREG(st.st_mode): return "file"
    if stat.S_ISLNK(st.st_mode): return "symlink"
    return "other"

def inventory_children(inventory):
    by_path = {}
    for entry in inventory:
        rel = entry.get("path")
        if not isinstance(rel, str) or rel in by_path: raise ValueError("invalid inventory path")
        if rel != "." and (rel.startswith("/") or any(part in ("", ".", "..") for part in rel.split("/"))):
            raise ValueError("unsafe inventory path")
        by_path[rel] = entry
    if "." not in by_path: raise ValueError("missing root inventory entry")
    children = {rel: [] for rel in by_path}
    for rel in by_path:
        entry = by_path[rel]
        if entry.get("type") not in ("dir", "file", "symlink") or any(type(entry.get(k)) is not int for k in ("dev", "ino")):
            raise ValueError("invalid inventory entry")
        if entry.get("type") == "file" and (type(entry.get("size")) is not int or not isinstance(entry.get("sha256"), str)):
            raise ValueError("invalid file inventory")
        if entry.get("type") == "symlink" and not isinstance(entry.get("target"), str):
            raise ValueError("invalid symlink inventory")
        if rel == ".": continue
        parent = rel.rpartition("/")[0] or "."
        if parent not in by_path or by_path[parent].get("type") != "dir": raise ValueError("orphan inventory entry")
        children[parent].append((rel.rpartition("/")[2], rel))
    return by_path, children

def tree_still_quarantined(location_guard):
    pfd, qfd, qid, qstat, rootstat = location_guard
    return same_entry(pfd, ".dm-quarantine", qstat) and same_entry(qfd, qid, rootstat)

def tree_ancestry_still_quarantined(location_guard, ancestors):
    if not tree_still_quarantined(location_guard): return False
    return all(same_entry(parent_fd, name, expected) for parent_fd, name, expected in ancestors)

def unlink_inventory_entry(parent_fd, name, rel, expected, inventory, children, deadline=None,
                           location_guard=None, root_label="", ancestors=()):
    """Delete exactly one inventoried entry, using only its pinned parent fd."""
    if location_guard is not None and not tree_ancestry_still_quarantined(location_guard, ancestors): return False
    if deadline is not None and time.monotonic() >= deadline: return False
    try: st = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    except FileNotFoundError: return rel != "."  # the root's absence is ambiguous until root_removed is durable
    kind = entry_kind(st)
    if (kind != expected.get("type") or st.st_dev != expected.get("dev") or
            st.st_ino != expected.get("ino")):
        return False
    if kind == "dir":
        try: child_fd = os.open(name, DIRFL, dir_fd=parent_fd)
        except OSError: return False
        try:
            opened = os.fstat(child_fd)
            if (entry_kind(opened), opened.st_dev, opened.st_ino) != ("dir", expected.get("dev"), expected.get("ino")):
                return False
            child_ancestors = ancestors + ((parent_fd, name, opened),)
            if rel == ".":
                hook("DISK_MAGICIAN_TEST_AFTER_ROOT_OPEN", root_label, "")
                if location_guard is not None and not tree_ancestry_still_quarantined(location_guard, child_ancestors): return False
            else:
                child_path = os.path.join(root_label, rel)
                hook("DISK_MAGICIAN_TEST_AFTER_CHILD_OPEN", child_path, "")
                if location_guard is not None and not tree_ancestry_still_quarantined(location_guard, child_ancestors): return False
            ok = True
            for child_name, child_rel in children.get(rel, []):
                if not unlink_inventory_entry(child_fd, child_name, child_rel, inventory[child_rel], inventory, children,
                                              deadline, location_guard, root_label, child_ancestors):
                    ok = False
            if not ok: return False
        finally: os.close(child_fd)
        try:
            if location_guard is not None and not tree_ancestry_still_quarantined(location_guard, ancestors): return False
            current = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
            if (entry_kind(current), current.st_dev, current.st_ino) != ("dir", expected.get("dev"), expected.get("ino")):
                return False
            if deadline is not None and time.monotonic() >= deadline: return False
            os.rmdir(name, dir_fd=parent_fd)
            os.fsync(parent_fd)
            return True
        except OSError: return False  # includes extra, non-inventoried contents
    if kind == "file":
        try: fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=parent_fd)
        except OSError: return False
        try:
            opened = os.fstat(fd)
            if (entry_kind(opened), opened.st_dev, opened.st_ino, opened.st_size) != (
                    "file", expected.get("dev"), expected.get("ino"), expected.get("size")):
                return False
            digest = hashlib.sha256()
            while True:
                chunk = os.read(fd, 1 << 20)
                if not chunk: break
                digest.update(chunk)
            after = os.fstat(fd)
            if ((after.st_dev, after.st_ino, after.st_size) !=
                    (opened.st_dev, opened.st_ino, opened.st_size) or digest.hexdigest() != expected.get("sha256")):
                return False
        finally: os.close(fd)
    elif kind == "symlink":
        try: target = os.readlink(name, dir_fd=parent_fd)
        except OSError: return False
        if target != expected.get("target"): return False
    else: return False
    try:
        if location_guard is not None and not tree_ancestry_still_quarantined(location_guard, ancestors): return False
        current = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
        if (entry_kind(current), current.st_dev, current.st_ino) != (kind, expected.get("dev"), expected.get("ino")):
            return False
        if deadline is not None and time.monotonic() >= deadline: return False
        os.unlink(name, dir_fd=parent_fd)
        os.fsync(parent_fd)
        kill_at("mid_delete")
        return True
    except OSError: return False

def phase2(binding_file, qid, deadline=None):
    """Finish deleting one quarantined tree; every unlink is fd-relative."""
    pfd = qfd = -1
    side = qid + ".json"
    try:
        if not isinstance(qid, str) or len(qid) != 16 or any(c not in "0123456789abcdef" for c in qid):
            return "kept:quarantine_partial_kept"
        with open(binding_file) as f: binding = json.load(f)
        parent = binding.get("parent_path")
        if not isinstance(parent, str) or not os.path.isabs(parent): return "kept:quarantine_partial_kept"
        pfd = os.open(parent, DIRFL)
        pstat = os.fstat(pfd)
        if (pstat.st_dev, pstat.st_ino) != (binding.get("parent_dev"), binding.get("parent_ino")):
            return "kept:quarantine_partial_kept"
        qst = os.stat(".dm-quarantine", dir_fd=pfd, follow_symlinks=False)
        if not stat.S_ISDIR(qst.st_mode) or qst.st_uid != os.getuid() or qst.st_mode & 0o777 != 0o700:
            return "kept:quarantine_partial_kept"
        qfd = os.open(".dm-quarantine", DIRFL, dir_fd=pfd)
        qopened = os.fstat(qfd)
        if (qopened.st_dev, qopened.st_ino) != (qst.st_dev, qst.st_ino):
            return "kept:quarantine_partial_kept"
        side_fd = os.open(side, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=qfd)
        try:
            with os.fdopen(side_fd, "r") as f: record = json.load(f)
        except Exception:
            return "kept:quarantine_partial_kept"
        if (not isinstance(record, dict) or record.get("id") != qid or
                record.get("phase") not in ("intent", "deleting") or
                not isinstance(record.get("inventory"), list)):
            return "kept:quarantine_partial_kept"
        if (qst.st_dev, qst.st_ino) != (record.get("quarantine_dev"), record.get("quarantine_ino")):
            return "kept:quarantine_partial_kept"
        original = record.get("original")
        if not isinstance(original, str) or os.path.dirname(original) != parent:
            return "kept:quarantine_partial_kept"
        inventory, children = inventory_children(record["inventory"])
        root = inventory["."]
        if (root.get("dev"), root.get("ino")) != (record.get("dev"), record.get("ino")):
            return "kept:quarantine_partial_kept"
        try: candidate = os.stat(qid, dir_fd=qfd, follow_symlinks=False)
        except FileNotFoundError: candidate = None
        if candidate is not None and (candidate.st_dev, candidate.st_ino) != (record.get("dev"), record.get("ino")):
            return "kept:quarantine_partial_kept"
        if candidate is None:
            # A missing name does not prove deletion: it may have been moved.
            # Only the durable marker written after our inventory walk proves
            # that this operation removed the frozen root.
            if record.get("phase") != "deleting" or record.get("root_removed") is not True:
                return "kept:quarantine_partial_kept"
            os.fsync(qfd)
            if not same_entry(pfd, ".dm-quarantine", qst): return "kept:quarantine_partial_kept"
            if ENV.get("DISK_MAGICIAN_TEST_KILL_AT") == "before_sidecar_drop": os.kill(os.getpid(), 9)
            os.unlink(side, dir_fd=qfd)
            os.fsync(qfd)
            if not index_drop(qid): return "kept:quarantine_partial_kept"
            return "removed"
        if record.get("phase") != "deleting":
            record["phase"] = "deleting"
            update_sidecar(qfd, side, record)
        hook("DISK_MAGICIAN_TEST_BEFORE_UNLINK", os.path.join(parent, ".dm-quarantine", qid), "")
        if not same_entry(pfd, ".dm-quarantine", qst): return "kept:quarantine_partial_kept"
        rootstat = os.stat(qid, dir_fd=qfd, follow_symlinks=False)
        location_guard = (pfd, qfd, qid, qst, rootstat)
        if not unlink_inventory_entry(qfd, qid, ".", root, inventory, children, deadline,
                                      location_guard, os.path.join(parent, ".dm-quarantine", qid)):
            return "kept:quarantine_partial_kept"
        os.fsync(qfd)
        if not same_entry(pfd, ".dm-quarantine", qst): return "kept:quarantine_partial_kept"
        record["root_removed"] = True
        update_sidecar(qfd, side, record)
        if ENV.get("DISK_MAGICIAN_TEST_KILL_AT") == "before_sidecar_drop": os.kill(os.getpid(), 9)
        os.unlink(side, dir_fd=qfd)
        os.fsync(qfd)
        if not index_drop(qid): return "kept:quarantine_partial_kept"
        return "removed"
    except Exception: return "kept:quarantine_partial_kept"
    finally:
        if qfd >= 0: os.close(qfd)
        if pfd >= 0: os.close(pfd)
def indexed_item(qid):
    index = index_read(qid)
    pfd = os.open(index["parent_path"], DIRFL)
    try:
        parent_stat = os.fstat(pfd)
        if (parent_stat.st_dev, parent_stat.st_ino) != (index["parent_dev"], index["parent_ino"]):
            raise ValueError("parent identity mismatch")
        qstat = os.stat(".dm-quarantine", dir_fd=pfd, follow_symlinks=False)
        if (not stat.S_ISDIR(qstat.st_mode) or qstat.st_uid != os.getuid() or qstat.st_mode & 0o777 != 0o700 or
                (qstat.st_dev, qstat.st_ino) != (index["quarantine_dev"], index["quarantine_ino"])):
            raise ValueError("quarantine directory identity mismatch")
        qfd = os.open(".dm-quarantine", DIRFL, dir_fd=pfd)
    except Exception:
        os.close(pfd); raise
    try:
        opened = os.fstat(qfd)
        if (opened.st_dev, opened.st_ino) != (index["quarantine_dev"], index["quarantine_ino"]):
            raise ValueError("quarantine directory retargeted")
        fd = os.open(qid + ".json", os.O_RDONLY | os.O_NOFOLLOW, dir_fd=qfd)
        with os.fdopen(fd, "r") as f: record = json.load(f)
        inventory = record.get("inventory", []) if isinstance(record, dict) else []
        root = next((e for e in inventory if isinstance(e, dict) and e.get("path") == "."), None)
        if (not isinstance(record, dict) or record.get("id") != qid or
                record.get("parent_dev") != index["parent_dev"] or record.get("parent_ino") != index["parent_ino"] or
                record.get("quarantine_dev") != index["quarantine_dev"] or record.get("quarantine_ino") != index["quarantine_ino"] or
                not isinstance(record.get("original"), str) or not os.path.isabs(record["original"]) or
                os.path.dirname(record["original"]) != index["parent_path"] or
                not isinstance(inventory, list) or not isinstance(root, dict) or
                (record.get("dev"), record.get("ino")) != (root.get("dev"), root.get("ino"))):
            raise ValueError("sidecar identity or path mismatch")
        return index, pfd, qfd, record
    except Exception:
        os.close(qfd); os.close(pfd); raise
def finish_sidecar(qfd, qid):
    os.unlink(qid + ".json", dir_fd=qfd); os.fsync(qfd)
    if not index_drop(qid): raise OSError("quarantine index cleanup failed")
def reconcile_one(qid, deadline=None):
    pfd = qfd = -1
    try:
        index, pfd, qfd, record = indexed_item(qid)
        phase = record.get("phase")
        base = os.path.basename(record["original"])
        expected = (record["dev"], record["ino"])
        try: at_original = os.stat(base, dir_fd=pfd, follow_symlinks=False)
        except FileNotFoundError: at_original = None
        try: at_quarantine = os.stat(qid, dir_fd=qfd, follow_symlinks=False)
        except FileNotFoundError: at_quarantine = None
        original_matches = at_original is not None and (at_original.st_dev, at_original.st_ino) == expected
        quarantine_matches = at_quarantine is not None and (at_quarantine.st_dev, at_quarantine.st_ino) == expected
        if phase == "deleting":
            binding = {"parent_path": index["parent_path"], "parent_dev": index["parent_dev"], "parent_ino": index["parent_ino"]}
            with tempfile.NamedTemporaryFile("w", dir=index_dir(), prefix=".reconcile.", delete=False) as f:
                json.dump(binding, f); binding_path = f.name
            try: result = phase2(binding_path, qid, deadline)
            finally:
                try: os.unlink(binding_path)
                except OSError: pass
            return result
        if phase not in ("intent", "rollback_pending", "rollback_conflict"):
            return f"alert:{qid}:malformed-phase"
        if original_matches and at_quarantine is None:
            finish_sidecar(qfd, qid); return f"reconciled:{qid}:original"
        if at_original is None and quarantine_matches:
            renamex(qfd, qid, pfd, base)
            os.fsync(qfd); os.fsync(pfd)
            restored = os.stat(base, dir_fd=pfd, follow_symlinks=False)
            if (restored.st_dev, restored.st_ino) != expected: return f"alert:{qid}:rollback-identity-mismatch"
            finish_sidecar(qfd, qid); return f"reconciled:{qid}:rolled-back"
        return f"alert:{qid}:location-conflict"
    except FileNotFoundError:
        return f"alert:{qid}:missing-index-or-sidecar"
    except Exception as exc:
        reason = str(exc).replace("\n", " ")[:120]
        return f"alert:{qid}:reconcile-failed:{reason}"
    finally:
        if qfd >= 0: os.close(qfd)
        if pfd >= 0: os.close(pfd)
def cursor_write(path, last_id):
    target = os.path.abspath(os.path.expanduser(path)); parent = os.path.dirname(target)
    os.makedirs(parent, mode=0o700, exist_ok=True)
    temp = os.path.join(parent, "." + os.path.basename(target) + "." + secrets.token_hex(8) + ".tmp")
    fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        data = json.dumps({"last_id": last_id}, separators=(",", ":")).encode()
        os.write(fd, data); os.fsync(fd)
    finally: os.close(fd)
    os.replace(temp, target)
    dfd = os.open(parent, DIRFL)
    try: os.fsync(dfd)
    finally: os.close(dfd)
def quarantine_reconcile(args):
    deadline = None; cursor = None; i = 0
    while i < len(args):
        if args[i] == "--deadline-at" and i + 1 < len(args): deadline = float(args[i + 1]); i += 2
        elif args[i] == "--cursor" and i + 1 < len(args): cursor = args[i + 1]; i += 2
        else: raise ValueError("usage: reconcile [--deadline-at MONOTONIC] [--cursor FILE]")
    directory = index_dir(); cursor = cursor or str(directory / "reconcile.cursor")
    last = None
    try:
        with open(cursor) as f: last = json.load(f).get("last_id")
    except FileNotFoundError: pass
    except Exception:
        print("ALERT: quarantine reconcile cursor is malformed"); return 1
    dfd = os.open(directory, DIRFL)
    try: ids = sorted(n[:-5] for n in os.listdir(dfd) if len(n) == 21 and n.endswith(".json") and all(c in "0123456789abcdef" for c in n[:-5]))
    finally: os.close(dfd)
    if last is not None: ids = [qid for qid in ids if qid > last]
    completed = last
    for qid in ids:
        if deadline is not None and time.monotonic() >= deadline:
            cursor_write(cursor, completed); print(f"deferred:{qid}"); return 0
        result = reconcile_one(qid, deadline); print(result)
        if result.startswith("alert:"): print(f"ALERT: {result}")
        completed = qid; cursor_write(cursor, completed)
    try: os.unlink(cursor)
    except FileNotFoundError: pass
    return 0
def quarantine_restore(qid):
    pfd = qfd = restored_fd = -1
    try:
        if len(qid) != 16 or any(c not in "0123456789abcdef" for c in qid): return "kept:unknown-quarantine-id"
        index, pfd, qfd, record = indexed_item(qid)
        if record.get("phase") == "deleting": return "kept:quarantine_partial_kept"
        base = os.path.basename(record["original"]); root = next(e for e in record["inventory"] if e.get("path") == ".")
        try: os.stat(base, dir_fd=pfd, follow_symlinks=False); return "kept:restore-target-exists"
        except FileNotFoundError: pass
        current = os.stat(qid, dir_fd=qfd, follow_symlinks=False)
        if (current.st_dev, current.st_ino) != (root.get("dev"), root.get("ino")): return "kept:identity-mismatch"
        if canon_inventory(visit(qfd, qid, ".", [])) != canon_inventory(record["inventory"]): return "kept:quarantine_partial_kept"
        hook("DISK_MAGICIAN_TEST_BEFORE_RESTORE_RENAME", os.path.join(index["parent_path"], ".dm-quarantine", qid), os.path.join(index["parent_path"], base))
        renamex(qfd, qid, pfd, base); os.fsync(qfd); os.fsync(pfd)
        restored = os.stat(base, dir_fd=pfd, follow_symlinks=False)
        root_flags = os.O_RDONLY | os.O_NOFOLLOW | (os.O_DIRECTORY if root.get("type") == "dir" else 0)
        restored_fd = os.open(base, root_flags, dir_fd=pfd)
        opened = os.fstat(restored_fd)
        if ((opened.st_dev, opened.st_ino) != (root.get("dev"), root.get("ino")) or
                (restored.st_dev, restored.st_ino) != (opened.st_dev, opened.st_ino) or
                not same_entry(pfd, base, opened)):
            record["phase"] = "restore_conflict"
            record["restore_conflict"] = {
                "expected": {"dev": root.get("dev"), "ino": root.get("ino")},
                "observed": {"dev": restored.st_dev, "ino": restored.st_ino},
                "original_path": record["original"],
            }
            try: update_sidecar(qfd, qid + ".json", record)
            except OSError: pass
            return "kept:restore-identity-mismatch"
        finish_sidecar(qfd, qid)
        return f"restored:{qid}"
    except FileNotFoundError: return "kept:unknown-quarantine-id"
    except Exception: return "kept:quarantine_restore_failed"
    finally:
        if restored_fd >= 0: os.close(restored_fd)
        if qfd >= 0: os.close(qfd)
        if pfd >= 0: os.close(pfd)
def canon_inventory(entries):
    return sorted(json.dumps([e.get(k) for k in KEYS]) for e in entries)
if __name__ == "__main__":
    args = sys.argv[1:]
    if args[:1] == ["bind"] and len(args) == 3: print(bind_parent(args[1], args[2]))
    elif args[:1] == ["candidate"] and len(args) == 2: print(bound_candidate(args[1]))
    elif args[:1] == ["phase1"] and len(args) == 4: print(phase1(*args[1:]))
    elif args[:1] == ["phase2"] and len(args) in (3, 5):
        if len(args) == 5 and args[3] == "--deadline-at":
            try:
                value = float(args[4])
                print(phase2(args[1], args[2], value if math.isfinite(value) and value >= 0 else -1))
            except ValueError: print("kept:quarantine_partial_kept")
        elif len(args) == 3: print(phase2(*args[1:]))
        else: print("kept:quarantine_partial_kept")
    elif args[:1] == ["restore"] and len(args) == 2: print(quarantine_restore(args[1]))
    elif args[:1] == ["reconcile"]: sys.exit(quarantine_reconcile(args[1:]))
    else: print("kept:check-failed")
