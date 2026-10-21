#!/usr/bin/env python3
"""diskm setup --hooks: install the C6 admission hook (hooks/disk-admission.sh, run as
`diskm admission-hook`) into Claude Code's settings.json as a Bash PreToolUse and PostToolUse
hook (plan Task B1). Idempotent: an already-installed entry leaves the file byte-identical.
Writes only when the C11 decision external_edits is recorded (no bypass flag); unrecorded → rc 75.
Malformed JSON or a wrong-typed hooks block → rc 2, file untouched."""
import argparse, json, os, sys, tempfile
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import policy_provenance

COMMAND = "diskm admission-hook"
ENTRY = {"type": "command", "command": COMMAND, "timeout": 780}  # one 600 s rc-76 wait + two admits


def install(settings):
    hooks = settings.setdefault("hooks", {})
    if not isinstance(hooks, dict): raise TypeError("hooks is not an object")
    changed = False
    for event in ("PreToolUse", "PostToolUse"):
        groups = hooks.setdefault(event, [])
        if not isinstance(groups, list) or not all(isinstance(g, dict) for g in groups):
            raise TypeError(f"hooks.{event} is not a list of objects")
        if any(isinstance(h, dict) and h.get("command") == COMMAND
               for g in groups if g.get("matcher") == "Bash" for h in g.get("hooks") or []):
            continue
        bash = next((g for g in groups if g.get("matcher") == "Bash" and isinstance(g.get("hooks"), list)), None)
        if bash is None: groups.append({"matcher": "Bash", "hooks": [dict(ENTRY)]})
        else: bash["hooks"].append(dict(ENTRY))
        changed = True
    return changed


def main(argv=None):
    p = argparse.ArgumentParser(prog="diskm setup --hooks")
    p.add_argument("--hooks", action="store_true", required=True)
    p.add_argument("--settings", default=os.path.join(
        os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude"), "settings.json"))
    a = p.parse_args(argv)
    try: settings = json.loads(open(a.settings, encoding="utf-8").read()) if os.path.exists(a.settings) else {}
    except (OSError, ValueError) as e: return print(f"setup --hooks: unreadable {a.settings}: {e}", file=sys.stderr) or 2
    if not isinstance(settings, dict): return print(f"setup --hooks: {a.settings} is not a JSON object", file=sys.stderr) or 2
    try: changed = install(settings)
    except TypeError as e: return print(f"setup --hooks: {a.settings}: {e}", file=sys.stderr) or 2
    if not changed: return print(f"setup --hooks: already installed in {a.settings}") or 0
    try: approved = policy_provenance.main("approved", "external_edits") == 0
    except Exception: approved = False  # an unreadable decision record is not approved
    if not approved:
        return print("setup --hooks: refused: decision external_edits is not recorded "
                     "(diskm policy approve external_edits --from-transcript <session.jsonl>)", file=sys.stderr) or 75
    target = os.path.realpath(a.settings)  # a symlinked settings.json keeps its link
    try:
        fd, tmp = tempfile.mkstemp(dir=os.path.dirname(target), prefix=".settings.", suffix=".tmp")
        with os.fdopen(fd, "w", encoding="utf-8") as f: f.write(json.dumps(settings, indent=2, ensure_ascii=False) + "\n")
        os.chmod(tmp, os.stat(target).st_mode & 0o7777 if os.path.exists(target) else 0o644)
        os.replace(tmp, target)
    except OSError as e: return print(f"setup --hooks: cannot write {target}: {e}", file=sys.stderr) or 2
    print(f"setup --hooks: installed `{COMMAND}` (PreToolUse, PostToolUse Bash) in {a.settings}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
