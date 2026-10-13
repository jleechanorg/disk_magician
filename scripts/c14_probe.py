#!/usr/bin/env python3
"""C14 probes (spec §7.2). lsremote: live, 30 s, uncached, run from / without GIT_* so
candidate config is never read; a local remote must be an absolute path outside <root>.
gitmeta: .git outside objects/ refs/ logs/ packed-refs index *HEAD, as a manifest or
compared with a lease's git_meta. admin: a linked worktree's admin dir; prints the
object ids under *HEAD, refs/, logs/ and the branch reflog, or kept:<reason>."""
import hashlib, json, os, re, signal, stat, subprocess, sys, tempfile, time

SKIP = {"objects", "refs", "logs", "packed-refs", "index"}

def local_path(url):
    """Filesystem path git would use for url, "" if unusable, None for a network transport."""
    if "://" in url:
        scheme, rest = url.split("://", 1)
        if scheme.lower() != "file":
            return None
        host, _, path = rest.partition("/")
        return "/" + path if host in ("", "localhost") and "%" not in path else ""
    colon, slash = url.find(":"), url.find("/")
    if "::" in url or (colon > 0 and (slash < 0 or colon < slash)):
        return None
    return url

def _remaining(deadline, step):
    if deadline in (None, ""):
        return None
    return max(0.0, float(deadline) - time.monotonic())

def _run_bounded(argv, *, cwd=None, env=None, cap=None, deadline=None, step="check", stderr=None):
    left = _remaining(deadline, step)
    if left is not None and left <= 0:
        return None
    limit = min(cap, left) if cap is not None and left is not None else (cap or left)
    p = subprocess.Popen(argv, cwd=cwd, env=env, stdin=subprocess.DEVNULL,
                         stdout=subprocess.PIPE, stderr=stderr or subprocess.DEVNULL, start_new_session=True)
    try:
        out = p.communicate(timeout=limit)[0]
    except subprocess.TimeoutExpired:
        os.killpg(p.pid, signal.SIGKILL)
        p.wait()
        return None
    return p.returncode, out

def lsremote(url, root, deadline=None):
    lp = local_path(url)
    if lp is not None:
        r = os.path.realpath(root)
        p = os.path.realpath(lp) if lp.startswith("/") else r
        if p == r or p.startswith(r.rstrip("/") + "/"):
            return 1
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    env.update(GIT_TERMINAL_PROMPT="0", GIT_ASKPASS="/usr/bin/false", SSH_ASKPASS="/usr/bin/false")
    result = _run_bounded(["git", "ls-remote", url], cwd="/", env=env, cap=30,
                          deadline=deadline, step="lsremote")
    if result is None:
        if deadline is not None:
            print("deferred:lsremote")
        return 2
    rc, out = result
    sys.stdout.write(out.decode(errors="replace"))
    return rc

def gitmeta(gd, lease=None):
    m = {}
    for dp, dns, fns in os.walk(gd, onerror=lambda e: sys.exit("kept:check-failed")):
        if dp == gd:
            dns[:] = [d for d in dns if d not in SKIP]
            fns = [f for f in fns if f not in SKIP and not f.endswith("HEAD")]
        for p in [os.path.join(dp, f) for f in fns] + [os.path.join(dp, d) for d in dns if os.path.islink(os.path.join(dp, d))]:
            mode = os.lstat(p).st_mode
            m[os.path.relpath(p, gd)] = (hashlib.sha256(open(p, "rb").read()).hexdigest() if stat.S_ISREG(mode)
                                         else "link:" + os.readlink(p) if stat.S_ISLNK(mode) else "mode:%o" % mode)
    if lease is None:
        return print(json.dumps(m, sort_keys=True))
    base = json.load(open(lease)).get("git_meta") if os.path.isfile(lease) else None
    print("kept:git-unbaselined" if not isinstance(base, dict) else "ok" if base == m else "kept:git-metadata")

ADMIN = {"HEAD", "ORIG_HEAD", "FETCH_HEAD", "AUTO_MERGE", "index", "commondir", "gitdir", "config.worktree", "COMMIT_EDITMSG"}
OID, HEX = re.compile(r"^(?!0+$)([0-9a-f]{40}|[0-9a-f]{64})$"), rb"[0-9a-f]{40}(?:[0-9a-f]{24})?"
REF, LOG = re.compile(HEX + rb"\n?"), re.compile(HEX + b" " + HEX + rb" [^\n]*> \d+ [+-]\d{4}(?:\t[^\n]*)?\n?")

def entry_ok(p, rel, st):  # git's own type and name; files under refs/ and logs/ must parse as a ref or reflog
    top, d, f = rel.split("/")[0], stat.S_ISDIR(st.st_mode), stat.S_ISREG(st.st_mode)
    if top not in ("refs", "logs") or not f or "/" not in rel:
        return d and top in ("refs", "logs") or f and top in ADMIN and "/" not in rel
    return bool(REF.fullmatch(open(p, "rb").read())) if top == "refs" else all(map(LOG.fullmatch, open(p, "rb").read().splitlines(True)))

def admin(ad, lease=None):
    names = set(os.listdir(ad))
    if "locked" in names or names & {"rebase-merge", "rebase-apply", "MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "BISECT_LOG"}:
        return print("kept:locked" if "locked" in names else "kept:dirty")
    files, inv = [], os.environ.get("C14_INVENTORY_OUT")
    for dp, dns, fns in os.walk(ad, onerror=lambda e: sys.exit("kept:check-failed")):
        for n in fns + dns:  # a symlink, special file or unparsed entry anywhere: admin-unknown
            p = os.path.join(dp, n); rel = os.path.relpath(p, ad); st = os.lstat(p)
            if not entry_ok(p, rel, st): return print("kept:admin-unknown")
            if stat.S_ISDIR(st.st_mode): continue
            files += [p] if rel.endswith("HEAD") or "/" in rel else []  # *HEAD, refs/**, logs/**
            if inv:
                print(json.dumps({"admin": ad, "path": rel, "mode": "%o" % st.st_mode, "dev": st.st_dev, "ino": st.st_ino, "size": st.st_size,
                                  "sha256": hashlib.sha256(open(p, "rb").read()).hexdigest()}), file=open(inv, "a"))
    cw = os.path.join(ad, "config.worktree")  # regular here; non-empty must match the lease git_meta baseline
    if "config.worktree" in names and os.path.getsize(cw) and hashlib.sha256(open(cw, "rb").read()).hexdigest() != (
            (json.load(open(lease)).get("git_meta") or {}) if lease and os.path.isfile(lease) else {}).get("config.worktree"):
        return print("kept:admin-unknown")
    head = open(os.path.join(ad, "HEAD")).read().strip()
    if head.startswith("ref: "):  # the branch reflog lives in the common dir
        files += [p for p in [os.path.join(ad, open(os.path.join(ad, "commondir")).read().strip(), "logs", head[5:])] if os.path.isfile(p)]
    oids = sorted({w for p in files for l in open(p) for w in l.split()[:2] if OID.match(w)})
    print("kept:admin-unknown" if "COMMIT_EDITMSG" in names and not editmsg_ok(ad, oids) else "\n".join(oids))

def editmsg_ok(ad, oids):  # COMMIT_EDITMSG (beyond the spec list) is only comments or a checked tip's message
    git = lambda i, *a: subprocess.run(["git", "--git-dir", ad, *a], input=i, capture_output=True, check=True).stdout
    msgs, p = git("\n".join(oids).encode(), "log", "-z", "--no-walk=unsorted", "--stdin", "--format=%B").split(b"\0") + [b""], os.path.join(ad, "COMMIT_EDITMSG")
    return any(git(open(p, "rb").read(), "stripspace", *s) in msgs for s in ([], ["-s"]))

def describe(obj, deadline=None):  # bounded removal-time object metadata read
    cmd = [os.environ["DISK_MAGICIAN_STAT_BIN"], obj] if os.environ.get("DISK_MAGICIAN_STAT_BIN") else [
        "gcloud", "storage", "objects", "describe", obj, "--format=json"]
    result = _run_bounded(cmd, cap=10, deadline=deadline, step="object-read")
    if result is None:
        return None
    rc, out = result
    try:
        return json.loads(out) if rc == 0 else {}
    except ValueError:
        return {}

def provenance(root, lease, deadline=None):
    """stdin: the NUL-terminated repositories under root, then OK. ok when every file outside them
    is in a verified upload manifest (size, sha256) and its own object still holds that generation
    and hash (one describe per object per run); else kept:unproven-content."""
    *repos, ok, tail = sys.stdin.buffer.read().split(b"\0")
    if (ok, tail) != (b"OK", b""):
        return print("kept:check-failed")
    repos, files = set(map(os.fsdecode, repos)), [] if os.path.isdir(root) and not os.path.islink(root) else [root]
    left = _remaining(deadline, "tree-walk")
    if left is not None and left <= 0:
        return print("deferred:tree-walk")
    for dp, dns, fns in os.walk(root, onerror=lambda e: sys.exit("kept:check-failed")) if not files else ():
        left = _remaining(deadline, "tree-walk")
        if left is not None and left <= 0:
            return print("deferred:tree-walk")
        if dp in repos:
            dns[:] = []
            continue
        files += [os.path.join(dp, n) for n in fns + [d for d in dns if os.path.islink(os.path.join(dp, d))]]
    d = json.load(open(lease)) if files and os.path.isfile(lease) else {}
    ent = {e["path"]: e for e in d.get("upload_manifest") or [] if isinstance(e, dict)} if d.get("published_url") and d.get("verified_at") else {}
    seen = {}
    for f in files:
        e, st = ent.get(os.path.relpath(f, root), {}), os.lstat(f)
        if not stat.S_ISREG(st.st_mode):
            return print("kept:unproven-content")
        left = _remaining(deadline, "hash")
        if left is not None and left <= 0:
            return print("deferred:hash")
        try:
            digest = sha256(f, deadline)
        except TimeoutError:
            return print("deferred:hash")
        if not (stat.S_ISREG(st.st_mode) and e.get("size") == st.st_size and e.get("sha256") == digest):
            return print("kept:unproven-content")
        if e["object"] not in seen:
            seen[e["object"]] = describe(e["object"], deadline)
            if seen[e["object"]] is None:
                return print("deferred:object-read")
        m = seen[e["object"]]
        if not (m.get("generation") and str(m["generation"]) == str(e["generation"]) and (
                m["md5_hash"] == e["md5"] if m.get("md5_hash") else m.get("crc32c_hash") == e["crc32c"])):
            return print("kept:unproven-content")
    print("ok")

def sha256(p, deadline=None):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            left = _remaining(deadline, "hash")
            if left is not None and left <= 0:
                raise TimeoutError
            h.update(b)
    return h.hexdigest()

def inventory(root, out, deadline=None):
    """Create a race-checked, fd-relative JSON inventory and atomically publish it."""
    root = os.path.abspath(root)
    flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
    step = "tree-walk"
    entries = []
    try:
        rst = os.lstat(root)
        rfd = -1
        if stat.S_ISDIR(rst.st_mode):
            rfd = os.open(root, flags)
            rst = os.fstat(rfd)
        if not stat.S_ISDIR(rst.st_mode):
            parent, name = os.path.split(root)
            pfd = os.open(parent or ".", flags)
            try:
                st = os.stat(name, dir_fd=pfd, follow_symlinks=False)
                if stat.S_ISREG(st.st_mode):
                    step = "hash"
                    left = _remaining(deadline, "hash")
                    if left is not None and left <= 0:
                        raise TimeoutError
                    ffd = os.open(name, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0), dir_fd=pfd)
                    try:
                        before = os.fstat(ffd)
                        if (before.st_dev, before.st_ino, before.st_size) != (st.st_dev, st.st_ino, st.st_size):
                            raise OSError("file replaced")
                        h = hashlib.sha256()
                        while True:
                            left = _remaining(deadline, "hash")
                            if left is not None and left <= 0:
                                raise TimeoutError
                            block = os.read(ffd, 1 << 20)
                            if not block: break
                            h.update(block)
                        after = os.fstat(ffd)
                        if (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns) != (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns):
                            raise OSError("file changed")
                        entries.append({"path": ".", "type": "file", "dev": before.st_dev, "ino": before.st_ino,
                                        "size": before.st_size, "sha256": h.hexdigest(), "mtime_ns": before.st_mtime_ns})
                    finally: os.close(ffd)
                elif stat.S_ISLNK(st.st_mode):
                    target = os.readlink(name, dir_fd=pfd)
                    now = os.stat(name, dir_fd=pfd, follow_symlinks=False)
                    if (now.st_dev, now.st_ino) != (st.st_dev, st.st_ino): raise OSError("symlink replaced")
                    entries.append({"path": ".", "type": "symlink", "dev": st.st_dev, "ino": st.st_ino,
                                    "size": st.st_size, "target": target, "mtime_ns": st.st_mtime_ns})
                else:
                    raise OSError("unsupported entry type")
            finally: os.close(pfd)
            if not entries: return print("kept:check-failed")
        def add_dir(fd, rel, expected):
            left = _remaining(deadline, "tree-walk")
            if left is not None and left <= 0:
                raise TimeoutError
            opened = os.fstat(fd)
            if (opened.st_dev, opened.st_ino) != (expected.st_dev, expected.st_ino):
                raise OSError("directory replaced")
            entries.append({"path": rel, "type": "dir", "dev": opened.st_dev, "ino": opened.st_ino,
                            "size": opened.st_size, "mtime_ns": opened.st_mtime_ns})
            names = sorted(os.listdir(fd))
            for name in names:
                left = _remaining(deadline, "tree-walk")
                if left is not None and left <= 0:
                    raise TimeoutError
                if name in (".", "..") or "/" in name or "\0" in name:
                    raise OSError("invalid directory entry")
                st = os.stat(name, dir_fd=fd, follow_symlinks=False)
                child_rel = name if rel == "." else rel + "/" + name
                if stat.S_ISDIR(st.st_mode):
                    child = os.open(name, flags, dir_fd=fd)
                    try:
                        now = os.fstat(child)
                        if (now.st_dev, now.st_ino) != (st.st_dev, st.st_ino):
                            raise OSError("directory replaced")
                        add_dir(child, child_rel, st)
                        after = os.stat(name, dir_fd=fd, follow_symlinks=False)
                        if (after.st_dev, after.st_ino) != (st.st_dev, st.st_ino):
                            raise OSError("directory replaced")
                    finally:
                        os.close(child)
                elif stat.S_ISREG(st.st_mode):
                    step = "hash"
                    left = _remaining(deadline, "hash")
                    if left is not None and left <= 0:
                        raise TimeoutError
                    ffd = os.open(name, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0), dir_fd=fd)
                    try:
                        before = os.fstat(ffd)
                        if (before.st_dev, before.st_ino, before.st_size) != (st.st_dev, st.st_ino, st.st_size):
                            raise OSError("file replaced")
                        h = hashlib.sha256()
                        while True:
                            left = _remaining(deadline, "hash")
                            if left is not None and left <= 0:
                                raise TimeoutError
                            block = os.read(ffd, 1 << 20)
                            if not block:
                                break
                            h.update(block)
                        after = os.fstat(ffd)
                        if (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns) != (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns):
                            raise OSError("file changed")
                        entries.append({"path": child_rel, "type": "file", "dev": before.st_dev, "ino": before.st_ino,
                                        "size": before.st_size, "sha256": h.hexdigest(), "mtime_ns": before.st_mtime_ns})
                    finally:
                        os.close(ffd)
                elif stat.S_ISLNK(st.st_mode):
                    target = os.readlink(name, dir_fd=fd)
                    now = os.stat(name, dir_fd=fd, follow_symlinks=False)
                    if (now.st_dev, now.st_ino) != (st.st_dev, st.st_ino):
                        raise OSError("symlink replaced")
                    entries.append({"path": child_rel, "type": "symlink", "dev": st.st_dev, "ino": st.st_ino,
                                    "size": st.st_size, "target": target, "mtime_ns": st.st_mtime_ns})
                else:
                    raise OSError("unsupported entry type")
            after = os.fstat(fd)
            if (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns) != (
                    opened.st_dev, opened.st_ino, opened.st_size, opened.st_mtime_ns):
                raise OSError("directory changed")
        if rfd >= 0:
            step = "tree-walk"
            try: add_dir(rfd, ".", rst)
            finally: os.close(rfd)
        entries.sort(key=lambda entry: entry["path"])
        directory = os.path.dirname(os.path.abspath(out)) or "."
        fd, tmp = tempfile.mkstemp(prefix=".c14-inventory-", dir=directory)
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                json.dump(entries, f, separators=(",", ":"), sort_keys=True)
                f.flush(); os.fsync(f.fileno())
            left = _remaining(deadline, "tree-walk")
            if left is not None and left <= 0:
                raise TimeoutError
            os.replace(tmp, out)
            dfd = os.open(directory, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
            try: os.fsync(dfd)
            finally: os.close(dfd)
        finally:
            try: os.unlink(tmp)
            except FileNotFoundError: pass
        print("ok")
    except TimeoutError:
        print("deferred:" + step)
    except Exception:
        print("kept:check-failed")

def account(inv_file, ledger, reason):
    try:
        entries = json.load(open(inv_file, encoding="utf-8"))
        total = sum(e["size"] for e in entries if e.get("type") == "file")
        row = {"at": int(time.time()), "reason": reason, "bytes": total}
        fd = os.open(ledger, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
        try:
            os.write(fd, (json.dumps(row, separators=(",", ":")) + "\n").encode())
            os.fsync(fd)
        finally: os.close(fd)
        print("ok")
    except Exception:
        print("kept:check-failed")

def archive_receipt(source, receipt, archived_at=None, retention_minutes=None):
    """Write an exclusive, durable identity receipt for a directory before it moves."""
    try:
        st = os.lstat(source)
        if not stat.S_ISDIR(st.st_mode):
            raise ValueError("archive entries must be directories")
        retention = int(retention_minutes) if retention_minutes is not None else 0
        if retention < 0:
            raise ValueError("invalid retention")
        row = {"original_path": os.path.abspath(source), "dev": st.st_dev, "ino": st.st_ino,
               "size": st.st_size, "archived_at": int(archived_at) if archived_at else int(time.time()),
               "retention_minutes": retention}
        parent = os.path.dirname(os.path.abspath(receipt))
        fd = os.open(receipt, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o600)
        try:
            os.write(fd, (json.dumps(row, separators=(",", ":"), sort_keys=True) + "\n").encode())
            os.fsync(fd)
        finally:
            os.close(fd)
        dfd = os.open(parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
        try: os.fsync(dfd)
        finally: os.close(dfd)
        print("ok")
    except Exception:
        print("kept:archive-identity")
        return 1

def archive_info(candidate, receipt, inv_file):
    """Validate archive identity against both the live path and verdict inventory."""
    try:
        entries = json.load(open(inv_file, encoding="utf-8"))
        root = next(e for e in entries if e.get("path") == ".")
        st = os.lstat(candidate)
        if not stat.S_ISDIR(st.st_mode) or root.get("type") != "dir":
            raise ValueError("not an inventoried directory")
        identity = (st.st_dev, st.st_ino, st.st_size)
        if identity != (root.get("dev"), root.get("ino"), root.get("size")):
            raise ValueError("candidate changed")
        rst = os.lstat(receipt)
        if not stat.S_ISREG(rst.st_mode):
            raise ValueError("receipt is not a regular file")
        with open(receipt, "r", encoding="utf-8") as f:
            before = os.fstat(f.fileno())
            row = json.load(f)
            after = os.fstat(f.fileno())
        if (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns) != (
                rst.st_dev, rst.st_ino, rst.st_size, rst.st_mtime_ns) or (
                after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns) != (
                before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns):
            raise ValueError("receipt changed")
        original = row.get("original_path")
        dev, ino, archived_at = row.get("dev"), row.get("ino"), row.get("archived_at")
        retention = row.get("retention_minutes")
        if not isinstance(original, str) or not os.path.isabs(original) or type(dev) is not int or type(ino) is not int or type(archived_at) is not int or archived_at <= 0 or type(retention) is not int or retention < 0:
            raise ValueError("receipt fields missing")
        if (dev, ino) != identity[:2] or type(row.get("size")) is not int or row["size"] != st.st_size:
            raise ValueError("archive identity changed")
        if "sha256" in row:
            raise ValueError("unsupported receipt digest")
        print(json.dumps({"original_path": original, "archived_at": archived_at,
                          "retention_minutes": retention}, separators=(",", ":")))
    except Exception:
        print("kept:archive-identity")

def repos(inv_file):
    """Print discovered repository roots from a complete JSON inventory."""
    try:
        entries = json.load(open(inv_file, encoding="utf-8"))
        if not isinstance(entries, list): raise ValueError("inventory must be a list")
        by_path = {e["path"]: e for e in entries}
        roots = set()
        for rel, e in by_path.items():
            if rel == ".": parent, name = ".", "."
            else: parent, _, name = rel.rpartition("/"); parent = parent or "."
            if name == ".git" and e.get("type") in ("dir", "file"):
                roots.add(parent)
            if rel == "." and e.get("type") == "dir" and all(
                    by_path.get(name, {}).get("type") == kind for name, kind in
                    (("HEAD", "file"), ("objects", "dir"), ("refs", "dir"))):
                roots.add(".")
            if e.get("type") == "dir" and rel != ".git" and not rel.endswith("/.git"):
                if all(by_path.get(rel + "/" + name, {}).get("type") == kind for name, kind in
                       (("HEAD", "file"), ("objects", "dir"), ("refs", "dir"))):
                    roots.add(rel)
        root = os.path.dirname(os.path.abspath(inv_file))
        # Caller supplies C14_ROOT to bind relative inventory paths to its candidate.
        root = os.path.realpath(os.environ["C14_ROOT"])
        for rel in sorted(roots):
            print(os.path.join(root, rel) if rel != "." else root, end="\0")
    except Exception:
        print("kept:check-failed")

def newest_mtime(inv_file):
    try:
        entries = json.load(open(inv_file, encoding="utf-8"))
        mtimes = [e["mtime_ns"] // 1_000_000_000 for e in entries if type(e.get("mtime_ns")) is int]
        if not mtimes: raise ValueError("empty mtime inventory")
        print(max(mtimes))
    except Exception:
        print("kept:check-failed")

def secrets(inv_file):
    try:
        entries = json.load(open(inv_file, encoding="utf-8"))
        pattern = re.compile(r"^(?:\.env.*|.*\.(?:pem|key|p12|pfx)|id_(?:rsa|ed25519|ecdsa|dsa).*|\.npmrc|\.netrc|.*credentials.*|secrets.*)$", re.I)
        print("yes" if any(pattern.fullmatch(e["path"].rsplit("/", 1)[-1]) for e in entries) else "no")
    except Exception:
        print("kept:check-failed")

def merge_inventory(inv_file, admin_file, out_file):
    try:
        entries = json.load(open(inv_file, encoding="utf-8"))
        if os.path.isfile(admin_file):
            for line in open(admin_file, encoding="utf-8"):
                if line.strip():
                    entry = json.loads(line)
                    entry["type"] = "admin"
                    entries.append(entry)
        with open(out_file, "w", encoding="utf-8") as f:
            json.dump(entries, f, separators=(",", ":"), sort_keys=True)
            f.flush(); os.fsync(f.fileno())
        print("ok")
    except Exception:
        print("kept:check-failed")

def open_file(root, deadline=None):
    cmd = [os.environ.get("DISK_MAGICIAN_LSOF_BIN", "lsof"), "-w", "-n", "-P", "-Fn", "-a", "-d", "^cwd"]
    if os.path.isdir(root):
        cmd += ["+D", root]
    else:
        cmd += [root]
    result = _run_bounded(cmd, deadline=deadline, step="tree-walk", stderr=subprocess.STDOUT)
    if result is None:
        print("deferred:tree-walk")
    else:
        rc, out = result
        print("yes" if out else "no")

if __name__ == "__main__":
    a = sys.argv[1:]
    try:
        if len(a) == 3 and a[0] == "lsremote" and not a[1].startswith("-"):
            sys.exit(lsremote(a[1], a[2]))
        if len(a) in (3, 4) and a[0] == "lsremote":
            sys.exit(lsremote(a[1], a[2], a[3]))
        if len(a) in (2, 3) and a[0] == "gitmeta":
            sys.exit(gitmeta(*a[1:]))
        if len(a) in (2, 3) and a[0] == "admin":
            sys.exit(admin(*a[1:]))
        if len(a) in (3, 4) and a[0] == "provenance":
            sys.exit(provenance(*a[1:]))
        if len(a) in (3, 4) and a[0] == "inventory":
            sys.exit(inventory(a[1], a[2], a[3] if len(a) == 4 else None))
        if len(a) == 4 and a[0] == "account":
            sys.exit(account(*a[1:]))
        if len(a) in (3, 4, 5) and a[0] == "archive-receipt":
            sys.exit(archive_receipt(a[1], a[2], a[3] if len(a) >= 4 else None, a[4] if len(a) >= 5 else None))
        if len(a) == 4 and a[0] == "archive-info":
            sys.exit(archive_info(a[1], a[2], a[3]))
        if len(a) == 2 and a[0] == "repos":
            sys.exit(repos(a[1]))
        if len(a) == 2 and a[0] == "newest-mtime":
            sys.exit(newest_mtime(a[1]))
        if len(a) == 2 and a[0] == "secrets":
            sys.exit(secrets(a[1]))
        if len(a) == 4 and a[0] == "merge-inventory":
            sys.exit(merge_inventory(*a[1:]))
        if len(a) in (2, 3) and a[0] == "open-file":
            sys.exit(open_file(a[1], a[2] if len(a) == 3 and a[2] else None))
    except Exception:
        sys.exit("kept:check-failed")
    sys.exit("usage: c14_probe.py lsremote <url> <root> | gitmeta <gitdir> [<lease.json>] | admin <admindir> [<lease.json>] | provenance <root> <lease.json>")
