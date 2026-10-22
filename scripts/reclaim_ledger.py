#!/usr/bin/env python3
"""reclaim_ledger.py — regenerate this machine's reclaim ledger from live data.

Writes <state-repo>/reclaim/known-reclaim-dirs.md and commits it there. The
generic reading guide lives in the repo at docs/known-reclaim-dirs.md; every
number here is computed, never hand-written:

  C  cleaned roots, last N days   deletion log (DISK_MAGICIAN_DELETION_LOG)
  D  fast regrowers               same log: roots cleaned in many hours/days
  B  growth vs N-day floor        growth_top10 (committed ledger history)
  A  uncovered / needs-decision   check_uncovered_roots (frontier data)

Reuses growth_top10, check_uncovered_roots and check_ledger_freshness.sh; this
file only aggregates and renders.
"""
import argparse
import contextlib
import datetime
import io
import json
import os
import pathlib
import socket
import subprocess
import sys

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import check_uncovered_roots as cur  # noqa: E402
import growth_top10  # noqa: E402
import resolve_state_repo_path  # noqa: E402

GIB_KB = 1024 * 1024
OUT_REL = "reclaim/known-reclaim-dirs.md"
FAST_DAYS = 3    # cleaned on this many distinct days ...
FAST_HOURS = 6   # ... or in this many distinct hours => regrows fast
TOP_C, TOP_D = 30, 15
TOOL_STAGING = ("/_disk_magician_archive",)  # the tool's own staging target, not a producer


def norm(path):
    """macOS /tmp -> /private/tmp style aliases; identity elsewhere (Linux /tmp is real)."""
    return cur.normalize_alias(path) if sys.platform == "darwin" else path


def parse_ts(text):
    try:
        return datetime.datetime.strptime(text, "%Y-%m-%dT%H:%M:%SZ").replace(
            tzinfo=datetime.timezone.utc)
    except ValueError:
        return None


def group_root(path, home):
    """Parent root for a cleaned path (macOS tmp/var classes, $HOME, Linux /tmp)."""
    root, _ = cur.parent_root(path, home)
    if root:
        return root
    parts = path.split("/")
    if path.startswith(("/tmp/", "/var/tmp/")) and len(parts) > 3:
        return "/".join(parts[:4])
    return "/".join(parts[:3]) if len(parts) > 3 else path


def load_deletions(log_path, since, home):
    """{root: stats} for non-dry-run rows at/after `since`; unknown-size rows
    (kb < 0) count toward `n` and `unknown` but not toward kb."""
    roots, rows = {}, 0
    try:
        fh = open(log_path, errors="replace")
    except OSError:
        return roots, None
    with fh:
        for line in fh:
            f = line.rstrip("\n").split("\t")
            if len(f) < 5 or "dry" in f[2]:
                continue
            ts = parse_ts(f[0])
            if ts is None or ts < since:
                continue
            path = norm(f[4].split(" -> ", 1)[0].strip().rstrip("/"))
            if not path.startswith("/"):
                continue
            try:
                kb = int(float(f[3]))
            except ValueError:
                kb = -1
            ent = roots.setdefault(group_root(path, home), {
                "kb": 0, "n": 0, "unknown": 0, "scripts": {}, "hours": set(),
                "days": set(), "last": ts})
            ent["n"] += 1
            if kb < 0:
                ent["unknown"] += 1
            else:
                ent["kb"] += kb
                ent["scripts"][f[1]] = ent["scripts"].get(f[1], 0) + 1
            ent["hours"].add(f[0][:13])
            ent["days"].add(f[0][:10])
            ent["last"] = max(ent["last"], ts)
            rows += 1
    return roots, rows


def fold(path, home):
    return "~" + path[len(home):] if path == home or path.startswith(home + "/") else path


def gib(kb):
    return f"{kb / GIB_KB:.2f}"


def table(head, rows):
    out = ["| " + " | ".join(head) + " |", "|" + "|".join("---" for _ in head) + "|"]
    out += ["| " + " | ".join(r) + " |" for r in rows]
    return out


def section_c(roots, home, days):
    ranked = sorted(roots.items(), key=lambda kv: kv[1]["kb"], reverse=True)
    out = [f"### C. Cleaned roots, last {days} days", ""]
    if not ranked:
        return out + ["No deletions logged in the window.", ""]
    rows = []
    for root, e in ranked[:TOP_C]:
        scripts = ", ".join(f"`{s}` ({n})" for s, n in
                            sorted(e["scripts"].items(), key=lambda x: -x[1])[:3]) or "-"
        rows.append([f"`{fold(root, home)}`", gib(e["kb"]), str(e["n"]), scripts,
                     e["last"].strftime("%Y-%m-%dT%H:%MZ")])
    rest = ranked[TOP_C:]
    if rest:
        rows.append([f"_{len(rest)} smaller roots_", gib(sum(e["kb"] for _, e in rest)), "", "", ""])
    total = sum(e["kb"] for e in roots.values())
    unknown = sum(e["unknown"] for e in roots.values())
    out += table(["Root", "GiB", "Deletions", "Owner script(s)", "Last cleaned"], rows)
    out += ["", f"Total logged: **{gib(total)} GiB** across {len(roots)} roots "
                f"(`du` upper bounds, not `df` deltas; {unknown} rows had no size).", ""]
    return out


def section_d(roots, home, days):
    fast = [(r, e) for r, e in roots.items()
            if (len(e["days"]) >= FAST_DAYS or len(e["hours"]) >= FAST_HOURS) and e["kb"] > 0
            and not r.endswith(TOOL_STAGING)]
    fast.sort(key=lambda kv: kv[1]["kb"], reverse=True)
    out = [f"### D. Regrows fast (cleaned on >= {FAST_DAYS} days or in >= {FAST_HOURS} distinct hours)", ""]
    if not fast:
        return out + ["None in the window.", ""]
    rows = [[str(i), f"`{fold(r, home)}`", gib(e["kb"]),
             f"{len(e['hours'])} h / {len(e['days'])} of {days} days"]
            for i, (r, e) in enumerate(fast[:TOP_D], 1)]
    return out + table(["#", "Root", "GiB removed", "Cleaned in"], rows) + [""]


def run_json(fn, argv):
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf), contextlib.redirect_stderr(io.StringIO()):
        rc = fn(argv)
    try:
        return rc, json.loads(buf.getvalue())
    except ValueError:
        return rc, None


def section_b(state_dir, days):
    rc, data = run_json(growth_top10.main, [
        "--days", str(days), "--limit", "25", "--state-dir", str(state_dir), "--json"])
    out = [f"### B. Growth vs {days}-day floor (committed ledger history, via `growth-top10`)", ""]
    if not data:
        return out + ["Unavailable: growth-top10 produced no result.", ""]
    kind = data.get("comparison_kind")
    if kind in ("no_floor", "no_current"):
        return out + [f"Unavailable: `{data.get('reason')}` (no fresh full-disk ledger to compare). "
                      "Re-run after the next complete frontier scan.", ""]
    out.append(f"Floor {gib(data.get('floor_used_kb', 0))} GiB at {data.get('floor_captured_at')}; "
               f"current {gib(data.get('current_used_kb', 0))} GiB at {data.get('current_captured_at')} "
               f"({data.get('current_source')}); comparison `{kind}`.")
    out.append("")
    growing = data.get("top_growth") or []
    if growing:
        out += table(["Path", "Growth GiB"],
                     [[f"`{d['path']}`", gib(d["delta_kb"])] for d in growing])
    else:
        out.append("No growing path exceeded the floor"
                   + (f" ({len(data.get('unknown') or [])} paths unmeasured)." if data.get("unknown") else "."))
    return out + [""]


def source_age(source, now):
    """' (file age 12.3h)' for a 'snapshot:<path>' source, else ''."""
    if source and source.startswith("snapshot:"):
        try:
            mtime = os.path.getmtime(source.split(":", 1)[1])
        except OSError:
            return ""
        return f" (file age {now.timestamp() / 3600 - mtime / 3600:.1f}h)"
    return ""


def section_a(frontier, home, now):
    argv = ["--json", "--threshold-gib", "5", "--home", home]
    if frontier:
        argv += ["--snapshot", frontier]
    rc, data = run_json(cur.main, argv)
    out = ["### A. Uncovered / needs-decision / protected rows >= 5 GiB", ""]
    if not data:
        return out + ["Unavailable: check_uncovered_roots produced no result.", ""]
    rows = []
    for cls, key in (("uncovered", "uncovered"), ("needs-decision", "needs_decision"),
                     ("protected", "protected")):
        for e in data.get(key) or []:
            rows.append([f"`{fold(e['path'], home)}`", f"{e['size_kb'] / GIB_KB:.1f}", cls,
                         (e.get("note") or e.get("reason") or "")[:120]])
    rows.sort(key=lambda r: -float(r[1]))
    if not rows:
        return out + [f"None (source: {data.get('source')}).", ""]
    return out + [f"Source: {data.get('source')}{source_age(data.get('source'), now)}.", ""] + table(
        ["Path", "GiB", "Class", "Note"], rows) + [""]


def freshness_line(override, state_dir):
    if override is not None:
        return override
    env = dict(os.environ, DISK_MAGICIAN_STATE_REPO=str(state_dir))
    try:
        r = subprocess.run(["bash", str(HERE / "check_ledger_freshness.sh")], env=env,
                           capture_output=True, text=True, timeout=60)
        return (r.stdout.strip().splitlines() or ["UNKNOWN\tno output"])[-1]
    except (OSError, subprocess.SubprocessError) as exc:
        return f"UNKNOWN\t{exc}"


def render(args, state_dir, now):
    home = norm(args.home)
    since = now - datetime.timedelta(days=args.days)
    roots, rows = load_deletions(args.deletions_log, since, home)
    fresh = " ".join(freshness_line(args.freshness_line, state_dir).split())[:240]
    stale = not fresh.startswith("OK ") or "status=stale" in fresh
    host = socket.gethostname()
    marker = state_dir / "MACHINE"
    if marker.is_file():
        for line in marker.read_text().splitlines():
            if line.startswith("hostname:"):
                host = line.split(":", 1)[1].strip()
    out = [f"# Known reclaim directories: {host}", "",
           f"Generated {now.strftime('%Y-%m-%d %H:%M UTC')} by `diskm reclaim-ledger` "
           f"(window {args.days}d). Read this first in any disk investigation or cleanup; "
           "how to read it and the re-clean commands are in the repo's `docs/known-reclaim-dirs.md`.", ""]
    if stale:
        out += [f"> **STALE FULL-DISK LEDGER**: `{fresh}`. Sections A and B use older full-disk data "
                "or are unavailable; C and D come from the deletion log and are current.", ""]
    else:
        out += [f"Full-disk ledger freshness: `{fresh}`.", ""]
    src = args.deletions_log + (f" ({rows} rows in window)" if rows is not None else " (missing)")
    out += [f"Deletion log source: `{fold(src, home)}`.", ""]
    out += section_c(roots, home, args.days) + section_d(roots, home, args.days)
    out += section_b(state_dir, args.days) + section_a(args.frontier, home, now)
    return "\n".join(out).rstrip() + "\n"


def commit(state_dir, rel, stamp):
    git = ["git", "-C", str(state_dir), "-c", "user.name=disk-magician",
           "-c", "user.email=disk-magician@localhost"]
    if subprocess.run(git + ["add", "--", rel], capture_output=True).returncode:
        return "add_failed"
    if subprocess.run(git + ["diff", "--cached", "--quiet", "--", rel]).returncode == 0:
        return "unchanged"
    r = subprocess.run(git + ["commit", "-q", "-m", f"reclaim-ledger {stamp}", "--", rel],
                       capture_output=True)
    return "committed" if r.returncode == 0 else "commit_failed"


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--state-dir", default=None)
    p.add_argument("--deletions-log", default=os.environ.get(
        "DISK_MAGICIAN_DELETION_LOG",
        os.path.expanduser("~/Library/Logs/disk-magician-deletions.log")))
    p.add_argument("--home", default=os.path.expanduser("~"))
    p.add_argument("--frontier", default=None, help="frontier JSON for section A (testing)")
    p.add_argument("--days", type=int, default=7)
    p.add_argument("--stdout", "--dry-run", dest="stdout", action="store_true",
                   help="print the ledger; write and commit nothing")
    p.add_argument("--no-commit", action="store_true", help="write the file but do not commit")
    p.add_argument("--freshness-line", default=None, help=argparse.SUPPRESS)
    p.add_argument("--now", default=None, help=argparse.SUPPRESS)
    args = p.parse_args(argv)
    if args.days <= 0:
        p.error("--days must be positive")

    state_dir = pathlib.Path(args.state_dir or resolve_state_repo_path.resolve())
    now = parse_ts(args.now) if args.now else datetime.datetime.now(datetime.timezone.utc)
    text = render(args, state_dir, now)
    if args.stdout:
        sys.stdout.write(text)
        return 0
    dest = state_dir / OUT_REL
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_text(text)
    status = "written"
    if not args.no_commit and (state_dir / ".git").exists():
        status = commit(state_dir, OUT_REL, now.strftime("%Y-%m-%dT%H:%M:%SZ"))
    print(f"reclaim-ledger: {dest} ({status})")
    return 0 if status not in ("add_failed", "commit_failed") else 1


if __name__ == "__main__":
    sys.exit(main())
