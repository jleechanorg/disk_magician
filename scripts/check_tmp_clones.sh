#!/usr/bin/env bash
# check_tmp_clones.sh — Detect and flag full git clones, oversize scratch dirs,
# and advice/suite directories in /private/tmp (bead disk_magician-tmp-full-clones-still-produced-tjkb).
#
# Read-only detector; exits 0 always (or 2 on invalid CLI arguments).
set -euo pipefail

TMP_ROOT="${DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE:-/private/tmp}"
[[ -d "$TMP_ROOT" ]] || TMP_ROOT="/tmp"
WARN_GB="${DISK_MAGICIAN_TMP_CLONE_WARN_GB:-1}"
JSON_OUTPUT=false

usage() {
  cat <<EOF
Usage: $(basename "$0") [--json] [--warn-gb N] [--tmp-root DIR] [--help]

Detect and flag /private/tmp entries (including children under protected roots
worldarchitect.ai and worldai_claw) that are:
  - full git checkouts (.git is a directory, not a worktree gitdir: file),
  - larger than DISK_MAGICIAN_TMP_CLONE_WARN_GB GiB (default: 1), or
  - named advice*, adv-[0-9]*, *-full*, or level_up_suite_*.

Options:
  --json           Emit machine-readable JSON report
  --warn-gb N      Override size threshold in GiB (default: ${WARN_GB})
  --tmp-root DIR   Override /private/tmp root directory
  -h, --help       Show this help message
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --json)
      JSON_OUTPUT=true
      ;;
    --warn-gb)
      [[ $# -ge 2 && -n "${2:-}" ]] || { echo "Error: --warn-gb requires a numeric argument" >&2; exit 2; }
      WARN_GB="$2"
      shift
      ;;
    --warn-gb=*)
      WARN_GB="${1#*=}"
      ;;
    --tmp-root)
      [[ $# -ge 2 && -n "${2:-}" ]] || { echo "Error: --tmp-root requires a path argument" >&2; exit 2; }
      TMP_ROOT="$2"
      shift
      ;;
    --tmp-root=*)
      TMP_ROOT="${1#*=}"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

STATE_DIR="${DISK_MAGICIAN_STATE_DIR:-${HOME}/.disk_magician_state}"
PROTECTED_PARENTS="${DISK_MAGICIAN_PROTECTED_TMP_ROOTS:-worldarchitect.ai worldai_claw wa-missions}"

python3 - "$TMP_ROOT" "$WARN_GB" "$JSON_OUTPUT" "$STATE_DIR" "$PROTECTED_PARENTS" <<'PY'
import fnmatch
import hashlib
import json
import os
import re
import subprocess
import sys

tmp_root = sys.argv[1]
warn_gb_raw = sys.argv[2]
json_output = sys.argv[3].lower() == "true"
state_dir = sys.argv[4]
protected_parents = set(sys.argv[5].split())

try:
    warn_gb = float(warn_gb_raw)
    if warn_gb < 0:
        raise ValueError("negative")
except ValueError:
    print(f"Error: invalid warn-gb value: {warn_gb_raw}", file=sys.stderr)
    sys.exit(2)

warn_kb = int(round(warn_gb * 1024 * 1024))
GIB_KB = 1024 * 1024

SKIP_NAMES = {
    "_disk_magician_archive",
    "powerlog",
    "fseventsd",
}


def fmt_size(kb: int) -> str:
    gb = kb / (1024.0 * 1024.0)
    if gb >= 1.0:
        return f"{gb:.1f}G"
    mb = kb / 1024.0
    if mb >= 1.0:
        return f"{mb:.0f}M"
    return f"{kb}K"


def run_cmd(cmd, timeout=5):
    try:
        res = subprocess.run(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=timeout,
            check=False,
        )
        return res.stdout.strip() if res.returncode == 0 else ""
    except Exception:
        return ""


def measure_kb(path: str) -> int:
    out = run_cmd(["du", "-sk", path], timeout=10)
    if not out:
        return 0
    first = out.split()[0] if out.split() else "0"
    try:
        return int(first)
    except ValueError:
        return 0


def find_git_clone_dir(path: str):
    """Return the repo dir if path (or a direct child of path) has a .git directory (not a gitdir: file)."""
    dot_git = os.path.join(path, ".git")
    if os.path.isdir(dot_git) and not os.path.islink(dot_git):
        return path
    try:
        for child in os.scandir(path):
            if not child.is_dir(follow_symlinks=False):
                continue
            child_git = os.path.join(child.path, ".git")
            if os.path.isdir(child_git) and not os.path.islink(child_git):
                return child.path
    except OSError:
        pass
    return None


def git_metadata(repo_dir: str):
    if not repo_dir:
        return "", ""
    remote = run_cmd(["git", "-C", repo_dir, "config", "--get", "remote.origin.url"], timeout=3)
    branch = run_cmd(["git", "-C", repo_dir, "symbolic-ref", "--short", "HEAD"], timeout=3)
    if not branch:
        branch = run_cmd(["git", "-C", repo_dir, "rev-parse", "--abbrev-ref", "HEAD"], timeout=3)
    return remote, branch


def lease_owner(path: str) -> str:
    try:
        real = os.path.realpath(path)
        digest = hashlib.sha256(real.encode("utf-8")).hexdigest()[:16]
        lease_file = os.path.join(state_dir, "worktree_leases", f"{digest}.json")
        if os.path.isfile(lease_file):
            with open(lease_file, "r", encoding="utf-8") as fh:
                data = json.load(fh)
            parts = []
            if data.get("producer"):
                parts.append(str(data["producer"]))
            if data.get("owner_session"):
                parts.append(f"session:{data['owner_session']}")
            owner = data.get("owner")
            if isinstance(owner, dict) and owner.get("comm"):
                parts.append(f"comm:{owner['comm']}")
            if parts:
                return "/".join(parts)
    except Exception:
        pass
    for marker in (".disk_magician_owner", ".owner"):
        marker_path = os.path.join(path, marker)
        if os.path.isfile(marker_path):
            try:
                with open(marker_path, "r", encoding="utf-8", errors="ignore") as fh:
                    line = fh.readline().strip()
                if line:
                    return line
            except OSError:
                pass
    return ""


def infer_owning_lane(name: str, git_branch: str, explicit_owner: str) -> str:
    if explicit_owner:
        return explicit_owner
    lower = name.lower()
    if lower.startswith("advice") or re.match(r"^adv-[0-9]+", lower):
        m_pr = re.search(r"(pr[0-9]+|adv-[0-9]+|advice-[0-9]+)", lower)
        for tool in ("claude", "cursor", "codex", "gemini", "opus"):
            if tool in lower:
                suffix = f"{m_pr.group(1)},{tool}" if m_pr else tool
                return f"advice/review-lane ({suffix})"
        if m_pr:
            return f"advice/review-lane ({m_pr.group(1)})"
        return "advice/review-lane"
    if lower.startswith("level_up_suite_"):
        return "testing_mcp/run_level_up_class_repro_suite.sh"
    m_pr_clone = re.search(r"(pr[0-9]+)", lower)
    if m_pr_clone and ("clone" in lower or "full" in lower):
        return f"pr-clone-lane ({m_pr_clone.group(1)})"
    if "full" in lower:
        return "full-clone-scratch"
    if git_branch and git_branch != "HEAD":
        return f"git-branch:{git_branch}"
    return "unknown"


def match_name_patterns(name: str):
    reasons = []
    if fnmatch.fnmatch(name, "advice*") or re.match(r"^adv-[0-9]+", name):
        reasons.append("pattern:advice*")
    if fnmatch.fnmatch(name, "*-full*") or fnmatch.fnmatch(name, "*full-clone*"):
        reasons.append("pattern:*-full*")
    if fnmatch.fnmatch(name, "level_up_suite_*"):
        reasons.append("pattern:level_up_suite_*")
    return reasons


def inspect_entry(entry_path: str, is_protected_child: bool = False):
    name = os.path.basename(entry_path)
    if not name or name in SKIP_NAMES or name.startswith("com.apple."):
        return None
    if is_protected_child and name == "evidence":
        # Canonical evidence child is protected unless someone turned it into a full git clone
        if not (os.path.isdir(os.path.join(entry_path, ".git")) and not os.path.islink(os.path.join(entry_path, ".git"))):
            return None

    reasons = []
    clone_repo_dir = find_git_clone_dir(entry_path) if os.path.isdir(entry_path) else None
    if clone_repo_dir:
        reasons.append("full_git_clone")

    reasons.extend(match_name_patterns(name))

    size_kb = measure_kb(entry_path)
    if size_kb >= warn_kb and warn_kb > 0:
        reasons.append("oversize")

    if not reasons:
        return None

    git_remote, git_branch = git_metadata(clone_repo_dir) if clone_repo_dir else ("", "")
    explicit_owner = lease_owner(entry_path) if os.path.isdir(entry_path) else ""
    owning_lane = infer_owning_lane(name, git_branch, explicit_owner)

    return {
        "path": entry_path,
        "name": name,
        "size_kb": size_kb,
        "size_gb": round(size_kb / float(GIB_KB), 3),
        "size_human": fmt_size(size_kb),
        "reasons": reasons,
        "is_full_git_clone": bool(clone_repo_dir),
        "git_remote": git_remote,
        "git_branch": git_branch,
        "owning_lane": owning_lane,
    }


entries = []
if os.path.isdir(tmp_root):
    try:
        top_items = sorted(os.scandir(tmp_root), key=lambda e: e.name)
    except OSError:
        top_items = []

    for item in top_items:
        if item.name in SKIP_NAMES or item.name.startswith("com.apple."):
            continue
        if not item.is_dir(follow_symlinks=False):
            continue

        # If this is a protected container root (e.g. worldarchitect.ai, worldai_claw)
        # without its own top-level .git directory, inspect its children individually.
        top_dot_git = os.path.join(item.path, ".git")
        is_top_clone = os.path.isdir(top_dot_git) and not os.path.islink(top_dot_git)
        if item.name in protected_parents and not is_top_clone:
            child_flagged = False
            try:
                children = sorted(os.scandir(item.path), key=lambda e: e.name)
            except OSError:
                children = []
            for child in children:
                if not child.is_dir(follow_symlinks=False):
                    continue
                res = inspect_entry(child.path, is_protected_child=True)
                if res:
                    entries.append(res)
                    child_flagged = True
            # If the container itself is oversize and had no flagged subdir, surface it
            if not child_flagged:
                res = inspect_entry(item.path, is_protected_child=False)
                if res:
                    entries.append(res)
        else:
            res = inspect_entry(item.path, is_protected_child=False)
            if res:
                entries.append(res)

entries.sort(key=lambda e: (-e["size_kb"], e["path"]))
total_kb = sum(e["size_kb"] for e in entries)

report = {
    "tmp_root": tmp_root,
    "warn_gb": warn_gb,
    "warn_kb": warn_kb,
    "flagged_count": len(entries),
    "total_flagged_kb": total_kb,
    "total_flagged_gb": round(total_kb / float(GIB_KB), 3),
    "entries": entries,
}

if json_output:
    print(json.dumps(report, indent=2))
else:
    if entries:
        print(
            f"  ⚠️  /private/tmp clone & scratch anomalies: {len(entries)} item(s), "
            f"{fmt_size(total_kb)} total (threshold >= {warn_gb:g} GiB)"
        )
        for e in entries:
            reasons_str = ",".join(e["reasons"])
            meta_parts = [f"flags={reasons_str}", f"lane={e['owning_lane']}"]
            if e["git_branch"]:
                meta_parts.append(f"branch={e['git_branch']}")
            if e["git_remote"]:
                meta_parts.append(f"remote={e['git_remote']}")
            meta_str = " ".join(meta_parts)
            print(f"    {e['path']:<48} {e['size_human']:>8}  {meta_str}")
    else:
        print(f"  /private/tmp clone & scratch check: clean (0 anomalies, threshold >= {warn_gb:g} GiB)")
PY
