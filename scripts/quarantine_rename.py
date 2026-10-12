#!/usr/bin/env python3
"""C14 quarantine phase 1 (spec §7.2): `phase1 <path> <inventory.json>` prints quarantined:<id>, quarantine_conflict:<id> or kept:<why>."""
import ctypes, hashlib, json, os, secrets, stat, subprocess, sys
ENV, KEYS, DIRFL = os.environ, ("path", "type", "dev", "ino", "size", "sha256", "target"), os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
def renamex(src, dst):  # flag 0x4 = RENAME_EXCL; a missing symbol raises LookupError
    try: fn = ctypes.CDLL(None, use_errno=True)[ENV.get("DISK_MAGICIAN_TEST_RENAMEX_SYMBOL", "renamex_np")]
    except (AttributeError, OSError): raise LookupError
    if fn(os.fsencode(src), os.fsencode(dst), ctypes.c_uint(4)): raise OSError(ctypes.get_errno(), "renamex_np")
def hook(name, path, dest):
    if ENV.get(name): subprocess.run(["bash", "-c", ENV[name]], env=dict(ENV, DM_Q_PATH=path, DM_Q_DEST=dest), stdout=subprocess.DEVNULL)
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
def verify(dest, rec):  # "" = identity, live-user and re-hash checks all pass; any exception keeps (rollback)
    canon = lambda es: sorted(json.dumps([None if k == "size" and e.get("type") != "file" else e.get(k) for k in KEYS]) for e in es)
    try:
        d = os.lstat(dest)
        if (d.st_dev, d.st_ino) != (rec["dev"], rec["ino"]): return "identity-mismatch"
        lsof = subprocess.run(["lsof", "-nP", "+D" if stat.S_ISDIR(d.st_mode) else "--", dest], capture_output=True, timeout=120)  # +D is dirs-only
        if lsof.stdout or lsof.returncode != 1 or lsof.stderr.strip(): return "live-user" if lsof.stdout or not lsof.returncode else "check-failed"
        return "" if canon(visit(None, dest, ".", [])) == canon(rec["inventory"]) else "rehash-mismatch"
    except Exception: return "check-failed"
def phase1(path, inv_file):
    path = os.path.abspath(path); hook("DISK_MAGICIAN_TEST_AFTER_VERDICT", path, "")
    try:
        with open(inv_file) as f: inv = [e for e in json.load(f) if isinstance(e, dict)]
        qdir = os.path.join(os.path.realpath(os.path.dirname(path)), ".dm-quarantine"); os.makedirs(qdir, 0o700, exist_ok=True); q, st = os.lstat(qdir), os.lstat(path)
        if not stat.S_ISDIR(q.st_mode) or q.st_uid != os.getuid() or q.st_mode & 0o777 != 0o700: return "kept:quarantine-dir-unsafe"
        if [(st.st_dev, st.st_ino)] != [(e.get("dev"), e.get("ino")) for e in inv if e.get("path") == "."]: return "kept:identity-mismatch"
        if os.stat(qdir).st_dev != st.st_dev: return "kept:cross-device"  # never copy
    except Exception: return "kept:check-failed"
    qid = secrets.token_hex(8); dest = os.path.join(qdir, qid); side = dest + ".json"
    rec = {"id": qid, "original": path, "dev": st.st_dev, "ino": st.st_ino, "inventory": inv, "phase": "intent"}
    try:
        with os.fdopen(os.open(side, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "w") as f:
            if ENV.get("DISK_MAGICIAN_TEST_INTENT_ERRNO"): raise OSError(int(ENV["DISK_MAGICIAN_TEST_INTENT_ERRNO"]), "test")
            f.write(json.dumps(rec)); f.flush(); os.fsync(f.fileno())
    except OSError:  # ENOSPC aborts before the rename; the artifact stays in place
        if os.path.lexists(side): os.unlink(side)
        return "kept:intent-write-failed"
    hook("DISK_MAGICIAN_TEST_BEFORE_QUARANTINE_RENAME", path, dest)
    try: renamex(path, dest)  # commit point
    except (LookupError, OSError) as e:
        os.unlink(side); return "kept:exclusive_rename_unavailable" if isinstance(e, LookupError) else "kept:rename-failed"
    hook("DISK_MAGICIAN_TEST_AFTER_QUARANTINE", path, dest)
    why = verify(dest, rec)
    if not why: return f"quarantined:{qid}"
    try: renamex(dest, path)
    except OSError: return f"quarantine_conflict:{qid}"  # original recreated (EEXIST): stays quarantined, sidecar kept
    os.unlink(side); return f"kept:{why}"
if __name__ == "__main__": print(phase1(*sys.argv[2:]) if sys.argv[1:2] == ["phase1"] and len(sys.argv) == 4 else "kept:check-failed")
