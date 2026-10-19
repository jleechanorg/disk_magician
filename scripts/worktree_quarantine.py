#!/usr/bin/env python3
"""Recoverable quarantine for an already-approved worktree removal.

The caller supplies the C14 checkout inventory produced by the removal
verdict.  This module journals the Git admin-directory changes before moving
the checkout, then tears down only that worktree's admin directory after the
checkout has been removed through quarantine_rename's fd-relative walker.
"""
import hashlib
import json
import math
import os
import secrets
import stat
import subprocess
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import quarantine_rename as qr

DIR = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW


def run(*args, deadline=None):
    timeout = qr.remaining_seconds(deadline)
    if timeout is not None and timeout <= 0: raise qr.DeadlineExceeded()
    try:
        return subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True,
                              timeout=None if timeout is None else timeout)
    except subprocess.TimeoutExpired:
        raise qr.DeadlineExceeded()


def digest(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def open_admin(record):
    """Open only the captured C14 admin and gitdir incarnations, or fail closed."""
    entries, _ = qr.inventory_children(record["worktree_admin_inventory"])
    root, gitdir = entries["."], entries["gitdir"]
    if root["type"] != "dir" or gitdir["type"] != "file":
        raise OSError("invalid admin identity")
    dfd = os.open(record["worktree_admin_path"], DIR)
    try:
        opened = os.fstat(dfd)
        current = os.stat("gitdir", dir_fd=dfd, follow_symlinks=False)
        if ((opened.st_dev, opened.st_ino) != (root["dev"], root["ino"]) or
                not stat.S_ISREG(current.st_mode) or
                (current.st_dev, current.st_ino) != (gitdir["dev"], gitdir["ino"])):
            raise OSError("admin identity changed")
        return dfd
    except Exception:
        os.close(dfd)
        raise


def restore_gitdir(record, expected):
    """Restore the captured gitdir bytes without following a retargeted path."""
    dfd = open_admin(record)
    try:
        entries, _ = qr.inventory_children(record["worktree_admin_inventory"])
        captured = entries["gitdir"]
        before = os.stat("gitdir", dir_fd=dfd, follow_symlinks=False)
        if (not stat.S_ISREG(before.st_mode) or
                (before.st_dev, before.st_ino) != (captured["dev"], captured["ino"])):
            raise OSError("gitdir identity changed")
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


def inventory(path, deadline=None):
    fd, out = tempfile.mkstemp(prefix=".wrh-inventory-")
    os.close(fd)
    try:
        args = [sys.executable, str(HERE / "c14_probe.py"), "inventory", path, out]
        if deadline is not None: args.append(str(deadline))
        result = run(*args, deadline=deadline)
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


def admin_path(wt, deadline=None):
    return run("git", "-C", wt, "rev-parse", "--absolute-git-dir", deadline=deadline).stdout.decode().strip()


def canonical(entries, exclude=()):
    return qr.canon_inventory(e for e in entries if e.get("path") not in exclude)


def admin_entries(rows):
    """Normalize C14 admin receipt rows (entry_type dir/file) into inventory entries."""
    normalized = []
    for row in rows:
        if not isinstance(row, dict) or not isinstance(row.get("path"), str):
            raise ValueError("malformed admin receipt row")
        if any(type(row.get(k)) is not int for k in ("dev", "ino")):
            raise ValueError("incomplete admin receipt row")
        kind = row.get("entry_type") or ("file" if isinstance(row.get("sha256"), str) else "dir")
        if kind == "dir":
            normalized.append({"path": row["path"], "type": "dir", "dev": row["dev"], "ino": row["ino"]})
        elif kind == "file":
            if not isinstance(row.get("sha256"), str) or type(row.get("size")) is not int:
                raise ValueError("incomplete admin file row")
            normalized.append({"path": row["path"], "type": "file", "dev": row["dev"],
                               "ino": row["ino"], "size": row["size"], "sha256": row["sha256"]})
        else:
            raise ValueError("unsupported admin entry type")
    return normalized


def admin_current_inventory(path, deadline=None):
    return inventory(path, deadline)


def check_admin(record, lock=True, repaired=True, deadline=None):
    base = record["worktree_admin_inventory"]
    current = admin_current_inventory(record["worktree_admin_path"], deadline)
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


def phase1(main, worktree, inventory_file, deadline=None):
    if qr.deadline_passed(deadline): return "deferred:deadline"
    main, worktree = os.path.realpath(main), os.path.abspath(worktree)
    parent, base = os.path.dirname(worktree), os.path.basename(worktree)
    try:
        with open(inventory_file, encoding="utf-8") as f:
            receipt = json.load(f)
        if not isinstance(receipt, list): return "kept:admin-proof-missing"
        admin_rows = [e for e in receipt if isinstance(e, dict) and e.get("type") == "admin"]
        checkout_inventory = [e for e in receipt if not (isinstance(e, dict) and e.get("type") == "admin")]
        root = next(e for e in checkout_inventory if e.get("path") == ".")
        if root.get("type") != "dir" or any(type(root.get(k)) is not int for k in ("dev", "ino")):
            return "kept:identity-mismatch"
        if not admin_rows: return "kept:admin-proof-missing"
        # Bind to the selected worktree's own C14 admin receipt rows; never refresh proof.
        admin = os.path.realpath(admin_path(worktree, deadline))
        admins = {os.path.realpath(r["admin"]) for r in admin_rows
                  if isinstance(r.get("admin"), str) and r.get("admin")}
        if len(admins) != 1 or admins != {admin}: return "kept:admin-proof-mismatch"
        try:
            admin_inventory = admin_entries(admin_rows)
        except ValueError:
            return "kept:admin-proof-missing"
        old_gitdir = next((e for e in admin_inventory if e.get("path") == "gitdir"), None)
        if old_gitdir is None: return "kept:admin-proof-missing"
        if any(e.get("path") == "locked" for e in admin_inventory):
            return "kept:already-locked"
        # The live admin dir must still equal the C14 receipt before any own write.
        if canonical(admin_inventory) != canonical(admin_current_inventory(admin, deadline)):
            return "kept:admin-changed"
        if qr.deadline_passed(deadline): return "deferred:deadline"
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
                    # Durable expected lock identity: git writes exactly the
                    # lock reason plus a trailing newline. Recording the digest
                    # BEFORE `git worktree lock` lets reconcile disambiguate
                    # our own lock from a foreign one after a crash in the
                    # window between lock and journal, without adopting
                    # arbitrary current lock contents.
                    "locked_sha256": hashlib.sha256((reason + "\n").encode()).hexdigest(),
                    "original_gitdir_sha256": old_gitdir.get("sha256"),
                    "original_gitdir_hex": Path(os.path.join(admin, "gitdir")).read_bytes().hex(),
                }
                qr.index_write(qid, qr.index_record(qid, parent, pstat, qst, worktree, st))
                if os.environ.get("DISK_MAGICIAN_TEST_WRH_KILL_AT") == "after_index": os.kill(os.getpid(), 9)
                fd = os.open(side, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=qfd)
                try:
                    data = json.dumps(record, separators=(",", ":")).encode()
                    os.write(fd, data); os.fsync(fd)
                finally:
                    os.close(fd)
                os.fsync(qfd)
                try:
                    qr.hook("DISK_MAGICIAN_TEST_AFTER_VERDICT", worktree, qpath)
                    if qr.deadline_passed(deadline):
                        if not qr.finish_sidecar(qfd, qid, "original"): return f"quarantine_conflict:{qid}:index-cleanup-failed"
                        return "deferred:deadline"
                    os.close(open_admin(record))
                    run("git", "-C", main, "worktree", "lock", "--reason", reason, worktree, deadline=deadline)
                    record["wrh_phase"] = "locked"
                    if not check_admin(record, lock=True, repaired=False, deadline=deadline):
                        raise OSError("admin changed after lock")
                    # Kill between the lock and its journal entry: the sidecar
                    # already carries the expected lock digest, so reconcile
                    # can clear exactly this owned lock and repair the gitdir.
                    if os.environ.get("DISK_MAGICIAN_TEST_WRH_KILL_AT") == "after_lock_before_journal": os.kill(os.getpid(), 9)
                    write_record(pfd, qfd, side, record)
                    if os.environ.get("DISK_MAGICIAN_TEST_WRH_KILL_AT") == "after_lock": os.kill(os.getpid(), 9)
                    if not qr.same_entry(pfd, base, st): raise OSError("checkout changed")
                    safe_rename(pfd, base, qfd, qid)
                    os.fsync(pfd); os.fsync(qfd)
                    record["wrh_phase"] = "renamed"
                    write_record(pfd, qfd, side, record)
                    if os.environ.get("DISK_MAGICIAN_TEST_WRH_KILL_AT") == "after_rename": os.kill(os.getpid(), 9)
                    why = qr.verify(pfd, qfd, qst, qid, {"dev": st.st_dev, "ino": st.st_ino, "inventory": checkout_inventory},
                                    os.path.join(parent, ".dm-quarantine"), deadline)
                    if why in ("identity-mismatch", "quarantine-dir-changed"): return f"quarantine_conflict:{qid}"
                    if why: return rollback(pfd, qfd, qid, record, reason=why)
                    if qr.deadline_passed(deadline): raise qr.DeadlineExceeded()
                    os.close(open_admin(record))
                    run("git", "-C", main, "worktree", "repair", qpath, deadline=deadline)
                    record["wrh_phase"] = "repaired"
                    record["repaired_gitdir_sha256"] = digest(os.path.join(admin, "gitdir"))
                    write_record(pfd, qfd, side, record)
                    if os.environ.get("DISK_MAGICIAN_TEST_WRH_KILL_AT") == "after_repair": os.kill(os.getpid(), 9)
                    qr.hook("DISK_MAGICIAN_TEST_WRH_AFTER_REPAIR", admin, qpath)
                    if not check_admin(record, deadline=deadline):
                        return rollback(pfd, qfd, qid, record)
                    record["worktree_admin_teardown_inventory"] = inventory(admin, deadline)
                    record["wrh_phase"] = "ready"
                    write_record(pfd, qfd, side, record)
                    return "quarantined:" + qid
                except qr.DeadlineExceeded:
                    return rollback(pfd, qfd, qid, record, reason="deferred:deadline")
                except Exception as e:
                    # Was defaulting to rollback(..., reason="admin-changed"),
                    # which mislabelled an exclusive-rename LookupError on Linux
                    # as an admin-inventory change. Name the real failure.
                    return rollback(pfd, qfd, qid, record, reason="quarantine-error:%s" % type(e).__name__)
            finally:
                os.close(qfd)
        finally:
            os.close(pfd)
    except qr.DeadlineExceeded:
        return "deferred:deadline"
    except Exception:
        return "kept:check-failed"


def bind_restored_checkout(pfd, qfd, qid, record):
    """Pin the restored generation before Git writes; caller closes the fd."""
    base = os.path.basename(record["original"])
    restored_fd = -1
    restored = None
    matches = False
    try:
        restored = os.stat(base, dir_fd=pfd, follow_symlinks=False)
        restored_fd = os.open(base, DIR, dir_fd=pfd)
        opened = os.fstat(restored_fd)
        matches = ((opened.st_dev, opened.st_ino) == (record["dev"], record["ino"]) and
                   (restored.st_dev, restored.st_ino) == (opened.st_dev, opened.st_ino) and
                   qr.same_entry(pfd, base, opened))
    except OSError:
        pass
    if matches:
        return restored_fd, ""
    if restored_fd >= 0:
        os.close(restored_fd)
    record["phase"] = record["wrh_phase"] = "restore_conflict"
    record["restore_conflict"] = {
        "expected": {"dev": record["dev"], "ino": record["ino"]},
        "observed": None if restored is None else {"dev": restored.st_dev, "ino": restored.st_ino},
        "original_path": record["original"],
    }
    try: qr.update_sidecar(qfd, qid + ".json", record)
    except OSError: return -1, f"quarantine_conflict:{qid}:restore-state-update-failed"
    return -1, "kept:restore-identity-mismatch"


def rollback(pfd, qfd, qid, record, reason="admin-changed"):
    parent = record["original"].rsplit("/", 1)[0]
    base = os.path.basename(record["original"])
    admin = record["worktree_admin_path"]
    restored_fd = -1
    try:
        os.close(open_admin(record))
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
            restore_gitdir(record, (qpath + "/.git\n").encode())
            os.close(open_admin(record))
            run("git", "-C", record["worktree_main"], "worktree", "repair", qpath)
            os.close(open_admin(record))
            if not qr.same_entry(qfd, qid, qst): return "quarantine_conflict:" + qid
            safe_rename(qfd, qid, pfd, base); os.fsync(qfd); os.fsync(pfd)
        # A replacement can arrive at the rename boundary. Bind the resulting
        # checkout before repairing its registration or unlocking by pathname.
        restored_fd, conflict = bind_restored_checkout(pfd, qfd, qid, record)
        if conflict:
            return conflict if conflict.startswith("quarantine_conflict:") else "quarantine_conflict:" + qid
        if qst is not None:
            os.close(open_admin(record))
            run("git", "-C", record["worktree_main"], "worktree", "repair", record["original"])
        locked = os.path.join(admin, "locked")
        if os.path.exists(locked):
            if record.get("locked_sha256") and digest(locked) == record.get("locked_sha256"):
                os.close(open_admin(record))
                run("git", "-C", record["worktree_main"], "worktree", "unlock", record["original"])
        if record.get("original_gitdir_hex"):
            restore_gitdir(record, bytes.fromhex(record["original_gitdir_hex"]))
        restored = os.stat(base, dir_fd=pfd, follow_symlinks=False)
        if (restored.st_dev, restored.st_ino) != (record["dev"], record["ino"]):
            return "quarantine_conflict:" + qid
        if not qr.finish_sidecar(qfd, qid, "rolled-back"): return f"quarantine_conflict:{qid}:index-cleanup-failed"
        return "kept:" + reason
    except Exception:
        return "quarantine_conflict:" + qid
    finally:
        if restored_fd >= 0: os.close(restored_fd)


def phase2(qid, deadline=None):
    try:
        index, pfd, qfd, record = qr.indexed_item(qid)
    except Exception:
        return "kept:quarantine_partial_kept"
    try:
        if record.get("worktree_admin") is not True:
            return "kept:quarantine_partial_kept"
        if not record.get("root_removed") and not check_admin(record, deadline=deadline):
            return "kept:quarantine_partial_kept"
        binding = {"parent_path": index["parent_path"], "parent_dev": index["parent_dev"], "parent_ino": index["parent_ino"]}
        fd, bind = tempfile.mkstemp(prefix=".wrh-bind-")
        try:
            with os.fdopen(fd, "w") as f: json.dump(binding, f)
            result = qr.phase2(bind, qid, deadline)
        finally:
            try: os.unlink(bind)
            except OSError: pass
        if result == "deferred:phase2":
            return "deferred:phase2"
        if result not in ("checkout_removed", "removed"):
            return "kept:quarantine_partial_kept"
        # phase2 loaded its own record and committed checkout completion. Never
        # journal admin progress from our pre-call snapshot: that would erase
        # root_removed and strand a crash/deadline in the first admin teardown.
        committed_index, committed_pfd, committed_qfd, committed = qr.indexed_item(qid)
        try:
            progress_keys = {"phase", "removed_paths", "root_removed", "wrh_phase"}
            if (committed_index != index or not isinstance(committed, dict) or
                    any(committed.get(k) != v for k, v in record.items() if k not in progress_keys) or
                    committed.get("phase") != "deleting" or committed.get("root_removed") is not True or
                    committed.get("wrh_phase") != "checkout_removed"):
                return "kept:quarantine_partial_kept"
            record = committed
        finally:
            os.close(committed_qfd); os.close(committed_pfd)
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
                try:
                    removed_admin = qr.unlink_inventory_entry(afd, os.path.basename(admin), ".", admin_inv["."], admin_inv, children,
                                                              deadline=deadline,
                                                              qfd=qfd, side=qid + ".json", record=admin_record,
                                                              removed_paths=set(record.get("admin_removed_paths", [])))
                except qr.DeadlineExceeded:
                    return "deferred:phase2"
                if not removed_admin:
                    return "kept:quarantine_partial_kept"
        finally:
            os.close(afd)
        listing = run("git", "-C", record["worktree_main"], "worktree", "list", "--porcelain", deadline=deadline).stdout.decode()
        qpath = os.path.join(index["parent_path"], ".dm-quarantine", qid)
        if "worktree " + qpath in listing or os.path.exists(admin):
            return "kept:quarantine_partial_kept"
        if not qr.finish_sidecar(qfd, qid, "removed"): return "kept:quarantine_partial_kept"
        return "removed"
    except qr.DeadlineExceeded:
        return "deferred:phase2"
    except Exception:
        return "kept:quarantine_partial_kept"
    finally:
        os.close(qfd); os.close(pfd)


def combined_remove(main, worktree, inventory_file, deadline=None):
    """Phase 1 + phase 2 (including admin teardown) under the caller's single lock."""
    first = phase1(main, worktree, inventory_file, deadline)
    if not first.startswith("quarantined:"): return first
    qid = first.split(":", 1)[1]
    result = phase2(qid, deadline)
    if result == "removed": return f"removed:{qid}"
    return result if result.endswith(":" + qid) else f"{result}:{qid}"


def restore(qid, deadline=None):
    if qr.deadline_passed(deadline): return "deferred:deadline"
    restored_fd = -1
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
        try:
            payload_matches = canonical(qr.visit(qfd, qid, ".", [], deadline)) == canonical(record["inventory"])
        except qr.DeadlineExceeded:
            return "deferred:deadline"
        if not payload_matches:
            return "deferred:deadline" if qr.deadline_passed(deadline) else "kept:quarantine_partial_kept"
        os.close(open_admin(record))
        if not qr.same_entry(qfd, qid, qst): return "kept:identity-mismatch"
        safe_rename(qfd, qid, pfd, base); os.fsync(qfd); os.fsync(pfd)
        # The quarantine name can be replaced between inventory verification
        # and rename. Bind the restored directory before any Git repair/write
        # or terminal cleanup, just as the generic restore binds its payload.
        restored_fd, conflict = bind_restored_checkout(pfd, qfd, qid, record)
        if conflict: return conflict
        original = record["original"]
        os.close(open_admin(record))
        run("git", "-C", record["worktree_main"], "worktree", "repair", original)
        if record.get("original_gitdir_hex"):
            restore_gitdir(record, bytes.fromhex(record["original_gitdir_hex"]))
        locked = os.path.join(record["worktree_admin_path"], "locked")
        if os.path.exists(locked):
            if digest(locked) != record.get("locked_sha256"): return "kept:lock-owner-mismatch"
            os.close(open_admin(record))
            run("git", "-C", record["worktree_main"], "worktree", "unlock", original)
        if canonical(record["worktree_admin_inventory"]) != canonical(admin_current_inventory(record["worktree_admin_path"])):
            return "kept:admin-changed"
        if not qr.finish_sidecar(qfd, qid, "restored"): return "kept:quarantine_partial_kept"
        return "restored:" + qid
    except qr.DeadlineExceeded:
        return "deferred:deadline"
    except Exception:
        return "kept:quarantine_partial_kept"
    finally:
        if restored_fd >= 0: os.close(restored_fd)
        os.close(qfd); os.close(pfd)


def reconcile_one(qid, deadline=None):
    """Resolve one indexed record without taking the operation lock.

    Called by the generic ``quarantine_rename.reconcile_one`` dispatcher (which
    already holds the canonical operation lock) so worktree records use the
    repair/rollback machinery instead of the plain generic rename. Records that
    are not worktree-admin fall back to the generic per-record resolver.
    """
    try:
        index, pfd, qfd, record = qr.indexed_item(qid)
    except qr.DeadlineExceeded:
        return f"deferred:{qid}:operation"
    except Exception:
        return f"alert:{qid}:missing-index-or-sidecar"
    if record is None or record.get("worktree_admin") is not True:
        try:
            return qr.reconcile_record(qid, index, pfd, qfd, record, deadline)
        finally:
            os.close(qfd); os.close(pfd)
    try:
        phase = record.get("wrh_phase")
        if phase == "checkout_removed" or record.get("phase") == "deleting":
            result = phase2(qid, deadline)
        else:
            result = rollback(pfd, qfd, qid, record, reason="rolled-back")
    except qr.DeadlineExceeded:
        return f"deferred:{qid}:operation"
    except Exception:
        return f"alert:{qid}:reconcile-failed"
    finally:
        os.close(qfd); os.close(pfd)
    if result in ("removed", "checkout_removed"):
        return f"reconciled:{qid}:removed"
    if result == "kept:rolled-back":
        return f"reconciled:{qid}:rolled-back"
    if result.startswith("deferred"):
        return f"{result}:{qid}"
    reason = result.split(":", 1)[1] if result.startswith("kept:") else result
    return f"alert:{qid}:{reason}"


def reconcile(deadline=None):
    try:
        directory = qr.index_dir()
        ids = sorted(n[:-5] for n in os.listdir(directory) if len(n) == 21 and n.endswith(".json") and
                     all(c in "0123456789abcdef" for c in n[:-5]))
        for qid in ids:
            if qr.deadline_passed(deadline):
                print("deferred:" + qid); return 0
            try: _, pfd, qfd, record = qr.indexed_item(qid)
            except Exception: continue
            if record is None:
                os.close(qfd); os.close(pfd)
                print(qid + ":" + qr.reconcile_one(qid, deadline))
                continue
            try:
                if record.get("worktree_admin") is not True: continue
                phase = record.get("wrh_phase")
                if phase == "checkout_removed" or record.get("phase") == "deleting":
                    print(qid + ":" + phase2(qid, deadline)); continue
                print(qid + ":" + rollback(pfd, qfd, qid, record))
            finally:
                os.close(qfd); os.close(pfd)
        return 0
    except Exception:
        return 1


def main(argv):
    args = list(argv)
    deadline = None
    if "--deadline-at" in args:
        i = args.index("--deadline-at")
        if i + 1 >= len(args): print("kept:check-failed"); return 0
        try: deadline = float(args[i + 1])
        except ValueError: print("kept:check-failed"); return 0
        if not math.isfinite(deadline) or deadline < 0:
            print("kept:check-failed"); return 0
        del args[i:i + 2]
    if len(args) == 4 and args[0] == "phase1":
        lock = qr.operation_lock(deadline)
        if lock is None: print("deferred:operation-lock"); return 0
        try: print(phase1(*args[1:], deadline))
        finally: qr.operation_unlock(lock)
    elif len(args) == 2 and args[0] == "phase2":
        lock = qr.operation_lock(deadline)
        if lock is None: print("deferred:operation-lock"); return 0
        try: print(phase2(args[1], deadline))
        finally: qr.operation_unlock(lock)
    elif len(args) == 2 and args[0] == "restore":
        lock = qr.operation_lock(deadline)
        if lock is None: print("deferred:operation-lock"); return 0
        try: print(restore(args[1], deadline))
        finally: qr.operation_unlock(lock)
    elif args == ["reconcile"]:
        lock = qr.operation_lock(deadline)
        if lock is None: print("deferred:operation-lock"); return 0
        try: return reconcile(deadline)
        finally: qr.operation_unlock(lock)
    elif len(args) == 4 and args[0] == "remove":
        lock = qr.operation_lock(deadline)
        if lock is None: print("deferred:operation-lock"); return 0
        try: print(combined_remove(args[1], args[2], args[3], deadline))
        finally: qr.operation_unlock(lock)
    else: print("kept:check-failed")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
