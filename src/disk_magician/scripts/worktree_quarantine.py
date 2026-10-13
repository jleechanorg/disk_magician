#!/usr/bin/env python3
"""Recoverable quarantine for an already-approved worktree removal.

The caller supplies the C14 checkout inventory produced by the removal
verdict.  This module journals the Git admin-directory changes before moving
the checkout, then tears down only that worktree's admin directory after the
checkout has been removed through quarantine_rename's fd-relative walker.
"""
import hashlib
import json
import os
import secrets
import stat
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import quarantine_rename as qr

DIR = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW


def run(*args):
    return subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True)


def digest(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def restore_gitdir(admin, expected):
    """Restore the captured gitdir bytes without following a retargeted path."""
    dfd = os.open(admin, DIR)
    try:
        before = os.stat("gitdir", dir_fd=dfd, follow_symlinks=False)
        if not stat.S_ISREG(before.st_mode):
            raise OSError("gitdir is not a regular file")
        fd = os.open("gitdir", os.O_WRONLY | os.O_NOFOLLOW, dir_fd=dfd)
        try:
            opened = os.fstat(fd)
            if (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino):
                raise OSError("gitdir replaced")
            os.ftruncate(fd, 0)
            view = memoryview(expected)
            while view:
                n = os.write(fd, view)
                if n <= 0: raise OSError("short gitdir restore")
                view = view[n:]
            os.fsync(fd)
            after = os.stat("gitdir", dir_fd=dfd, follow_symlinks=False)
            if (after.st_dev, after.st_ino) != (opened.st_dev, opened.st_ino):
                raise OSError("gitdir replaced during restore")
        finally:
            os.close(fd)
        os.fsync(dfd)
    finally:
        os.close(dfd)


def inventory(path):
    fd, out = tempfile.mkstemp(prefix=".wrh-inventory-")
    os.close(fd)
    try:
        result = run(sys.executable, str(HERE / "c14_probe.py"), "inventory", path, out)
        if result.stdout.strip() != b"ok":
            raise OSError("inventory failed")
        with open(out, encoding="utf-8") as f:
            entries = json.load(f)
        if not isinstance(entries, list):
            raise ValueError("inventory malformed")
        return entries
    finally:
        try:
            os.unlink(out)
        except FileNotFoundError:
            pass


def admin_path(wt):
    return run("git", "-C", wt, "rev-parse", "--absolute-git-dir").stdout.decode().strip()


def canonical(entries, exclude=()):
    normalized = []
    for entry in entries:
        if entry.get("path") in exclude:
            continue
        normalized.append({k: entry.get(k) for k in ("path", "type", "dev", "ino", "size", "sha256", "target")
                           if k in entry and not (entry.get("type") == "dir" and k == "size")})
    return sorted(json.dumps(e, sort_keys=True, separators=(",", ":")) for e in normalized)


def check_admin(record, lock=True, repaired=True):
    base = record["worktree_admin_inventory"]
    path = record["worktree_admin_path"]
    current = inventory(path)
    allowed = {"locked", "gitdir"}
    if canonical(base, allowed) != canonical(current, allowed):
        return False
    by_path = {e.get("path"): e for e in current}
    locked = by_path.get("locked")
    gitdir = by_path.get("gitdir")
    if lock:
        if not locked or locked.get("sha256") != record.get("locked_sha256"):
            return False
    elif locked is not None:
        return False
    expected_gitdir = record.get("repaired_gitdir_sha256") if repaired else record.get("original_gitdir_sha256")
    if not gitdir or gitdir.get("sha256") != expected_gitdir:
        return False
    return True


def write_record(parent_fd, qfd, name, record):
    qr.update_sidecar(qfd, name, record)


def safe_rename(srcfd, src, dstfd, dst):
    qr.renamex(srcfd, src, dstfd, dst)


def phase1(main, worktree, inventory_file):
    main, worktree = os.path.realpath(main), os.path.abspath(worktree)
    parent, base = os.path.dirname(worktree), os.path.basename(worktree)
    try:
        with open(inventory_file, encoding="utf-8") as f:
            checkout_inventory = json.load(f)
        root = next(e for e in checkout_inventory if e.get("path") == ".")
        if root.get("type") != "dir" or any(type(root.get(k)) is not int for k in ("dev", "ino")):
            return "kept:identity-mismatch"
        admin = admin_path(worktree)
        admin_inventory = inventory(admin)
        admin_root = next(e for e in admin_inventory if e.get("path") == ".")
        old_gitdir = next(e for e in admin_inventory if e.get("path") == "gitdir")
        if any(e.get("path") == "locked" for e in admin_inventory):
            return "kept:already-locked"
        pfd = os.open(parent, DIR)
        try:
            pstat = os.fstat(pfd)
            st = os.stat(base, dir_fd=pfd, follow_symlinks=False)
            if not stat.S_ISDIR(st.st_mode) or (st.st_dev, st.st_ino) != (root["dev"], root["ino"]):
                return "kept:identity-mismatch"
            try:
                os.mkdir(".dm-quarantine", 0o700, dir_fd=pfd)
            except FileExistsError:
                pass
            qst = os.stat(".dm-quarantine", dir_fd=pfd, follow_symlinks=False)
            if not stat.S_ISDIR(qst.st_mode) or qst.st_uid != os.getuid() or qst.st_mode & 0o777 != 0o700:
                return "kept:quarantine-dir-unsafe"
            qfd = os.open(".dm-quarantine", DIR, dir_fd=pfd)
            try:
                qopened = os.fstat(qfd)
                if (qopened.st_dev, qopened.st_ino) != (qst.st_dev, qst.st_ino) or st.st_dev != qst.st_dev:
                    return "kept:quarantine-dir-unsafe"
                qid = secrets.token_hex(8)
                side = qid + ".json"
                qpath = os.path.join(parent, ".dm-quarantine", qid)
                reason = "dm-quarantine:" + qid
                record = {
                    "schema": 1, "id": qid, "original": worktree, "dev": st.st_dev, "ino": st.st_ino,
                    "parent_dev": pstat.st_dev, "parent_ino": pstat.st_ino,
                    "quarantine_dev": qst.st_dev, "quarantine_ino": qst.st_ino,
                    "inventory": checkout_inventory, "phase": "intent", "removed_paths": [],
                    "worktree_admin": True, "worktree_admin_path": admin,
                    "worktree_admin_inventory": admin_inventory, "worktree_main": main,
                    "worktree_reason": reason, "wrh_phase": "intent",
                    "original_gitdir_sha256": old_gitdir.get("sha256"),
                    "original_gitdir_hex": Path(os.path.join(admin, "gitdir")).read_bytes().hex(),
                }
                qr.index_write(qid, qr.index_record(qid, parent, pstat, qst))
                fd = os.open(side, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=qfd)
                try:
                    data = json.dumps(record, separators=(",", ":")).encode()
                    os.write(fd, data); os.fsync(fd)
                finally:
                    os.close(fd)
                os.fsync(qfd)
                try:
                    qr.hook("DISK_MAGICIAN_TEST_AFTER_VERDICT", worktree, qpath)
                    run("git", "-C", main, "worktree", "lock", "--reason", reason, worktree)
                    record["wrh_phase"] = "locked"
                    record["locked_sha256"] = digest(os.path.join(admin, "locked"))
                    write_record(pfd, qfd, side, record)
                    if os.environ.get("DISK_MAGICIAN_TEST_WRH_KILL_AT") == "after_lock": os.kill(os.getpid(), 9)
                    if not qr.same_entry(pfd, base, st): raise OSError("checkout changed")
                    safe_rename(pfd, base, qfd, qid)
                    os.fsync(pfd); os.fsync(qfd)
                    record["wrh_phase"] = "renamed"
                    write_record(pfd, qfd, side, record)
                    if os.environ.get("DISK_MAGICIAN_TEST_WRH_KILL_AT") == "after_rename": os.kill(os.getpid(), 9)
                    run("git", "-C", main, "worktree", "repair", qpath)
                    record["wrh_phase"] = "repaired"
                    record["repaired_gitdir_sha256"] = digest(os.path.join(admin, "gitdir"))
                    write_record(pfd, qfd, side, record)
                    if os.environ.get("DISK_MAGICIAN_TEST_WRH_KILL_AT") == "after_repair": os.kill(os.getpid(), 9)
                    qr.hook("DISK_MAGICIAN_TEST_WRH_AFTER_REPAIR", admin, qpath)
                    if not check_admin(record):
                        return rollback(pfd, qfd, qid, record)
                    record["worktree_admin_teardown_inventory"] = inventory(admin)
                    record["wrh_phase"] = "ready"
                    write_record(pfd, qfd, side, record)
                    return "quarantined:" + qid
                except Exception:
                    return rollback(pfd, qfd, qid, record)
            finally:
                os.close(qfd)
        finally:
            os.close(pfd)
    except Exception:
        return "kept:check-failed"


def rollback(pfd, qfd, qid, record):
    parent = record["original"].rsplit("/", 1)[0]
    base = os.path.basename(record["original"])
    admin = record["worktree_admin_path"]
    try:
        try: original_st = os.stat(base, dir_fd=pfd, follow_symlinks=False)
        except FileNotFoundError: original_st = None
        try: qst = os.stat(qid, dir_fd=qfd, follow_symlinks=False)
        except FileNotFoundError: qst = None
        if original_st is not None and qst is not None:
            return "quarantine_conflict:" + qid
        if original_st is not None and (original_st.st_dev, original_st.st_ino) != (record["dev"], record["ino"]):
            return "quarantine_conflict:" + qid
        if qst is not None:
            if (qst.st_dev, qst.st_ino) != (record["dev"], record["ino"]): return "quarantine_conflict:" + qid
            qpath = os.path.join(parent, ".dm-quarantine", qid)
            restore_gitdir(admin, (qpath + "/.git\n").encode())
            run("git", "-C", record["worktree_main"], "worktree", "repair", qpath)
            safe_rename(qfd, qid, pfd, base); os.fsync(qfd); os.fsync(pfd)
            run("git", "-C", record["worktree_main"], "worktree", "repair", record["original"])
        locked = os.path.join(admin, "locked")
        if os.path.exists(locked):
            if record.get("locked_sha256") and digest(locked) == record.get("locked_sha256"):
                run("git", "-C", record["worktree_main"], "worktree", "unlock", record["original"])
        if record.get("original_gitdir_hex"):
            restore_gitdir(admin, bytes.fromhex(record["original_gitdir_hex"]))
        restored = os.stat(base, dir_fd=pfd, follow_symlinks=False)
        if (restored.st_dev, restored.st_ino) != (record["dev"], record["ino"]):
            return "quarantine_conflict:" + qid
        side = qid + ".json"
        try: os.unlink(side, dir_fd=qfd); os.fsync(qfd)
        except FileNotFoundError: pass
        if not qr.index_drop(qid): return "quarantine_conflict:" + qid
        return "kept:admin-changed"
    except Exception:
        return "quarantine_conflict:" + qid


def phase2(qid):
    try:
        index, pfd, qfd, record = qr.indexed_item(qid)
    except Exception:
        return "kept:quarantine_partial_kept"
    try:
        if record.get("worktree_admin") is not True:
            return "kept:quarantine_partial_kept"
        if not record.get("root_removed") and not check_admin(record):
            return "kept:quarantine_partial_kept"
        binding = {"parent_path": index["parent_path"], "parent_dev": index["parent_dev"], "parent_ino": index["parent_ino"]}
        fd, bind = tempfile.mkstemp(prefix=".wrh-bind-")
        try:
            with os.fdopen(fd, "w") as f: json.dump(binding, f)
            result = qr.phase2(bind, qid)
        finally:
            try: os.unlink(bind)
            except OSError: pass
        if result not in ("checkout_removed", "removed"):
            return "kept:quarantine_partial_kept"
        if os.environ.get("DISK_MAGICIAN_TEST_WRH_KILL_AT") == "after_checkout_removed":
            os.kill(os.getpid(), 9)
        # The checkout is gone. The only remaining deletion is this worktree's
        # pinned admin directory; remove it using the same fd walker as C14.
        admin = record["worktree_admin_path"]
        admin_inv, children = qr.inventory_children(record["worktree_admin_teardown_inventory"])
        afd = os.open(os.path.dirname(admin), DIR)
        try:
            try:
                root = os.stat(os.path.basename(admin), dir_fd=afd, follow_symlinks=False)
            except FileNotFoundError:
                root = None
            if root is not None:
                if (root.st_dev, root.st_ino) != (admin_inv["."]["dev"], admin_inv["."]["ino"]):
                    return "kept:quarantine_partial_kept"
                admin_record = dict(record)
                admin_record["journal_key"] = "admin_removed_paths"
                admin_record["admin_removed_paths"] = list(record.get("admin_removed_paths", []))
                if not qr.unlink_inventory_entry(afd, os.path.basename(admin), ".", admin_inv["."], admin_inv, children,
                                                 qfd=qfd, side=qid + ".json", record=admin_record,
                                                 removed_paths=set(record.get("admin_removed_paths", []))):
                    return "kept:quarantine_partial_kept"
        finally:
            os.close(afd)
        listing = run("git", "-C", record["worktree_main"], "worktree", "list", "--porcelain").stdout.decode()
        qpath = os.path.join(index["parent_path"], ".dm-quarantine", qid)
        if "worktree " + qpath in listing or os.path.exists(admin):
            return "kept:quarantine_partial_kept"
        os.unlink(qid + ".json", dir_fd=qfd); os.fsync(qfd)
        if not qr.index_drop(qid): return "kept:quarantine_partial_kept"
        return "removed"
    except Exception:
        return "kept:quarantine_partial_kept"
    finally:
        os.close(qfd); os.close(pfd)


def restore(qid):
    try:
        index, pfd, qfd, record = qr.indexed_item(qid)
    except Exception:
        return "kept:unknown-quarantine-id"
    try:
        if record.get("worktree_admin") is not True or record.get("phase") == "deleting":
            return "kept:quarantine_partial_kept"
        parent, base = index["parent_path"], os.path.basename(record["original"])
        try: os.stat(base, dir_fd=pfd, follow_symlinks=False); return "kept:restore-target-exists"
        except FileNotFoundError: pass
        qst = os.stat(qid, dir_fd=qfd, follow_symlinks=False)
        if (qst.st_dev, qst.st_ino) != (record["dev"], record["ino"]): return "kept:identity-mismatch"
        if canonical(qr.visit(qfd, qid, ".", [])) != canonical(record["inventory"]):
            return "kept:quarantine_partial_kept"
        safe_rename(qfd, qid, pfd, base); os.fsync(qfd); os.fsync(pfd)
        original = record["original"]
        run("git", "-C", record["worktree_main"], "worktree", "repair", original)
        if record.get("original_gitdir_hex"):
            restore_gitdir(record["worktree_admin_path"], bytes.fromhex(record["original_gitdir_hex"]))
        locked = os.path.join(record["worktree_admin_path"], "locked")
        if os.path.exists(locked):
            if digest(locked) != record.get("locked_sha256"): return "kept:lock-owner-mismatch"
            run("git", "-C", record["worktree_main"], "worktree", "unlock", original)
        if canonical(record["worktree_admin_inventory"]) != canonical(inventory(record["worktree_admin_path"])):
            return "kept:admin-changed"
        os.unlink(qid + ".json", dir_fd=qfd); os.fsync(qfd)
        if not qr.index_drop(qid): return "kept:quarantine_partial_kept"
        return "restored:" + qid
    except Exception:
        return "kept:quarantine_partial_kept"
    finally:
        os.close(qfd); os.close(pfd)


def reconcile():
    try:
        directory = qr.index_dir()
        ids = sorted(n[:-5] for n in os.listdir(directory) if len(n) == 21 and n.endswith(".json") and
                     all(c in "0123456789abcdef" for c in n[:-5]))
        for qid in ids:
            try: _, pfd, qfd, record = qr.indexed_item(qid)
            except Exception: continue
            try:
                if record.get("worktree_admin") is not True: continue
                phase = record.get("wrh_phase")
                if phase == "checkout_removed" or record.get("phase") == "deleting":
                    print(qid + ":" + phase2(qid)); continue
                print(qid + ":" + rollback(pfd, qfd, qid, record))
            finally:
                os.close(qfd); os.close(pfd)
        return 0
    except Exception:
        return 1


if __name__ == "__main__":
    args = sys.argv[1:]
    if len(args) == 4 and args[0] == "phase1": print(phase1(*args[1:]))
    elif len(args) == 2 and args[0] == "phase2": print(phase2(args[1]))
    elif len(args) == 2 and args[0] == "restore": print(restore(args[1]))
    elif args == ["reconcile"]: sys.exit(reconcile())
    else: print("kept:check-failed")
