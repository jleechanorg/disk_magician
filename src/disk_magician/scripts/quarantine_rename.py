#!/usr/bin/env python3
"""C14 quarantine phase 1: bind the parent before verdict, then `phase1 <path> <inventory.json> <parent-binding.json>`."""
import ctypes, hashlib, json, os, secrets, stat, subprocess, sys
ENV, KEYS, DIRFL = os.environ, ("path", "type", "dev", "ino", "size", "sha256", "target"), os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
UPDATE_COUNT = 0
def renamex(srcfd, src, dstfd, dst):  # flag 0x4 = RENAME_EXCL; a missing symbol raises LookupError
    try: fn = ctypes.CDLL(None, use_errno=True)[ENV.get("DISK_MAGICIAN_TEST_RENAMEX_SYMBOL", "renameatx_np")]
    except (AttributeError, OSError): raise LookupError
    if fn(srcfd, os.fsencode(src), dstfd, os.fsencode(dst), ctypes.c_uint(4)): raise OSError(ctypes.get_errno(), "renameatx_np")
def hook(name, path, dest):
    if ENV.get(name): subprocess.run(["bash", "-c", ENV[name]], env=dict(ENV, DM_Q_PATH=path, DM_Q_DEST=dest), stdout=subprocess.DEVNULL)
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
        return "kept:intent-write-failed"
    dest = os.path.join(qdir, qid)
    hook("DISK_MAGICIAN_TEST_BEFORE_QUARANTINE_RENAME", path, dest)
    if not same_entry(pfd, ".dm-quarantine", q): return f"quarantine_conflict:{qid}"
    if not same_entry(pfd, base, st):
        try: os.unlink(side, dir_fd=qfd)
        except OSError: pass
        return "kept:identity-mismatch"
    try: renamex(pfd, base, qfd, qid)  # commit point; both directory bindings stay pinned
    except (LookupError, OSError) as e:
        try: os.unlink(side, dir_fd=qfd)
        except OSError: pass
        return "kept:exclusive_rename_unavailable" if isinstance(e, LookupError) else "kept:rename-failed"
    try:
        os.fsync(pfd); os.fsync(qfd)
    except OSError: return f"quarantine_conflict:{qid}"
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
    return f"kept:{why}"
if __name__ == "__main__":
    args = sys.argv[1:]
    if args[:1] == ["bind"] and len(args) == 3: print(bind_parent(args[1], args[2]))
    elif args[:1] == ["candidate"] and len(args) == 2: print(bound_candidate(args[1]))
    elif args[:1] == ["phase1"] and len(args) == 4: print(phase1(*args[1:]))
    else: print("kept:check-failed")
