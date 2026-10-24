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
import fnmatch
import io
import json
import os
import pathlib
import re
import socket
import subprocess
import sys
import tempfile

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import check_uncovered_roots as cur  # noqa: E402
import growth_top10  # noqa: E402
import resolve_config  # noqa: E402
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


def monitored_cell(path, mon):
    return "?" if mon is None else ("yes" if is_monitored(path, mon) else "**NO**")


def section_c(roots, home, days, mon):
    ranked = sorted(roots.items(), key=lambda kv: kv[1]["kb"], reverse=True)
    out = [f"### C. Cleaned roots, last {days} days", ""]
    if not ranked:
        return out + ["No deletions logged in the window.", ""]
    rows = []
    for root, e in ranked[:TOP_C]:
        scripts = ", ".join(f"`{s}` ({n})" for s, n in
                            sorted(e["scripts"].items(), key=lambda x: -x[1])[:3]) or "-"
        rows.append([f"`{fold(root, home)}`", gib(e["kb"]), str(e["n"]), scripts,
                     e["last"].strftime("%Y-%m-%dT%H:%MZ"), monitored_cell(root, mon)])
    rest = ranked[TOP_C:]
    if rest:
        rows.append([f"_{len(rest)} smaller roots_", gib(sum(e["kb"] for _, e in rest)), "", "", "", ""])
    total = sum(e["kb"] for e in roots.values())
    unknown = sum(e["unknown"] for e in roots.values())
    out += table(["Root", "GiB", "Deletions", "Owner script(s)", "Last cleaned", "Monitored"], rows)
    out += ["", f"Total logged: **{gib(total)} GiB** across {len(roots)} roots "
                f"(`du` upper bounds, not `df` deltas; {unknown} rows had no size).", ""]
    return out


def section_d(roots, home, days, mon):
    fast = [(r, e) for r, e in roots.items()
            if (len(e["days"]) >= FAST_DAYS or len(e["hours"]) >= FAST_HOURS) and e["kb"] > 0
            and not r.endswith(TOOL_STAGING)]
    fast.sort(key=lambda kv: kv[1]["kb"], reverse=True)
    out = [f"### D. Regrows fast (cleaned on >= {FAST_DAYS} days or in >= {FAST_HOURS} distinct hours)", ""]
    if not fast:
        return out + ["None in the window.", ""]
    rows = [[str(i), f"`{fold(r, home)}`", gib(e["kb"]),
             f"{len(e['hours'])} h / {len(e['days'])} of {days} days", monitored_cell(r, mon)]
            for i, (r, e) in enumerate(fast[:TOP_D], 1)]
    return out + table(["#", "Root", "GiB removed", "Cleaned in", "Monitored"], rows) + [""]


def load_monitored(state_dir, home):
    """(dir paths, glob patterns) from the effective config.

    Snapshot consumers use ``resolve_config`` while the ledger historically
    read only the state-repo mirror.  A higher-precedence XDG or explicit
    config can therefore make the ledger classify the same cleaned root as
    unmonitored until the next state-config materialization.  Resolve with
    the requested state directory as the default so ``--state-dir`` remains
    useful in isolated runs, while preserving the resolver's explicit/XDG
    precedence.
    """
    configured_state = os.environ.get("DISK_MAGICIAN_STATE_REPO")
    explicit_config = os.environ.get("DISK_MAGICIAN_CONFIG")
    if configured_state is None:
        os.environ["DISK_MAGICIAN_STATE_REPO"] = str(state_dir)
    try:
        configured = resolve_config.resolve()
    finally:
        if configured_state is None:
            os.environ.pop("DISK_MAGICIAN_STATE_REPO", None)
    if not configured:
        # An unusable explicit override is authoritative and must not silently
        # fall through to a stale state mirror.
        if explicit_config:
            return None
        configured = str(state_dir / "config" / "config.json")
    try:
        cfg = json.loads(pathlib.Path(configured).read_text())
    except (OSError, ValueError):
        return None
    ex = lambda p: (home + p[1:] if p.startswith("~") else p).replace("$HOME", home)  # noqa: E731
    dirs = {d["key"]: ex(d["path"]) for d in cfg.get("monitored_dirs", []) if "path" in d}
    gl = {g["key"]: ex(g["pattern"]) for k in ("monitored_globs", "monitored_file_globs")
          for g in cfg.get(k, []) if "pattern" in g and "key" in g}
    return dirs, list(gl.values()), {**gl, **dirs}


def is_monitored(path, mon):
    dirs, globs = mon[0], mon[1]
    path = path.rstrip("/")
    return (any(path == d or path.startswith(d + "/") for d in dirs.values())
            or any(fnmatch.fnmatch(path, g) for g in globs))


def snapshot_history(state_dir, since):
    """[(ts, snapshot dict)] sampled at most once per 6h from committed
    snapshots/disk_snapshot.json with coverage >= 70%, oldest first."""
    rel = "snapshots/disk_snapshot.json"
    r = subprocess.run(["git", "-C", str(state_dir), "log", f"--since={since.isoformat()}",
                        "--format=%H %ct", "--", rel], capture_output=True, text=True)
    out, last = [], None
    for line in reversed(r.stdout.splitlines()):
        sha, ct = line.split()
        if last is not None and int(ct) - last < 6 * 3600:
            continue
        g = subprocess.run(["git", "-C", str(state_dir), "show", f"{sha}:{rel}"],
                           capture_output=True, text=True)
        try:
            snap = json.loads(g.stdout)
        except ValueError:
            continue
        if snap.get("snapshot_coverage_pct", 0) >= 70:
            out.append((int(ct), snap))
            last = int(ct)
    return out


def section_monitored(state_dir, mon, since, days, home):
    """Growth per monitored directory vs its lowest fresh size in the window."""
    out = [f"### B1. Monitored directories vs {days}-day floor (`monitored_dirs` x committed snapshot history)", ""]
    if mon is None:
        return out + [f"Unavailable: `{state_dir}/config/config.json` unreadable.", ""]
    hist = snapshot_history(state_dir, since)
    if len(hist) < 2:
        return out + [f"Unavailable: {len(hist)} committed snapshot(s) with coverage >= 70% in the window.", ""]

    def fresh(snap):
        carried = {c.get("key") for c in snap.get("carried_keys", [])}
        return {k: v for k, v in (snap.get("directories") or {}).items()
                if isinstance(v, (int, float)) and k not in carried}
    now_ts, now_snap = hist[-1]
    now = fresh(now_snap)
    rows = []
    for key, kb in now.items():
        floor = min((fresh(sn)[key] for _, sn in hist if key in fresh(sn)), default=kb)
        if kb - floor >= GIB_KB:
            rows.append((kb - floor, key, kb, floor))
    stamp = datetime.datetime.fromtimestamp(now_ts, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%MZ")
    out.append(f"Current = snapshot at {stamp}; floor = lowest fresh size over {len(hist)} snapshots "
               f"(coverage >= 70%, one per 6 h). Carried or timed-out sizes are skipped. "
               f"{len(now)} keys measured fresh in the current snapshot. A floor can be a partial "
               f"measurement; confirm a large jump with a direct measurement.")
    out.append("")
    if not rows:
        return out + ["No monitored directory grew by 1 GiB or more over its floor.", ""]
    rows.sort(reverse=True)
    return out + table(["Key", "Path", "Now GiB", "Floor GiB", "Growth GiB"],
                       [[f"`{k}`", f"`{fold(mon[2][k], home)}`" if k in mon[2] else "(unknown)", gib(n), gib(f), gib(d)]
                        for d, k, n, f in rows[:25]]) + [""]


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
    out = [f"### B2. Top-down ledger growth vs {days}-day floor (paths outside `monitored_dirs`, via `growth-top10`)", ""]
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
    mon = load_monitored(state_dir, home)
    out += ["`monitored_dirs` (in the state repo's `config/config.json`) is the one list of directories "
            "this tool measures. This file is a report over that list, not a second list. "
            "**Monitored** = covered by `monitored_dirs`/`monitored_globs`; **NO** rows are growers or "
            "cleaned roots outside it and should be added there by editing `monitored_dirs` "
            "(`check_uncovered_roots.py --register` records sweeper owners in "
            "`config/sweeper_roots.txt`, not `monitored_dirs`).", ""]
    out += section_c(roots, home, args.days, mon) + section_d(roots, home, args.days, mon)
    out += section_monitored(state_dir, mon, since, args.days, home)
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


def read_existing(state_dir):
    """Display the published report only: no history traversal, generation or writes."""
    path = state_dir / OUT_REL
    print(f"=== Existing per-host reclaim ledger: {path} ===")
    try:
        text = path.read_text(encoding="utf-8")
    except FileNotFoundError:
        print("MISSING reclaim ledger; not evidence of no growth. Deeper diagnosis may continue.")
        return
    except (OSError, UnicodeError) as exc:
        print(f"UNREADABLE reclaim ledger ({type(exc).__name__}); not evidence of no growth. "
              "Deeper diagnosis may continue.")
        return
    # All five producer sections must be present, ordered and populated. Accept
    # unavailable/empty-window prose, without parsing tables or interpreting values.
    title = re.search(r"^# Known reclaim directories: \S.*$", text, re.M)
    sections = re.split(r"^### ([A-Z][0-9]*)\. [^\n]+\n", text, flags=re.M)
    labels = sections[1::2]
    bodies = sections[2::2]
    complete = labels == ["C", "D", "B1", "B2", "A"] and all(
        body.strip() and not body.lstrip().startswith("#") for body in bodies)
    if text.strip() and (not title or not complete):
        print("INVALID RECLAIM REPORT: incomplete producer sections or missing report title; "
              "not evidence of no growth. Deeper diagnosis may continue.")
    # Use the report's generation time, not mtime (a checkout/copy can refresh mtime).
    match = re.search(r"^Generated (\d{4}-\d{2}-\d{2} \d{2}:\d{2} UTC) by `diskm reclaim-ledger`", text, re.M)
    generated = None
    if match:
        try:
            generated = datetime.datetime.strptime(match[1], "%Y-%m-%d %H:%M UTC").replace(
                tzinfo=datetime.timezone.utc)
        except ValueError:
            pass
    now = datetime.datetime.now(datetime.timezone.utc)
    try:
        stale_hours = float(os.environ.get("DISK_MAGICIAN_LEDGER_STALE_HOURS", "48"))
        if not 0 < stale_hours < float("inf"):
            raise ValueError
    except ValueError:
        stale_hours = 48.0
    if generated is None:
        print("UNKNOWN RECLAIM REPORT AGE; not evidence of no growth.")
    elif generated > now:
        print("FUTURE RECLAIM REPORT: generation time is ahead of current UTC; "
              "not evidence of no growth.")
    elif (now - generated).total_seconds() > stale_hours * 3600:
        print(f"STALE RECLAIM REPORT: generated {generated.isoformat()}, older than "
              f"{stale_hours:g}h; not evidence of no growth.")
    # Preserve the producer's own source freshness/partial/missing banners verbatim.
    print(text, end="" if text.endswith("\n") else "\n")
    if not text.strip():
        print("EMPTY reclaim ledger; not evidence of no growth.")


def publish_report(dest, text):
    """Publish complete text atomically; failures before replace preserve old bytes."""
    # Existing config_mutator._atomic_write is JSON-specific; use its sibling
    # tempfile/flush/fsync/replace pattern here without changing the report format.
    fd, name = tempfile.mkstemp(prefix=f".{dest.name}.", suffix=".tmp", dir=dest.parent)
    temp = pathlib.Path(name)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
        if dest.exists():
            os.chmod(temp, dest.stat().st_mode & 0o777)
        os.replace(temp, dest)
    finally:
        try:
            temp.unlink()
        except FileNotFoundError:
            pass


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--state-dir", default=None)
    p.add_argument("--read-existing", action="store_true",
                   help="display the existing per-host report without regeneration or writes")
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
    if args.read_existing:
        read_existing(state_dir)
        return 0
    now = parse_ts(args.now) if args.now else datetime.datetime.now(datetime.timezone.utc)
    text = render(args, state_dir, now)
    if args.stdout:
        sys.stdout.write(text)
        return 0
    dest = state_dir / OUT_REL
    dest.parent.mkdir(parents=True, exist_ok=True)
    publish_report(dest, text)
    status = "written"
    if not args.no_commit and (state_dir / ".git").exists():
        status = commit(state_dir, OUT_REL, now.strftime("%Y-%m-%dT%H:%M:%SZ"))
    print(f"reclaim-ledger: {dest} ({status})")
    return 0 if status not in ("add_failed", "commit_failed") else 1


if __name__ == "__main__":
    sys.exit(main())
