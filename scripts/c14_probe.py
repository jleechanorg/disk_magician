#!/usr/bin/env python3
"""C14 probes (spec §7.2). lsremote: live, 30 s, uncached, run from / without GIT_* so
candidate config is never read; a local remote must be an absolute path outside <root>.
gitmeta: .git outside objects/ refs/ logs/ packed-refs index *HEAD, as a manifest or
compared with a lease's git_meta."""
import hashlib, json, os, signal, stat, subprocess, sys

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

if __name__ == "__main__":
    a = sys.argv[1:]
    try:
        if len(a) == 3 and a[0] == "lsremote" and not a[1].startswith("-"):
            sys.exit(lsremote(a[1], a[2]))
        if len(a) in (2, 3) and a[0] == "gitmeta":
            sys.exit(gitmeta(*a[1:]))
    except Exception:
        sys.exit("kept:check-failed")
    sys.exit("usage: c14_probe.py lsremote <url> <root> | gitmeta <gitdir> [<lease.json>]")
