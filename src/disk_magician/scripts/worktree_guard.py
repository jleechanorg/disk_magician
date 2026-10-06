#!/usr/bin/env python3
"""worktree_guard.py — PreToolUse guard: `git worktree add` must target
$STANDARD_WORKTREE_ROOT (default ~/.worktrees). Spec D3 of
docs/superpowers/specs/2026-10-05-standard-worktree-root-and-evidence-location-design.md.

Allow = exit 0 with empty stdout. Deny = spec D3 JSON on stdout. Fail-open:
malformed input or a target that cannot be resolved statically is allowed
(unresolvable targets are logged to ~/.disk_magician_state/worktree_guard.log).
"""

import os
import re
import sys

DENY_REASON = ("Worktrees go under ~/.worktrees/<repo>/<name>. "
               "Use: diskm worktree-new <repo> <branch>")
SHELL_TOOLS = {"Bash", "bash", "shell", "exec_command"}
VALUE_OPTS = {"-b", "-B", "--reason"}


def _resolve(p):
    # Same semantics as layout_standard.sh _layout_resolve.
    p = os.path.normpath(p)
    head, tail = p, []
    while head and not os.path.exists(head):
        head, t = os.path.split(head)
        tail.insert(0, t)
    return os.path.join(os.path.realpath(head or "/"), *tail)


def _expand(word, home, variables):
    """Expand ~, $HOME and in-command vars; None if anything dynamic remains."""
    if word == "~" or word.startswith("~/"):
        word = home + word[1:]
    names = dict(variables, HOME=home)

    def sub(m):
        val = names.get(m.group(1) or m.group(2))
        return "\0" if val is None else val
    word = re.sub(r"\$\{(\w+)\}|\$(\w+)", sub, word)
    if "\0" in word or "$" in word or "`" in word:
        return None
    return word


def _absolute(path, cwd):
    if path is None:
        return None
    if os.path.isabs(path):
        return path
    return os.path.join(cwd, path) if cwd else None


def _segments(command):
    import shlex
    # A mktemp template's directory prefix is literal: judge the template itself.
    command = re.sub(r"\$\(\s*mktemp(?:\s+-[dqu]+)*\s+([^\s)\-][^\s)]*)\s*\)", r"\1", command)
    lex = shlex.shlex(command.replace("\n", " ; "), posix=True, punctuation_chars=";&|")
    lex.whitespace_split = True
    seg = []
    for tok in lex:
        if tok and set(tok) <= set(";&|"):
            if seg:
                yield seg
            seg = []
        else:
            seg.append(tok)
    if seg:
        yield seg


def _add_target(args):
    """args after `worktree add`; returns (path word or None, -b/-B branch or None)."""
    it = iter(args)
    branch = None
    for a in it:
        if a == "--":
            return next(it, None), branch
        if a in VALUE_OPTS:
            val = next(it, None)
            if a in ("-b", "-B"):
                branch = val
        elif not a.startswith("-"):
            for b in it:  # -b may follow the path
                if b in ("-b", "-B"):
                    branch = next(it, branch)
            return a, branch
    return None, branch


def _targets(command, cwd, home):
    """Yield absolute target path (or None if unresolvable, with raw word)."""
    variables = {}
    for seg in _segments(command):
        i = 0
        while i < len(seg) and "=" in seg[i] and seg[i].split("=", 1)[0].isidentifier():
            name, val = seg[i].split("=", 1)
            if len(seg) == 1 or all("=" in s for s in seg):
                variables[name] = _expand(val, home, variables)
            i += 1
        words = seg[i:]
        if not words:
            continue
        if words[0] == "cd":
            dest = _expand(words[1], home, variables) if len(words) > 1 else home
            cwd = _absolute(dest, cwd)
            continue
        if os.path.basename(words[0]) != "git":
            continue
        git_cwd, j = cwd, 1
        while j < len(words) and words[j].startswith("-"):
            if words[j] == "-C" and j + 1 < len(words):
                git_cwd = _absolute(_expand(words[j + 1], home, variables), git_cwd)
                j += 2
            elif words[j] == "-c":
                j += 2
            else:
                j += 1
        if words[j:j + 2] != ["worktree", "add"]:
            continue
        raw, branch = _add_target(words[j + 2:])
        if raw is None:
            continue
        yield _absolute(_expand(raw, home, variables), git_cwd), raw, git_cwd, branch


def _log(home, raw, command):
    try:
        import time
        state = os.path.join(home, ".disk_magician_state")
        os.makedirs(state, exist_ok=True)
        with open(os.path.join(state, "worktree_guard.log"), "a") as f:
            f.write("%s unresolvable target=%r cmd=%r\n" % (
                time.strftime("%Y-%m-%dT%H:%M:%S%z"), raw, command[:300]))
    except Exception:
        pass


def _command_text(cmd):
    if isinstance(cmd, list):
        cmd = [str(c) for c in cmd]
        for k, c in enumerate(cmd[:-1]):
            if c in ("-c", "-lc"):
                return cmd[k + 1]
        import shlex
        return shlex.join(cmd)
    return cmd if isinstance(cmd, str) else ""


def _main_repo(cwd):
    """Main checkout owning cwd (linked worktrees map to their main repo), or None."""
    import subprocess
    try:
        common = subprocess.run(
            ["git", "-C", cwd, "rev-parse", "--path-format=absolute", "--git-common-dir"],
            capture_output=True, text=True, timeout=5).stdout.strip()
    except Exception:
        return None
    if not common:
        return None
    return common if common.endswith(".git") and not common.endswith("/.git") else os.path.dirname(common)


def deny_reason(target, git_cwd, branch, root):
    """Name the concrete destination and command; generic if the repo is unknown."""
    repo = _main_repo(git_cwd) if git_cwd else None
    if not repo:
        return DENY_REASON
    name = re.sub(r"_?X{3,}$", "", os.path.basename(target.rstrip("/"))) or "wt"
    repo_name = os.path.basename(repo)
    if repo_name.endswith(".git"):
        repo_name = repo_name[:-4]
    dest = os.path.join(root, repo_name, name)
    return ("Worktrees go under ~/.worktrees/<repo>/<name>. Put this one at %s:\n"
            "  diskm worktree-new %s %s --name %s\n"
            "or: git worktree add %s%s" % (
                dest, repo, branch or "<branch>", name,
                "-b %s " % branch if branch else "", dest))


def decide(payload, home, root):
    """Return a deny reason string, or None (allow)."""
    if payload.get("tool_name") not in SHELL_TOOLS:
        return None
    ti = payload.get("tool_input") or {}
    command = _command_text(ti.get("command"))
    if "worktree" not in command:
        return None
    cwd = ti.get("workdir") or payload.get("cwd") or os.getcwd()
    shown_root, root = root, _resolve(root)
    reason = None
    for target, raw, git_cwd, branch in _targets(command, cwd, home):
        if target is None:
            _log(home, raw, command)
        elif not _resolve(target).startswith(root + "/") and reason is None:
            reason = deny_reason(target, git_cwd, branch, shown_root)
    return reason


def main():
    raw = sys.stdin.buffer.read()
    if b"worktree" not in raw or os.environ.get("DISK_MAGICIAN_WORKTREE_GUARD") == "off":
        return 0
    try:
        import json
        payload = json.loads(raw)
        home = os.environ.get("HOME") or os.path.expanduser("~")
        root = os.environ.get("STANDARD_WORKTREE_ROOT") or os.path.join(home, ".worktrees")
        verdict = decide(payload, home, root.rstrip("/"))
    except Exception:
        return 0
    if verdict:
        sys.stdout.write(json.dumps({"hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": verdict}}) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
