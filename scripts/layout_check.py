#!/usr/bin/env python3
"""layout_check.py — `diskm layout-check`: report-only layout detector (spec
docs/superpowers/specs/2026-10-05-standard-worktree-root-and-evidence-
location-design.md, D5). Deletes nothing; exits 0 always.

Reports:
  1. linked worktrees outside $STANDARD_WORKTREE_ROOT, grouped by parent dir,
     with worktree_age_days (scripts/lib/worktree_recency.sh);
  2. evidence-named dirs in home (outside /tmp and outside worktrees);
  3. worktree-guard bypasses logged in the last 7 days.

Every subprocess runs under a timeout and the whole run under --max-seconds;
any timeout or cap hit sets "truncated": true (never silent).
"""
import argparse
import glob
import json
import os
import signal
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone
from pathlib import Path

LIB = Path(__file__).resolve().parent / "lib"
LEGACY_ROOTS = ("wc-wt", "project_worldaiclaw", "worktrees", ".mctrl/worktrees",
                "projects", "projects_other")
EVIDENCE_GLOBS = ("*evidence*", "dk2d_*", "Downloads/*evidence*", ".codex/evidence-*")
CALL_TIMEOUT_S = 30


class Budget:
    def __init__(self, seconds):
        self.deadline = time.monotonic() + seconds
        self.truncated = False

    def remaining(self):
        return self.deadline - time.monotonic()


def run(cmd, budget):
    """stdout of cmd on rc 0, else None. Timeouts kill the whole process group."""
    limit = min(CALL_TIMEOUT_S, budget.remaining())
    if limit <= 0:
        budget.truncated = True
        return None
    try:
        proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                text=True, start_new_session=True)
    except OSError:
        return None
    try:
        out, _ = proc.communicate(timeout=limit)
    except subprocess.TimeoutExpired:
        budget.truncated = True
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except OSError:
            pass
        proc.communicate()
        return None
    return out if proc.returncode == 0 else None


def _real(p):
    return os.path.realpath(p)


def _children(d):
    try:
        return [e.path for e in os.scandir(d) if e.is_dir(follow_symlinks=False)]
    except OSError:
        return []


def _main_repo(d):
    """Main repo for a dir holding .git (dir -> itself, gitdir file -> owner)."""
    git = os.path.join(d, ".git")
    if os.path.isdir(git):
        return d
    try:
        with open(git) as f:
            line = f.readline().strip()
    except OSError:
        return None
    if not line.startswith("gitdir: ") or "/.git/worktrees/" not in line:
        return None
    main = line[len("gitdir: "):].split("/.git/worktrees/")[0]
    return main if os.path.isdir(os.path.join(main, ".git")) else None


def legacy_repos(home, budget):
    """Repos with a .git at depth <= 2 under the legacy worktree roots."""
    repos = set()
    for rel in LEGACY_ROOTS:
        if budget.remaining() <= 0:
            budget.truncated = True
            break
        for d1 in _children(os.path.join(home, rel)):
            if os.path.lexists(os.path.join(d1, ".git")):
                repos.add(_main_repo(d1))
                continue
            for d2 in _children(d1):
                if os.path.lexists(os.path.join(d2, ".git")):
                    repos.add(_main_repo(d2))
    repos.discard(None)
    return repos


def linked_worktrees(repo, budget):
    out = run(["git", "-C", repo, "worktree", "list", "--porcelain"], budget)
    paths = [line[len("worktree "):] for line in (out or "").splitlines()
             if line.startswith("worktree ")]
    return [p for p in paths[1:] if os.path.isdir(p)]  # [0] is the main tree


def age_days(path, budget):
    out = run(["bash", "-c", 'source "$1" && worktree_age_days "$2"', "_",
               str(LIB / "worktree_recency.sh"), path], budget)
    try:
        return int(out.strip())
    except (AttributeError, ValueError):
        return None


def guard_bypasses(home, now):
    """(count in last 7d, unparsed lines). Lines start with an ISO-8601 or epoch stamp."""
    count = unparsed = 0
    try:
        with open(os.path.join(home, ".disk_magician_state", "worktree_guard.log"),
                  errors="replace") as f:
            lines = f.read().splitlines()
    except OSError:
        return 0, 0
    for line in lines:
        if not line.strip():
            continue
        token = line.split()[0]
        try:
            if token.isdigit():
                ts = datetime.fromtimestamp(int(token), timezone.utc)
            elif len(token) == 24:  # worktree_guard.py: %Y-%m-%dT%H:%M:%S%z (-0700)
                ts = datetime.strptime(token, "%Y-%m-%dT%H:%M:%S%z")
            else:
                ts = datetime.fromisoformat(token.replace("Z", "+00:00"))
                if ts.tzinfo is None:
                    ts = ts.replace(tzinfo=timezone.utc)
        except (ValueError, OverflowError, OSError):
            unparsed += 1
            continue
        if now - ts <= timedelta(days=7):
            count += 1
    return count, unparsed


def build_report(home, max_seconds):
    budget = Budget(max_seconds)
    setup = run(["bash", "-c",
                 'source "$1/layout_standard.sh" && source "$1/worktree_repo_discovery.sh" '
                 '&& printf "%s\\n%s\\n" "$STANDARD_WORKTREE_ROOT" "$EVIDENCE_TMP_ROOT" '
                 '&& discover_worktree_repos ""', "_", str(LIB)], budget)
    lines = (setup or "").splitlines()
    root = lines[0] if lines else os.path.join(home, ".worktrees")
    tmp_root = lines[1] if len(lines) > 1 else "/tmp"
    repos = {r for r in lines[2:] if os.path.isdir(r)} | legacy_repos(home, budget)

    real_root = _real(root).rstrip("/") + "/"
    seen, outside = set(), []
    for repo in sorted({_real(r) for r in repos}):
        for wt in linked_worktrees(repo, budget):
            rp = _real(wt)
            if rp in seen:
                continue
            seen.add(rp)
            if not (rp + "/").startswith(real_root):
                outside.append({"path": wt, "repo": repo})

    with ThreadPoolExecutor(max_workers=4) as pool:
        ages = list(pool.map(lambda w: age_days(w["path"], budget), outside))
    groups = {}
    for wt, age in zip(outside, ages):
        wt["age_days"] = age
        groups.setdefault(os.path.dirname(wt["path"]), []).append(wt)

    real_tmp = _real(tmp_root).rstrip("/") + "/"
    evidence = set()
    for pattern in EVIDENCE_GLOBS:
        for p in glob.glob(os.path.join(home, pattern)):
            rp = _real(p)
            if (os.path.isdir(p) and not os.path.islink(p)
                    and not rp.startswith(real_tmp)
                    and not any(rp == s or rp.startswith(s + "/") for s in seen)):
                evidence.add(p)

    bypasses, unparsed = guard_bypasses(home, datetime.now(timezone.utc))
    return {
        "standard_worktree_root": root,
        "worktrees_outside_root": [
            {"parent": parent, "count": len(wts), "worktrees": wts}
            for parent, wts in sorted(groups.items(), key=lambda kv: (-len(kv[1]), kv[0]))
        ],
        "evidence_outside_tmp": sorted(evidence),
        "guard_bypasses_7d": bypasses,
        "guard_log_unparsed": unparsed,
        "truncated": budget.truncated,
    }


def print_table(r):
    total = sum(g["count"] for g in r["worktrees_outside_root"])
    print(f"Layout check (report only) — standard worktree root: {r['standard_worktree_root']}")
    if r["truncated"]:
        print("  ⚠️  TRUNCATED: a timeout or the run cap was hit — results are partial")
    print(f"  Worktrees outside root: {total} in {len(r['worktrees_outside_root'])} parent dir(s)")
    for g in r["worktrees_outside_root"]:
        print(f"    {g['count']:>4}  {g['parent']}")
        for w in g["worktrees"]:
            age = "?" if w["age_days"] is None else w["age_days"]
            print(f"            {w['path']}  (age {age}d, repo {w['repo']})")
    print(f"  Evidence dirs outside /tmp: {len(r['evidence_outside_tmp'])}")
    for p in r["evidence_outside_tmp"]:
        print(f"    {p}")
    print(f"  Worktree-guard bypasses (7d): {r['guard_bypasses_7d']}"
          + (f" ({r['guard_log_unparsed']} unparsed log lines)" if r["guard_log_unparsed"] else ""))


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--json", action="store_true", help="machine-readable output")
    ap.add_argument("--max-seconds", type=float, default=120, help="total run cap")
    args = ap.parse_args()
    try:
        report = build_report(os.path.expanduser("~"), args.max_seconds)
    except Exception as exc:  # report-only: never fail the caller
        print(f"layout_check: error: {exc}", file=sys.stderr)
        report = {"error": str(exc), "worktrees_outside_root": [], "evidence_outside_tmp": [],
                  "guard_bypasses_7d": 0, "guard_log_unparsed": 0, "truncated": True,
                  "standard_worktree_root": None}
    if args.json:
        print(json.dumps(report, indent=2))
    else:
        print_table(report)
    return 0


if __name__ == "__main__":
    sys.exit(main())
