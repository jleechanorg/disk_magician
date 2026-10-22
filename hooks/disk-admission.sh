#!/usr/bin/env bash
# disk-admission.sh — Claude Code Bash hook (spec C6). PreToolUse: admit each governed `git worktree add`,
# `git clone`, `cp -R` (`diskm admit --source hook`); 76 waits DISK_MAGICIAN_ADMIT_RETRY_S (600) once and re-admits;
# 75 or a second 76 deny, 10 or another rc → systemMessage, 0 silent;
# never updatedInput. PostToolUse confirms only a single simple command that exited 0. Newline, heredoc,
# $( ), backticks, eval or a subshell → not parsed (hook_unparsed). Always exits 0. Test hook: DISK_MAGICIAN_ADMIT_BIN.
read -r -d '' PY <<'EOF'
import fcntl, json, os, re, shlex, subprocess, sys, time
ev = json.load(sys.stdin); cmd = (ev.get("tool_input") or {}).get("command") or ""; tid = ev.get("tool_use_id") or ""
admit = [os.environ["DISK_MAGICIAN_ADMIT_BIN"]] if os.environ.get("DISK_MAGICIAN_ADMIT_BIN") else ["diskm", "admit"]
home, tmpd = os.path.expanduser("~"), os.path.realpath(os.environ.get("TMPDIR") or "/nonexistent")
private_tmp = "/private/tmp" if sys.platform == "darwin" else "/tmp"
def canon(p):
    p = os.path.normpath(p)
    if sys.platform == "darwin": p = re.sub(r"^/tmp(?=/|$)", "/private/tmp", p)
    return os.path.join(os.path.realpath(os.path.dirname(p)), os.path.basename(p))
ROOTS = [(os.path.realpath(r), n, c) for r, n, c in [(home + "/.worktrees", 2, "worktrees"),
         (home + "/Documents/Codex", 2, "codex_documents"), (tmpd, 1, "tmpdir_scratch"), (private_tmp, 1, "tmp_containers")]]
def governed(p):
    p = canon(p)
    for root, depth, cls in ROOTS:
        if p.startswith(root + "/") and len(p[len(root) + 1:].split("/")) >= depth: return p, cls
def unparsed():
    if not re.search(r"\b(git|cp)\b", cmd): return
    st = os.environ.get("DISK_MAGICIAN_STATE_DIR") or home + "/.disk_magician_state"
    try:
        os.makedirs(st + "/admission", exist_ok=True)
        with open(st + "/state.lock", "a") as lk, open(st + "/admission/events.jsonl", "a") as f:
            fcntl.flock(lk, fcntl.LOCK_EX); f.write(json.dumps(dict(event="hook_unparsed", at=time.time(), tool_use_id=tid)) + "\n")
    except OSError: pass
try:
    lex = shlex.shlex(cmd, posix=True, punctuation_chars=True); lex.whitespace_split = True; toks = list(lex)
except ValueError: toks = None
if toks is None or re.search(r"\n|\$\(|`|<<", cmd) or {"eval", "(", ")"} & set(toks or []): sys.exit(unparsed())
segs, cur, skip = [[]], ev.get("cwd") or os.getcwd(), False
for t in toks:  # a redirection drops its target and an fd number before it
    if skip: skip = False
    elif re.fullmatch(r"&?[<>]+&?", t): skip = True; segs[-1][-1:] and segs[-1][-1].isdigit() and segs[-1].pop()
    elif t in ("&&", "||", ";", "|", "|&", "&"): segs.append([])
    else: segs[-1].append(t)
compound, found = len(segs) > 1, []
for s in segs:
    while s and re.match(r"[A-Za-z_]\w*=", s[0]): s = s[1:]
    if not s: continue
    at = lambda p, base=cur: os.path.normpath(os.path.join(base, os.path.expanduser(re.sub(r"^\$\{?HOME\}?(?=/|$)", "~", p))))
    if s[0] == "cd": cur = at(s[1] if len(s) > 1 else home); continue
    pos, d, i = [], cur, 1
    while s[0] == "git" and i < len(s) and s[i].startswith("-"):
        if s[i] in ("-C", "-c", "--git-dir", "--work-tree", "--namespace", "--config-env") and i + 1 < len(s): d = at(s[i + 1], d) if s[i] == "-C" else d; i += 1
        i += 1
    args = s[i:] if s[0] == "git" else s[1:]
    pos = [a for j, a in enumerate(args) if not a.startswith("-") and args[j - 1] not in (("-b", "-B", "--branch", "-o", "--origin", "--depth", "--reference", "--config", "-c", "--template", "--filter",
           "-j", "--jobs", "--reason", "--separate-git-dir", "--shallow-since", "--shallow-exclude", "--server-option", "--upload-pack") if s[0] == "git" else ())]
    if s[0] == "git" and args[:2] == ["worktree", "add"] and len(pos) > 2: dest, prod, est, src = pos[2], "hook:git-worktree-add:" + os.path.basename(d), 1, None
    elif s[0] == "git" and args[:1] == ["clone"] and len(pos) > 1:
        url = pos[1]; dest = pos[2] if len(pos) > 2 else re.sub(r"\.git$", "", url.rstrip("/").split("/")[-1].split(":")[-1])
        prod, est, src = "hook:git-clone:" + re.sub(r"\.git$", "", re.sub(r"^[a-z+]+://([^@/]*@)?|^[^@/:]*@", "", url).replace(":", "/", 1)), 2, None
    elif s[0] == "cp" and any(re.fullmatch(r"-[A-Za-z]*[Rra][A-Za-z]*|--recursive|--archive", a) for a in args) and len(pos) > 1: dest, prod, est, src = pos[-1], "hook:cp-R", 1, at(pos[0])
    else: continue
    if src and os.path.isdir(dest := at(dest, d)): dest = os.path.join(dest, os.path.basename(src))  # cp into an existing dir
    if (g := governed(at(dest, d))) is None: continue
    if src:
        try: est = max(est, int(subprocess.run(["du", "-sk", src], capture_output=True, text=True, timeout=5).stdout.split()[0]) / 2**20)
        except (OSError, ValueError, IndexError, subprocess.SubprocessError): pass
    found.append([*admit, "--class", g[1], *(["--est-gb", f"{est:g}"] if src else []), "--dest", g[0], "--producer", prod, "--source", "hook", "--tool-use-id", tid] + ["--compound"] * compound)
if not found: sys.exit()
if ev.get("hook_event_name") != "PreToolUse":
    resp = ev.get("tool_response") if isinstance(ev.get("tool_response"), dict) else {}
    rc = next((resp[k] for k in ("exit_code", "exitCode", "returnCode") if k in resp), 0)
    if ev.get("hook_event_name") == "PostToolUse" and not compound and rc == 0 and not resp.get("interrupted"):
        subprocess.run([*admit, "--confirm-tool-use", tid], capture_output=True, timeout=30)
    sys.exit()
msgs, deny = [], None
def run(a):
    try: return subprocess.run(a, capture_output=True, timeout=60).returncode
    except (OSError, subprocess.SubprocessError): return "missing"
for a in found:
    if (rc := run(a)) == 76: time.sleep(float(os.environ.get("DISK_MAGICIAN_ADMIT_RETRY_S") or 600)); rc = run(a)
    cls, dest = a[a.index("--class") + 1], a[a.index("--dest") + 1]
    if rc == 75: deny = deny or f"disk-admission: refused class={cls} rc=75 for {dest}: disk is low; reuse an existing worktree or checkout instead of creating a new one"
    elif rc == 76: deny = deny or f"disk-admission: refused class={cls} rc=76 for {dest}: BLACK zone; still queued after one retry_after_s wait"
    elif rc == 10: msgs.append(f"disk-admission: warn class={cls} for {dest}")
    elif rc != 0: msgs.append(f"admission_degraded:caller rc={rc} for {dest}")
out = {"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": deny}} if deny else {}
if msgs and not deny: out["systemMessage"] = "; ".join(msgs)
if out: print(json.dumps(out))
EOF
python3 -c "$PY" 2>/dev/null
exit 0
