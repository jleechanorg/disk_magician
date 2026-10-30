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

def _touches_root(path, root_real):
    if not path:
        return True
    queue, seen = [os.path.abspath(path)], set()
    prefix = root_real.rstrip(os.sep) + os.sep
    while queue:
        curr = queue.pop()
        if curr in seen:
            continue
        seen.add(curr)
        real = os.path.realpath(curr)
        if real == root_real or real.startswith(prefix):
            return True
        if os.path.islink(curr):
            try:
                target = os.readlink(curr)
            except OSError:
                return True
            queue.append(os.path.abspath(os.path.join(os.path.dirname(curr), target)))
        parent = os.path.dirname(curr)
        if parent != curr:
            queue.append(parent)
    return False

def _unquote_alt_line(line):
    if not line.startswith(b'"'):
        return line
    if len(line) < 2 or not line.endswith(b'"'):
        return None
    body, out, i = line[1:-1], bytearray(), 0
    escapes = {ord("a"): 7, ord("b"): 8, ord("f"): 12, ord("n"): 10,
               ord("r"): 13, ord("t"): 9, ord("v"): 11, ord("\\"): 92, ord('"'): 34}
    while i < len(body):
        ch = body[i]
        if ch != 92:
            out.append(ch)
            i += 1
            continue
        i += 1
        if i >= len(body):
            return None
        esc = body[i]
        if esc in escapes:
            out.append(escapes[esc])
            i += 1
        elif 48 <= esc <= 55:
            oct_digits = bytes([esc])
            i += 1
            for _ in range(2):
                if i < len(body) and 48 <= body[i] <= 55:
                    oct_digits += bytes([body[i]])
                    i += 1
                else:
                    break
            val = int(oct_digits, 8)
            if val > 255:
                return None
            out.append(val)
        else:
            return None
    return bytes(out)

def _resolve_gitdir(lp, root_real):
    cand = lp
    if not os.path.lexists(cand) and not cand.endswith(".git") and os.path.lexists(cand + ".git"):
        cand = cand + ".git"
    if _touches_root(cand, root_real) or not os.path.exists(cand):
        return None, None
    if os.path.isfile(cand):
        try:
            raw = open(cand, "rb").read().splitlines()
        except OSError:
            return None, None
        if not raw or not raw[0].startswith(b"gitdir: "):
            return None, None
        target = os.fsdecode(raw[0][8:].rstrip(b"\r"))
        if not target:
            return None, None
        gitdir = os.path.join(os.path.dirname(cand), target)
    elif os.path.isdir(cand):
        dotgit = os.path.join(cand, ".git")
        if os.path.lexists(dotgit):
            if _touches_root(dotgit, root_real):
                return None, None
            if os.path.isdir(dotgit):
                gitdir = dotgit
            elif os.path.isfile(dotgit):
                try:
                    raw = open(dotgit, "rb").read().splitlines()
                except OSError:
                    return None, None
                if not raw or not raw[0].startswith(b"gitdir: "):
                    return None, None
                target = os.fsdecode(raw[0][8:].rstrip(b"\r"))
                if not target:
                    return None, None
                gitdir = os.path.join(cand, target)
            else:
                return None, None
        else:
            gitdir = cand
    else:
        return None, None
    if _touches_root(gitdir, root_real) or not os.path.isdir(gitdir):
        return None, None
    cfile = os.path.join(gitdir, "commondir")
    if os.path.lexists(cfile):
        if _touches_root(cfile, root_real) or not os.path.isfile(cfile):
            return None, None
        try:
            raw_cd = open(cfile, "rb").read().rstrip(b"\r\n")
        except OSError:
            return None, None
        if not raw_cd:
            return None, None
        commondir = os.path.join(gitdir, os.fsdecode(raw_cd))
        if _touches_root(commondir, root_real) or not os.path.isdir(commondir):
            return None, None
    else:
        commondir = gitdir
    return gitdir, commondir

def _local_remote_ok(lp, root):
    if not root or not lp or not lp.startswith("/"):
        return False
    root_real = os.path.realpath(root)
    gitdir, commondir = _resolve_gitdir(lp, root_real)
    if not gitdir or not commondir:
        return False
    for base in (gitdir, commondir):
        for entry in ("HEAD", "refs", "packed-refs", "objects"):
            p = os.path.join(base, entry)
            if os.path.lexists(p) and _touches_root(p, root_real):
                return False
    obj_queue = [os.path.join(commondir, "objects")]
    if os.path.lexists(os.path.join(gitdir, "objects")):
        obj_queue.append(os.path.join(gitdir, "objects"))
    seen_obj = set()
    while obj_queue:
        obj_dir = obj_queue.pop()
        if _touches_root(obj_dir, root_real) or not os.path.isdir(obj_dir):
            return False
        for enc in (os.path.dirname(os.path.abspath(obj_dir)), os.path.dirname(os.path.realpath(obj_dir))):
            cf = os.path.join(enc, "commondir")
            if os.path.lexists(cf):
                if _touches_root(cf, root_real) or not os.path.isfile(cf):
                    return False
                try:
                    rcd = open(cf, "rb").read().rstrip(b"\r\n")
                except OSError:
                    return False
                if not rcd:
                    return False
                cd_target = os.path.join(enc, os.fsdecode(rcd))
                if _touches_root(cd_target, root_real) or not os.path.isdir(cd_target):
                    return False
                cd_objs = os.path.join(cd_target, "objects")
                if os.path.lexists(cd_objs):
                    obj_queue.append(cd_objs)
        real_obj = os.path.realpath(obj_dir)
        if real_obj in seen_obj:
            continue
        seen_obj.add(real_obj)
        info_dir = os.path.join(obj_dir, "info")
        if os.path.lexists(info_dir) and _touches_root(info_dir, root_real):
            return False
        alt_file = os.path.join(obj_dir, "info", "alternates")
        if not os.path.lexists(alt_file):
            continue
        if _touches_root(alt_file, root_real) or not os.path.isfile(alt_file):
            return False
        try:
            raw_alt = open(alt_file, "rb").read()
        except OSError:
            return False
        for raw_line in raw_alt.split(b"\n"):
            line = raw_line[:-1] if raw_line.endswith(b"\r") else raw_line
            if not line or line.startswith(b"#"):
                continue
            parsed = _unquote_alt_line(line)
            if parsed is None or not parsed:
                return False
            alt_path = os.fsdecode(parsed)
            if os.path.isabs(alt_path):
                obj_queue.append(alt_path)
            else:
                if _touches_root(os.path.join(obj_dir, alt_path), root_real):
                    return False
                obj_queue.append(os.path.join(real_obj, alt_path))
    return True

def lsremote(url, root, deadline=None):
    lp = local_path(url)
    if lp is not None and not _local_remote_ok(lp, root):
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

def worktrees(admin_dir, root, deadline=None):
    """Fail closed when the removal candidate contains admin_dir (the common Git
    admin storage) yet a registered linked worktree lives outside the candidate:
    removing the candidate would orphan that worktree's admin. Paths come from
    git's own NUL-delimited records, so spaces/newlines are not token-split."""
    try:
        root = os.path.realpath(root)
        admin_dir = os.path.realpath(admin_dir)
        if not (admin_dir == root or admin_dir.startswith(root.rstrip(os.sep) + os.sep)):
            print("ok")  # shared admin storage is outside the candidate: siblings cannot be orphaned
            return 0
        env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
        result = _run_bounded(["git", "--git-dir", admin_dir, "worktree", "list", "--porcelain", "-z"],
                              cwd="/", env=env, cap=10, deadline=deadline, step="worktree-topology")
        if result is None:
            if deadline is not None:
                print("deferred:worktree-topology")
                return 0
            print("kept:check-failed")
            return 1
        rc, out = result
        if rc != 0 or not out:
            print("kept:check-failed")
            return 1
        if not out.endswith(b"\0\0"):  # a complete -z record list ends with two NUL bytes
            print("kept:check-failed")
            return 1
        fields, i, records = out.split(b"\0"), 0, 0
        n = len(fields)
        while i < n:
            name = fields[i]
            if name == b"":
                i += 1
                continue
            if not name.startswith(b"worktree "):
                print("kept:check-failed")  # a field outside a worktree record
                return 1
            path = os.fsdecode(name[len(b"worktree "):])
            if not path or not os.path.isabs(path):
                print("kept:check-failed")
                return 1
            real = os.path.realpath(path)
            if not (real == root or real.startswith(root.rstrip(os.sep) + os.sep)):
                print("kept:external-worktree")
                return 1
            i += 1
            attrs = 0
            while i < n and fields[i] != b"":  # consume the record until its NUL terminator
                f = fields[i]
                if f.startswith((b"HEAD ", b"branch ", b"detached", b"bare", b"locked", b"prunable ")):
                    attrs += 1
                else:
                    print("kept:check-failed")
                    return 1
                i += 1
            if attrs == 0:
                print("kept:check-failed")  # worktree line without a recognized attribute
                return 1
            records += 1
            if i < n:
                i += 1  # skip the record terminator
        if records == 0:
            print("kept:check-failed")
            return 1
        print("ok")
        return 0
    except Exception:
        print("kept:check-failed")
        return 1

def outer_certificate(root, receipt_path):
    """Validate the advice runner's exact-SHA clone receipt and declared overlay."""
    try:
        root = os.path.realpath(root)
        with open(receipt_path, encoding="utf-8") as stream:
            receipt = json.load(stream)
        sha = receipt.get("sha")
        source = receipt.get("source_repo")
        manifest = receipt.get("overlay_manifest")
        baseline = receipt.get("git_meta")
        receipt_ref = receipt.get("receipt_path")
        pid, started, created = receipt.get("pid"), receipt.get("start_epoch"), receipt.get("created_epoch")
        if (receipt.get("clone_kind") != "independent_exact_sha_fetch" or
                not isinstance(sha, str) or not re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", sha) or
                not isinstance(source, str) or not isinstance(manifest, list) or
                not isinstance(baseline, dict) or not isinstance(receipt_ref, str) or
                os.path.realpath(receipt_ref) != os.path.realpath(receipt_path) or
                isinstance(pid, bool) or not isinstance(pid, int) or pid < 1 or
                isinstance(started, bool) or not isinstance(started, (int, float)) or started <= 0 or
                isinstance(created, bool) or not isinstance(created, int) or created <= 0):
            return "kept:check-failed"
        source = os.path.realpath(source)
        if source == root or source.startswith(root.rstrip("/") + "/") or root.startswith(source.rstrip("/") + "/"):
            return "kept:check-failed"
        if not os.path.isdir(source):
            return "kept:source-missing"
        env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
        def git(*args):
            return subprocess.run(["git", "-C", root, *args], stdout=subprocess.PIPE,
                                  stderr=subprocess.DEVNULL, check=False, timeout=10, env=env).stdout.decode().strip()
        if git("rev-parse", "--show-toplevel") != root or git("rev-parse", "HEAD") != sha:
            return "kept:check-failed"
        if git("symbolic-ref", "-q", "HEAD"):
            return "kept:check-failed"
        if subprocess.run(["git", "-C", source, "cat-file", "-e", sha + "^{commit}"],
                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False, timeout=10,
                          env={**env, "GIT_NO_LAZY_FETCH": "1"}).returncode:
            return "kept:source-missing"
        gitdir = git("rev-parse", "--absolute-git-dir")
        if not gitdir or os.path.realpath(gitdir) != os.path.join(root, ".git"):
            return "kept:check-failed"
        actual_meta = json.loads(subprocess.run([sys.executable, __file__, "gitmeta", gitdir],
                                                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                                check=True, timeout=30, text=True, env=env).stdout)
        if actual_meta != baseline:
            return "kept:git-metadata"
        allowed = {}
        for row in manifest:
            if not isinstance(row, dict) or set(row) != {"path", "sha256"}:
                return "kept:check-failed"
            rel, digest = row["path"], row["sha256"]
            if (not isinstance(rel, str) or not rel.startswith(".advice-review-documents/") or
                    not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest) or
                    rel in allowed or ".." in rel.split("/") or "\\" in rel):
                return "kept:check-failed"
            allowed[rel] = digest
        overlay_root = os.path.join(root, ".advice-review-documents")
        actual = {}
        if os.path.lexists(overlay_root):
            if not os.path.isdir(overlay_root) or os.path.islink(overlay_root):
                return "kept:dirty"
            for dp, dirs, files in os.walk(overlay_root, followlinks=False):
                for name in list(dirs):
                    p = os.path.join(dp, name)
                    if os.path.islink(p):
                        return "kept:dirty"
                for name in files:
                    p = os.path.join(dp, name)
                    rel = os.path.relpath(p, root).replace(os.sep, "/")
                    if os.path.islink(p) or not os.path.isfile(p):
                        return "kept:dirty"
                    with open(p, "rb") as stream:
                        actual[rel] = hashlib.sha256(stream.read()).hexdigest()
        if actual != allowed:
            return "kept:dirty"
        if git("remote"):
            return "kept:check-failed"
        status = subprocess.run(["git", "-C", root, "status", "--porcelain=v1", "--untracked-files=all",
                                 "--ignore-submodules=none", "-z"], stdout=subprocess.PIPE,
                                stderr=subprocess.DEVNULL, check=False, timeout=30, env=env)
        if status.returncode:
            return "kept:check-failed"
        records = status.stdout.split(b"\0")
        i = 0
        while i < len(records) and records[i]:
            record = records[i]
            i += 1
            if len(record) < 4 or record[:3] != b"?? ":
                return "kept:dirty"
            rel = os.fsdecode(record[3:]).replace(os.sep, "/")
            if rel not in allowed:
                return "kept:dirty"
        return "ok"
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError):
        return "kept:check-failed"

ADMIN = {"HEAD", "ORIG_HEAD", "FETCH_HEAD", "AUTO_MERGE", "index", "commondir", "gitdir", "config.worktree", "COMMIT_EDITMSG"}
OID, HEX = re.compile(r"^(?!0+$)([0-9a-f]{40}|[0-9a-f]{64})$"), rb"[0-9a-f]{40}(?:[0-9a-f]{24})?"
REF, LOG = re.compile(HEX + rb"\n?"), re.compile(HEX + b" " + HEX + rb" [^\n]*> \d+ [+-]\d{4}(?:\t[^\n]*)?\n?")

def entry_ok(rel, st, data=None):  # git's own type and name; refs/logs files must parse from the verified bytes
    top, d, f = rel.split("/")[0], stat.S_ISDIR(st.st_mode), stat.S_ISREG(st.st_mode)
    if top not in ("refs", "logs") or not f or "/" not in rel:
        return d and top in ("refs", "logs") or f and top in ADMIN and "/" not in rel
    if data is None:
        return False
    return bool(REF.fullmatch(data)) if top == "refs" else all(map(LOG.fullmatch, data.splitlines(True)))

def _read_verified(p, keep=False):
    """lstat then fd-open; hash (and optionally keep) the same inode, verifying it did
    not change across the read. Returns (stat, sha256_hex or None, bytes)."""
    st = os.lstat(p)
    if not stat.S_ISREG(st.st_mode):
        return st, None, b""
    fd = os.open(p, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    try:
        before = os.fstat(fd)
        if (before.st_dev, before.st_ino) != (st.st_dev, st.st_ino):
            return st, None, b""
        h, buf = hashlib.sha256(), bytearray()
        while True:
            block = os.read(fd, 1 << 20)
            if not block:
                break
            h.update(block)
            if keep:
                buf += block
        after = os.fstat(fd)
        if (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns) != (
                before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns):
            return st, None, b""
        return before, h.hexdigest(), bytes(buf)
    finally:
        os.close(fd)

def admin(ad, lease=None):
    names = set(os.listdir(ad))
    if "locked" in names or names & {"rebase-merge", "rebase-apply", "MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "BISECT_LOG"}:
        return print("kept:locked" if "locked" in names else "kept:dirty")
    inv, rows, oids, dirs, small = os.environ.get("C14_INVENTORY_OUT"), [], [], [], {}
    def receipt(rel, st, digest=None):  # original admin state; entry_type stays distinct from the type=admin envelope
        if not inv: return
        row = {"admin": ad, "path": rel, "entry_type": "dir" if stat.S_ISDIR(st.st_mode) else "file",
               "mode": "%o" % st.st_mode, "dev": st.st_dev, "ino": st.st_ino, "size": st.st_size}
        if digest is not None:
            row["sha256"] = digest
        rows.append(row)
    root_st = os.lstat(ad)
    receipt(".", root_st)  # the admin root carries its own dev/ino for the downstream remover
    dirs.append((".", root_st))
    for dp, dns, fns in os.walk(ad, onerror=lambda e: sys.exit("kept:check-failed")):
        for n in fns + dns:  # a symlink, special file or unparsed entry anywhere: admin-unknown
            p = os.path.join(dp, n); rel = os.path.relpath(p, ad); st = os.lstat(p)
            if stat.S_ISDIR(st.st_mode):
                if not entry_ok(rel, st): return print("kept:admin-unknown")
                receipt(rel, st)  # allowed refs/** and logs/** directories carry dev/ino too
                dirs.append((rel, st))
                continue
            if not stat.S_ISREG(st.st_mode):
                return print("kept:admin-unknown")
            # Only the worktree's OWN HEAD (and ORIG_HEAD) are push obligations. A
            # blanket "*HEAD" also matched FETCH_HEAD, whose contents are every
            # fetched branch tip -- none of them this worktree's work. Any worktree
            # that had ever fetched therefore required dozens of unrelated commits
            # to be advertised and answered kept:not-pushed forever (bead
            # disk_magician-vp7h). ORIG_HEAD is deliberately KEPT as an obligation:
            # after a completed `reset --hard` it can be the only remaining pointer
            # to unpushed commits when reflogs are disabled or expired, and dropping
            # it would let cleanup GC the last recovery path to real work (raised by
            # the /advice Codex reviewer on PR #242). In-progress states that could
            # carry real work (MERGE_HEAD, CHERRY_PICK_HEAD, REVERT_HEAD, rebase
            # dirs, locked) are already rejected above, and logs/HEAD plus refs/**
            # still match through the "/" arm.
            need = rel in ("HEAD", "ORIG_HEAD") or "/" in rel  # HEAD, ORIG_HEAD, refs/**, logs/**
            keep = need or rel in ("HEAD", "commondir", "config.worktree", "COMMIT_EDITMSG")
            fst, digest, data = _read_verified(p, keep=keep)
            if digest is None or (fst.st_dev, fst.st_ino) != (st.st_dev, st.st_ino):
                return print("kept:check-failed")
            if not entry_ok(rel, st, data if (rel.split("/")[0] in ("refs", "logs") and "/" in rel) else None):
                return print("kept:admin-unknown")
            if need:
                oids += [w for l in data.decode("utf-8", "replace").splitlines() for w in l.split()[:2] if OID.match(w)]
            if rel in ("HEAD", "commondir", "config.worktree", "COMMIT_EDITMSG"):
                small[rel] = data
            receipt(rel, st, digest)
    for rel, st in dirs:  # post-walk stability: every recorded directory is still the same inode
        now = os.lstat(ad if rel == "." else os.path.join(ad, rel))
        if (now.st_dev, now.st_ino) != (st.st_dev, st.st_ino):
            return print("kept:check-failed")
    if "config.worktree" in names and small.get("config.worktree") and hashlib.sha256(small["config.worktree"]).hexdigest() != (
            (json.load(open(lease)).get("git_meta") or {}) if lease and os.path.isfile(lease) else {}).get("config.worktree"):
        return print("kept:admin-unknown")
    head = small.get("HEAD", b"").strip()
    if head.startswith(b"ref: "):  # the branch reflog lives in the common dir; scan only verified bytes
        rp = os.path.join(ad, os.fsdecode(small.get("commondir", b"").strip()), "logs", os.fsdecode(head[5:]))
        if os.path.isfile(rp):
            fst, digest, data = _read_verified(rp, keep=True)
            if digest is None:
                return print("kept:check-failed")
            oids += [w for l in data.decode("utf-8", "replace").splitlines() for w in l.split()[:2] if OID.match(w)]
    if inv:
        with open(inv, "a", encoding="utf-8") as fh:
            for row in rows: print(json.dumps(row), file=fh)
    oid_set = sorted(set(oids))
    print("kept:admin-unknown" if "COMMIT_EDITMSG" in names and not editmsg_ok(ad, oid_set, small.get("COMMIT_EDITMSG", b"")) else "\n".join(oid_set))

def editmsg_ok(ad, oids, data):  # COMMIT_EDITMSG (beyond the spec list) is only comments or a checked tip's message
    git = lambda i, *a: subprocess.run(["git", "--git-dir", ad, *a], input=i, capture_output=True, check=True).stdout
    msgs = git("\n".join(oids).encode(), "log", "-z", "--no-walk=unsorted", "--stdin", "--format=%B").split(b"\0") + [b""]
    return any(git(data, "stripspace", *s) in msgs for s in ([], ["-s"]))

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
                                        "size": before.st_size, "sha256": h.hexdigest(), "mtime_ns": before.st_mtime_ns,
                                        "name": os.path.basename(root.rstrip(os.sep))})
                    finally: os.close(ffd)
                elif stat.S_ISLNK(st.st_mode):
                    target = os.readlink(name, dir_fd=pfd)
                    now = os.stat(name, dir_fd=pfd, follow_symlinks=False)
                    if (now.st_dev, now.st_ino) != (st.st_dev, st.st_ino): raise OSError("symlink replaced")
                    entries.append({"path": ".", "type": "symlink", "dev": st.st_dev, "ino": st.st_ino,
                                    "size": st.st_size, "target": target, "mtime_ns": st.st_mtime_ns,
                                    "name": os.path.basename(root.rstrip(os.sep))})
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
                            "size": opened.st_size, "mtime_ns": opened.st_mtime_ns,
                            **({"name": os.path.basename(root.rstrip(os.sep))} if rel == "." else {})})
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

def archive_receipt(source, receipt, archived_at=None, retention_minutes=None, recovery_hours=None):
    """Write an exclusive, durable identity receipt for a directory before it moves."""
    try:
        st = os.lstat(source)
        if not stat.S_ISDIR(st.st_mode):
            raise ValueError("archive entries must be directories")
        retention = int(retention_minutes) if retention_minutes is not None else 0
        if retention < 0:
            raise ValueError("invalid retention")
        recovery = int(recovery_hours) if recovery_hours is not None else 0
        if recovery < 0:
            raise ValueError("invalid recovery window")
        row = {"original_path": os.path.abspath(source), "dev": st.st_dev, "ino": st.st_ino,
               "size": st.st_size, "archived_at": int(archived_at) if archived_at else int(time.time()),
               "retention_minutes": retention, "recovery_hours": recovery}
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
        recovery = row.get("recovery_hours", 0)
        if not isinstance(original, str) or not os.path.isabs(original) or type(dev) is not int or type(ino) is not int or type(archived_at) is not int or archived_at <= 0 or type(retention) is not int or retention < 0:
            raise ValueError("receipt fields missing")
        if type(recovery) is not int or recovery < 0:
            raise ValueError("receipt recovery field invalid")
        if (dev, ino) != identity[:2] or type(row.get("size")) is not int or row["size"] != st.st_size:
            raise ValueError("archive identity changed")
        if "sha256" in row:
            raise ValueError("unsupported receipt digest")
        print(json.dumps({"original_path": original, "archived_at": archived_at,
                          "retention_minutes": retention, "recovery_hours": recovery}, separators=(",", ":")))
    except Exception:
        print("kept:archive-identity")

def _internal_target(root, rel, entry):
    """Absolute realpath a symlink entry points at, or None when it escapes root."""
    parent = os.path.dirname(rel) or "."
    link_parent = root if parent == "." else os.path.join(root, parent)
    target = os.path.realpath(os.path.join(link_parent, entry.get("target", "")))
    return target if target.startswith(root.rstrip(os.sep) + os.sep) else None

def _entry_kind(root, rel, entry):
    """Effective file/dir kind Git's own -f/-d tests would see, following a symlink
    only when it resolves inside root. None means unsupported or escaping."""
    kind = entry.get("type")
    if kind in ("file", "dir"):
        return kind
    if kind != "symlink":
        return None
    target = _internal_target(root, rel, entry)
    if target is None:
        return None
    if os.path.isdir(target):
        return "dir"
    if os.path.isfile(target):
        return "file"
    return None

def _bare_repo_state(root, base, by_path):
    """'repo' for a Git-accepted bare layout (HEAD=file, objects=dir, refs=dir,
    symlinks allowed when internal); 'invalid' for a repo-looking dir we cannot
    validate (caller fails closed); 'none' otherwise."""
    def entry(name):
        rel = name if base == "." else base + "/" + name
        return rel, by_path.get(rel)
    head_rel, head = entry("HEAD")
    objects_rel, objects = entry("objects")
    refs_rel, refs = entry("refs")
    if head is None:
        return "none"
    kinds = {rel: _entry_kind(root, rel, e) if e is not None else None
             for rel, e in ((head_rel, head), (objects_rel, objects), (refs_rel, refs))}
    if kinds[head_rel] == "file" and kinds[objects_rel] == "dir" and kinds[refs_rel] == "dir":
        return "repo"
    if objects is None or refs is None:
        return "none"
    return "invalid"

def repos(inv_file):
    """Print discovered repository roots from a complete JSON inventory."""
    try:
        entries = json.load(open(inv_file, encoding="utf-8"))
        if not isinstance(entries, list): raise ValueError("inventory must be a list")
        by_path = {e["path"]: e for e in entries}
        root = os.path.realpath(os.environ.get("C14_ROOT", os.path.dirname(os.path.abspath(inv_file))))
        roots = set()
        gitdir_targets = set()
        for rel, e in by_path.items():
            if rel == ".": parent, name = ".", "."
            else: parent, _, name = rel.rpartition("/"); parent = parent or "."
            if name != ".git" or e.get("type") != "symlink":
                continue
            link_parent = root if parent == "." else os.path.join(root, parent)
            target = os.path.realpath(os.path.join(link_parent, e.get("target", "")))
            if not target.startswith(root.rstrip(os.sep) + os.sep) or not os.path.isdir(target):
                sys.stdout.write("kept:gitdir-invalid\0")
                return 1
            gitdir_targets.add(os.path.relpath(target, root))
        for rel, e in by_path.items():
            if rel == ".": parent, name = ".", "."
            else: parent, _, name = rel.rpartition("/"); parent = parent or "."
            if name == ".git" and e.get("type") in ("dir", "file"):
                roots.add(parent)
            elif name == ".git" and e.get("type") == "symlink":
                link_parent = root if parent == "." else os.path.join(root, parent)
                target = os.path.realpath(os.path.join(link_parent, e.get("target", "")))
                if not target.startswith(root.rstrip(os.sep) + os.sep) or not os.path.isdir(target):
                    sys.stdout.write("kept:gitdir-invalid\0")
                    return 1
                roots.add(parent)
            # A bare repo is any dir Git accepts: HEAD a file (or internal
            # symlink), objects and refs dirs (or internal symlinks). Metadata
            # under .git/ (e.g. .git/modules/<sm>) belongs to its owner; a dir
            # named foo.git is untouched. A repo-looking dir we cannot validate
            # fails closed rather than falling through to ordinary content.
            if rel in gitdir_targets or ".git" in rel.split("/"):
                continue
            if rel == "." or e.get("type") == "dir":
                state = _bare_repo_state(root, rel, by_path)
                if state == "repo":
                    roots.add(rel)
                elif state == "invalid":
                    sys.stdout.write("kept:gitdir-invalid\0")
                    return 1
        # Caller supplies C14_ROOT to bind relative inventory paths to its candidate.
        for rel in sorted(roots):
            print(os.path.join(root, rel) if rel != "." else root, end="\0")
        return 0
    except Exception:
        print("kept:check-failed")
        return 1

def newest_mtime(inv_file):
    try:
        entries = json.load(open(inv_file, encoding="utf-8"))
        mtimes = [e["mtime_ns"] // 1_000_000_000 for e in entries if type(e.get("mtime_ns")) is int]
        if not mtimes: raise ValueError("empty mtime inventory")
        print(max(mtimes))
    except Exception:
        print("kept:check-failed")

SECRET_RE = re.compile(r"^(?:\.env.*|.*\.(?:pem|key|p12|pfx)(?:\.map)?|id_(?:rsa|ed25519|ecdsa|dsa).*|\.npmrc|\.netrc|.*credential(?!services)(?-i:s|S(?![a-z])).*|secrets.*)$", re.I)
_TEMPLATE = (".example", ".template", ".sample", ".dist", ".default")
# A template marker can appear BEFORE the secret-looking suffix, e.g.
# test-credentials-template.env or config_template.secrets.yaml. Such a file is a
# template by intent and carries no secret material.
_TEMPLATE_MARKERS = ("-template", "_template", ".template", "-example", "_example",
                     "-sample", "_sample", "-dist", "_dist", "-default", "_default")
# A stem that is exactly one of these stays secret-like for every extension.
_SECRET_EXACT = {"credentials", "credential", "secrets", "secret"}
_DEP_DIRS = {"node_modules", "venv", ".venv", "site-packages", "pods", "third-party"}
_SRC_EXTS = {"js", "mjs", "cjs", "jsx", "ts", "tsx", "py", "pyi", "c", "cc", "cpp", "m", "mm", "swift", "go", "rs", "java", "kt", "rb", "php", "cs"}
# Code/document extensions used ONLY by the compound-identifier rule below. They are
# deliberately NOT added to _SRC_EXTS, because _SRC_EXTS also grants dependency-dir
# exemption and the name table forbids that for e.g. node_modules/pkg/credentials.sh
# and no pyc/pyo exemption outside a dependency dir.
_CODE_EXTS = _SRC_EXTS | {"sh", "bash", "zsh", "md", "rst", "html", "htm", "css", "svg"}
_NATIVE = (".h", ".hpp", ".pyc", ".so", ".a", ".dylib")

_CA_BUNDLES = ("cacert.pem", "ca-bundle.pem", "ca-certificates.pem")

def _never(n):
    return n.startswith((".env", "id_rsa", "id_ed25519", "id_ecdsa", "id_dsa")) or n.endswith((".pem", ".key", ".p12", ".pfx")) or n in (".npmrc", ".netrc")

def _public_ca_bundle(n):
    """Public trust-store bundle shipped by vendored tooling (e.g. pip's vendored certifi).
    Never private key material: only these exact well-known public CA filenames qualify, so a
    deploy.pem or any *.key/.p12/.pfx stays secret-like wherever it lives."""
    return n in _CA_BUNDLES

def exempt_name(path):
    """Single owner of the secret-name exemption (relative path; used by every secret gate).
    Exempt only: a template suffix; .d.ts/.map/.json.schema whose stripped stem is not
    secret-named (e.g. credentials.map: only under a dependency dir); .h/.hpp/.pyc/.so/.a/.dylib under a dependency dir; or a source extension under a dependency dir. .env*, id_*, *.pem/key/p12/pfx,
    .npmrc, .netrc are exempt only as templates. Everything else stays secret-like."""
    parts = path.split("/")
    n = parts[-1].lower()
    if n.endswith(_TEMPLATE) or any(m in n for m in _TEMPLATE_MARKERS):
        return True
    if _never(n):
        # A vendored public CA bundle is dependency material, not a secret. Every other
        # never-exempt name stays secret-like regardless of directory, including a .pem
        # under node_modules/venv/site-packages.
        return bool(_DEP_DIRS & {c.lower() for c in parts[:-1]}) and _public_ca_bundle(n)
    if not SECRET_RE.fullmatch(parts[-1]):
        return True
    # Source code is not secret material — but only when the secret word is part of a
    # longer identifier. A stem that IS the secret word (credentials.py, secrets.rb,
    # node_modules/pkg/credentials.sh, secrets.md) stays secret-like, which is what
    # tests/secret_name_table.tsv asserts for 23 rows. A compound name such as
    # mvp_site/openrouter_credentials.py is code, and inside a git repo it never reaches
    # this gate at all (that scan lists only ignored/untracked files), so without this a
    # non-repo scratch copy of a checkout is unremovable.
    if "." in n and n.rpartition(".")[2] in _CODE_EXTS and n.split(".")[0] not in _SECRET_EXACT:
        return True
    comps = {c.lower() for c in parts[:-1]}
    dep = bool(_DEP_DIRS & comps)
    stripped = n
    while stripped.endswith((".map", ".d.ts")):
        stripped = stripped[: -4 if stripped.endswith(".map") else -5]
    if n.endswith(".json.schema") and stripped == n:
        stripped = n[: -len(".json.schema")]
    if stripped != n:
        # A stem that is itself secret-named (credentials, secrets, ...) is exempt only under a dependency dir.
        return not _never(stripped) and (dep or not SECRET_RE.fullmatch(stripped))
    if n.endswith(_NATIVE):
        return dep
    return dep and "." in n and n.rpartition(".")[2] in _SRC_EXTS

def _xcode_generated(q):
    """Compiler/indexer output and fetched package clones inside a DerivedData root."""
    top = q.split("/", 1)[0].lower()
    return top in ("build", "logs") or top.endswith(".noindex") or top.startswith("modulecache") \
        or q.lower().startswith("sourcepackages/checkouts/")

def _xcode_device_support_generated(q):
    """Extracted device system symbols inside an iOS DeviceSupport root."""
    return q.lower().startswith("symbols/")

def secrets(inv_file, kind=""):
    try:
        kind = os.environ.get("C14_SECRET_KIND") or kind
        entries = json.load(open(inv_file, encoding="utf-8"))
        paths = (e.get("name", "") if e["path"] == "." else e["path"] for e in entries)
        if kind == "xcode-derived-data":
            # Generated names such as NativeRequestCredentials.o are not secrets; anything
            # else in the root (a .env, secrets.json, *.p12) still is.
            paths = (q for q in paths if not _xcode_generated(q))
        elif kind == "xcode-device-support":
            paths = (q for q in paths if not _xcode_device_support_generated(q))
        print("yes" if any(SECRET_RE.fullmatch(q.rsplit("/", 1)[-1]) and not exempt_name(q) for q in paths) else "no")
    except Exception:
        print("kept:check-failed")

def any_secret(argv):
    """Contract: rc 0 = a secret-like path remains; rc 1 + stdout "none" = explicit none found;
    rc 3 = any error (callers must treat everything but rc 1 + "none" as secret-like)."""
    try:
        if argv:
            return 3
        names = sys.stdin.buffer.read().decode("utf-8", "surrogateescape").split("\n")
        if any(q and not exempt_name(q) for q in names):
            return 0
        print("none")
        return 1
    except BaseException:
        return 3

def merge_inventory(inv_file, admin_file, out_file, admin_filter=None):
    try:
        entries = json.load(open(inv_file, encoding="utf-8"))
        if os.path.isfile(admin_file):
            for line in open(admin_file, encoding="utf-8"):
                if not line.strip():
                    continue
                entry = json.loads(line)
                # A caller-supplied channel can accumulate rows for every
                # repository checked in a run. A receipt for one worktree root
                # may bind only rows canonicalized to that candidate's own git
                # dir; an empty/absent filter binds none.
                if admin_filter is not None and entry.get("admin") != admin_filter:
                    continue
                entry["type"] = "admin"
                entries.append(entry)
        with open(out_file, "w", encoding="utf-8") as f:
            json.dump(entries, f, separators=(",", ":"), sort_keys=True)
            f.flush(); os.fsync(f.fileno())
        print("ok")
    except Exception:
        print("kept:check-failed")

def _hardlink_only_false_positive(lsof_bin, root, out, cap, deadline):
    """True only when every path reported by `lsof +D <root>` is a multi-link hardlink
    (st_nlink > 1) and no holder PID is executing from <root> or holds any non-hardlink
    path inside <root>."""
    try:
        pids, paths = set(), []
        for raw in out.splitlines():
            if not raw:
                continue
            tag = raw[:1]
            if tag == b"p":
                pid = os.fsdecode(raw[1:])
                if not pid.isdigit():
                    return False
                pids.add(pid)
            elif tag == b"n":
                paths.append(os.fsdecode(raw[1:]))
            elif tag not in (b"f", b"c"):
                return False
        if not pids or not paths:
            return False
        hardlink_paths = set()
        for p in paths:
            st = os.lstat(p)
            if not stat.S_ISREG(st.st_mode) or st.st_nlink <= 1:
                return False
            hardlink_paths.add(os.path.abspath(p))
            hardlink_paths.add(os.path.realpath(p))
        root_abs = os.path.abspath(root).rstrip(os.sep)
        root_real = os.path.realpath(root).rstrip(os.sep)
        ps_res = _run_bounded(
            ["ps", "-p", ",".join(sorted(pids)), "-o", "comm="],
            cap=cap, deadline=deadline, step="tree-walk",
        )
        if ps_res is None or ps_res[0] not in (0, 1):
            return False
        for raw in ps_res[1].splitlines():
            comm = os.fsdecode(raw).strip()
            if not comm or not os.path.isabs(comm):
                continue
            c_abs = os.path.abspath(comm)
            c_real = os.path.realpath(comm)
            if (c_abs == root_abs or c_abs.startswith(root_abs + os.sep) or
                    c_real == root_real or c_real.startswith(root_real + os.sep)):
                return False
        res = _run_bounded(
            [lsof_bin, "-w", "-n", "-P", "-Fn", "-a", "-d", "^cwd", "-p", ",".join(sorted(pids))],
            cap=cap, deadline=deadline, step="tree-walk", stderr=subprocess.STDOUT,
        )
        if res is None:
            return False
        rc, pout = res
        if rc not in (0, 1):
            return False
        for raw in pout.splitlines():
            if not raw:
                continue
            tag = raw[:1]
            if tag == b"n":
                vp = os.fsdecode(raw[1:])
                if not os.path.isabs(vp):
                    continue
                vp_abs = os.path.abspath(vp)
                vp_real = os.path.realpath(vp)
                if vp_abs in hardlink_paths or vp_real in hardlink_paths:
                    continue
                if (vp_abs == root_abs or vp_abs.startswith(root_abs + os.sep) or
                        vp_real == root_real or vp_real.startswith(root_real + os.sep)):
                    return False
            elif tag not in (b"p", b"f", b"c"):
                return False
        return True
    except Exception:
        return False

def open_file(root, deadline=None):
    lsof_bin = os.environ.get("DISK_MAGICIAN_LSOF_BIN", "lsof")
    cap = float(os.environ.get("DISK_MAGICIAN_LSOF_CAP", "30"))
    cmd = [lsof_bin, "-w", "-n", "-P", "-Fn", "-a", "-d", "^cwd"]
    if os.path.isdir(root):
        cmd += ["+D", root]
    else:
        cmd += [root]
    try:
        result = _run_bounded(cmd, cap=cap, deadline=deadline, step="tree-walk", stderr=subprocess.STDOUT)
    except OSError:
        print("kept:check-failed")
        return
    if result is None:
        print("deferred:tree-walk")
    else:
        rc, out = result
        if out and rc in (0, 1) and os.path.isdir(root) and _hardlink_only_false_positive(lsof_bin, root, out, cap, deadline):
            print("no")
        elif out:
            print("yes")
        elif rc == 1:
            print("no")
        else:
            print("kept:check-failed")

if __name__ == "__main__":
    a = sys.argv[1:]
    if a and a[0] == "any-secret":
        sys.exit(any_secret(a[1:]))
    try:
        if len(a) == 3 and a[0] == "lsremote" and not a[1].startswith("-"):
            sys.exit(lsremote(a[1], a[2]))
        if len(a) in (3, 4) and a[0] == "lsremote":
            sys.exit(lsremote(a[1], a[2], a[3]))
        if len(a) in (2, 3) and a[0] == "gitmeta":
            sys.exit(gitmeta(*a[1:]))
        if len(a) in (3, 4) and a[0] == "worktrees":
            sys.exit(worktrees(a[1], a[2], a[3] if len(a) == 4 and a[3] else None))
        if len(a) == 3 and a[0] == "outer-certificate":
            result = outer_certificate(a[1], a[2])
            print(result)
            sys.exit(0 if result == "ok" else 1)
        if len(a) in (2, 3) and a[0] == "admin":
            sys.exit(admin(*a[1:]))
        if len(a) in (3, 4) and a[0] == "provenance":
            sys.exit(provenance(*a[1:]))
        if len(a) in (3, 4) and a[0] == "inventory":
            sys.exit(inventory(a[1], a[2], a[3] if len(a) == 4 else None))
        if len(a) == 4 and a[0] == "account":
            sys.exit(account(*a[1:]))
        if len(a) in (3, 4, 5, 6) and a[0] == "archive-receipt":
            sys.exit(archive_receipt(a[1], a[2], a[3] if len(a) >= 4 else None, a[4] if len(a) >= 5 else None, a[5] if len(a) >= 6 else None))
        if len(a) == 4 and a[0] == "archive-info":
            sys.exit(archive_info(a[1], a[2], a[3]))
        if len(a) == 2 and a[0] == "repos":
            sys.exit(repos(a[1]))
        if len(a) == 2 and a[0] == "newest-mtime":
            sys.exit(newest_mtime(a[1]))
        if len(a) in (2, 3) and a[0] == "secrets":
            sys.exit(secrets(*a[1:]))
        if len(a) == 2 and a[0] == "exempt-name":
            print("yes" if exempt_name(a[1]) else "no"); sys.exit(0)
        if len(a) in (4, 5) and a[0] == "merge-inventory":
            sys.exit(merge_inventory(*a[1:]))
        if len(a) in (2, 3) and a[0] == "open-file":
            sys.exit(open_file(a[1], a[2] if len(a) == 3 and a[2] else None))
    except Exception:
        sys.exit("kept:check-failed")
    sys.exit("usage: c14_probe.py lsremote <url> <root> | gitmeta <gitdir> [<lease.json>] | admin <admindir> [<lease.json>] | provenance <root> <lease.json>")
