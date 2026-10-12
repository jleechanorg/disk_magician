#!/usr/bin/env python3
"""C14 probes (spec §7.2). lsremote: live, 30 s, uncached, run from / without GIT_* so
candidate config is never read; a local remote must be an absolute path outside <root>.
gitmeta: .git outside objects/ refs/ logs/ packed-refs index *HEAD, as a manifest or
compared with a lease's git_meta. admin: a linked worktree's admin dir; prints the
object ids under *HEAD, refs/, logs/ and the branch reflog, or kept:<reason>."""
import hashlib, json, os, re, signal, stat, subprocess, sys

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

def lsremote(url, root):
    lp = local_path(url)
    if lp is not None:
        r = os.path.realpath(root)
        p = os.path.realpath(lp) if lp.startswith("/") else r
        if p == r or p.startswith(r.rstrip("/") + "/"):
            return 1
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    env.update(GIT_TERMINAL_PROMPT="0", GIT_ASKPASS="/usr/bin/false", SSH_ASKPASS="/usr/bin/false")
    p = subprocess.Popen(["git", "ls-remote", url], cwd="/", env=env, stdin=subprocess.DEVNULL,
                         stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, start_new_session=True)
    try:
        sys.stdout.write(p.communicate(timeout=30)[0].decode())
    except subprocess.TimeoutExpired:
        os.killpg(p.pid, signal.SIGKILL)
        return p.wait() or 1
    return p.returncode

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

if __name__ == "__main__":
    a = sys.argv[1:]
    try:
        if len(a) == 3 and a[0] == "lsremote" and not a[1].startswith("-"):
            sys.exit(lsremote(a[1], a[2]))
        if len(a) in (2, 3) and a[0] == "gitmeta":
            sys.exit(gitmeta(*a[1:]))
        if len(a) in (2, 3) and a[0] == "admin":
            sys.exit(admin(*a[1:]))
    except Exception:
        sys.exit("kept:check-failed")
    sys.exit("usage: c14_probe.py lsremote <url> <root> | gitmeta <gitdir> [<lease.json>] | admin <admindir> [<lease.json>]")
