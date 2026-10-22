#!/usr/bin/env python3
"""Finish deferred C14 quarantine removals (diskm quarantine-reconcile).

Drives quarantine_rename's reconcile over the state index, which binds every
store to its parent/quarantine/root identity; nothing is deleted whose index,
manifest or identity fails to validate (it is reported as kept). Stores found
under the scratch roots that no index entry owns are reported, never touched.

  plan   [--root R ...] [--scan-seconds N]            read-only
  clean  [--root R ...] [--deadline-seconds N]        reconcile + prune partials

Output is tab-separated plan/kept/orphan-*/result lines, plus
one record per purge appended to $DM_QR_LOG_FILE for the shell wrapper to write to the deletion log.
"""
import contextlib, io, os, re, stat, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import quarantine_rename as qr

UPDATE_RE = re.compile(r"^[0-9a-f]{16}\.json\.update\.[0-9a-f]{16}$")
SKIP = {".git", "node_modules", ".dm-quarantine"}


LOG_FILE = None
def log(action, kb, path):
    """Deletion-log record for the shell wrapper (action, kb, path), tab-separated."""
    if LOG_FILE:
        with open(LOG_FILE, "a") as f: f.write(f"{action}\t{kb}\t{path}\n")


def index_ids():
    dfd = os.open(qr.index_dir(), qr.DIRFL)
    try: return sorted(n[:-5] for n in os.listdir(dfd) if len(n) == 21 and n.endswith(".json") and re.fullmatch(r"[0-9a-f]{16}", n[:-5]))
    finally: os.close(dfd)


def remaining_kb(record):
    done = set(record.get("removed_paths", []))
    return sum(e.get("size", 0) for e in record.get("inventory", [])
               if isinstance(e, dict) and e.get("type") == "file" and e.get("path") not in done) // 1024


def classify(qid):
    """(action, detail, original, kb, store_identity); read-only, fails closed."""
    try: index, pfd, qfd, record = qr.indexed_item(qid)
    except FileNotFoundError: return "kept", "missing-index-or-sidecar", "", 0, None
    except Exception as exc: return "kept", "identity-or-manifest:" + str(exc).replace("\n", " ")[:80], "", 0, None
    os.close(qfd); os.close(pfd)
    store = (index["quarantine_path"], index["quarantine_dev"], index["quarantine_ino"])
    if record is None: return "bookkeeping", index.get("terminal") or index.get("phase", ""), index.get("original", ""), 0, store
    phase = record.get("phase")
    if record.get("worktree_admin") is True: return "delegate-worktree-admin", str(phase), record["original"], remaining_kb(record), store
    if phase == "deleting": return "purge", "phase2-resume", record["original"], remaining_kb(record), store
    if phase in ("intent", "rollback_pending", "rollback_conflict"): return "rollback", str(phase), record["original"], 0, store
    return "kept", "malformed-phase", record.get("original", ""), 0, store


def find_stores(roots, deadline, depth=4):
    found, seen = set(), set()
    stack = [(os.path.realpath(r), 0) for r in roots if r]
    while stack:
        if time.monotonic() >= deadline: print("kept\tscan-deadline\t-"); break
        path, d = stack.pop()
        if path in seen: continue
        seen.add(path)
        try: entries = list(os.scandir(path))
        except OSError: continue
        for e in entries:
            try: is_dir = e.is_dir(follow_symlinks=False)
            except OSError: continue
            if not is_dir: continue
            if e.name == ".dm-quarantine": found.add(e.path)
            elif e.name not in SKIP and d < depth: stack.append((e.path, d + 1))
    return found


def plan(roots, scan_seconds):
    owned, rows = set(), {}
    ids = index_ids()
    for qid in ids:
        action, detail, original, kb, store = classify(qid)
        rows[qid] = (action, kb, original, store)
        if store: owned.add(os.path.realpath(store[0]))
        print(f"{action}\t{qid}\t{original}\t{kb}\t{detail}")
    known = set(ids)
    for store in sorted(find_stores(roots, time.monotonic() + scan_seconds)):
        if os.path.realpath(store) not in owned:
            try: n = len(os.listdir(store))
            except OSError: n = -1
            if n: print(f"orphan-store\t{store}\t-\t0\tno-index-entry entries={n}")
            continue
        for name in sorted(os.listdir(store)):
            if name[:16] not in known and not UPDATE_RE.match(name):
                print(f"orphan-entry\t{os.path.join(store, name)}\t-\t0\tno-index-entry")
    return rows


def prune_partials(stores):
    """Stale sidecar `.update.*` temps; safe under the operation lock (no updater runs)."""
    for path, dev, ino in sorted(stores):
        n = kb = 0
        try:
            qfd = os.open(path, qr.DIRFL | os.O_NOFOLLOW)
        except OSError: continue
        try:
            st = os.fstat(qfd)
            if (st.st_dev, st.st_ino) != (dev, ino) or st.st_uid != os.getuid(): continue
            for name in os.listdir(qfd):
                if not UPDATE_RE.match(name): continue
                try:
                    fst = os.stat(name, dir_fd=qfd, follow_symlinks=False)
                    if not stat.S_ISREG(fst.st_mode): continue
                    os.unlink(name, dir_fd=qfd); n += 1; kb += fst.st_size // 1024
                except OSError: pass
        finally: os.close(qfd)
        if n: log("quarantine-partial", kb, path); print(f"pruned\t{path}\t{n}\t{kb}")


def prune_reconcile_temps():
    d = qr.index_dir()
    for name in os.listdir(d):
        if name.startswith(".reconcile."):
            try: os.unlink(d / name)
            except OSError: pass


def clean(roots, deadline_seconds):
    deadline = time.monotonic() + deadline_seconds
    lock = qr.operation_lock(deadline)
    if lock is None: print("deferred\toperation-lock"); return 0
    try:
        rows = plan(roots, min(30, deadline_seconds))
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf): rc = qr.quarantine_reconcile(["--deadline-at", repr(deadline)])
        for line in buf.getvalue().splitlines():
            print("result\t" + line)
            if line.startswith("removed:"):
                qid = line.split(":")[1]; action, kb, original, _ = rows.get(qid, ("", 0, "", None))
                log("quarantine-phase2", kb, original or qid)
        prune_partials({r[3] for r in rows.values() if r[3]})
        prune_reconcile_temps()
        return rc
    finally: qr.operation_unlock(lock)


if __name__ == "__main__":
    args, roots, seconds = sys.argv[1:], [], None
    LOG_FILE = os.environ.get("DM_QR_LOG_FILE")
    mode = args[0] if args else ""
    i = 1
    while i < len(args):
        if args[i] == "--root" and i + 1 < len(args): roots.append(args[i + 1]); i += 2
        elif args[i] in ("--scan-seconds", "--deadline-seconds") and i + 1 < len(args): seconds = float(args[i + 1]); i += 2
        else: sys.exit("usage: quarantine_reconcile.py plan|clean [--root R ...] [--scan-seconds N | --deadline-seconds N]")
    if mode == "plan": plan(roots, seconds if seconds is not None else 30)
    elif mode == "clean": sys.exit(clean(roots, seconds if seconds is not None else 300))
    else: sys.exit("usage: quarantine_reconcile.py plan|clean ...")
