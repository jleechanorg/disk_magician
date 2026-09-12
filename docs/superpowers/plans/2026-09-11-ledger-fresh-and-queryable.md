# Implementation plan: PR2 "the ledger is fresh and queryable" (F, G, H)

Bead: `disk_magician-zyn`. Design: `docs/superpowers/specs/2026-09-11-ledger-fresh-and-queryable-design.md`
(read that first — this plan assumes its component numbering: F = partial
ledger, G = `growth-top10`, H = hot-dir/monitored-dir visibility gap, plus
the ledger-freshness check that F/H's acceptance criteria require).

Do not implement F, G, and H in a single mega-commit. Land in this order —
each step is independently testable and G depends on F's constant names.

## Step 1 — F: partial ledger artifact

**File:** `scripts/render_topdown_ledger.py`

1.1. Add constant near the top, next to `LEDGER_JSON`/`LEDGER_MD`:
```python
PARTIAL_LEDGER_JSON = "topdown-5g.partial.json"
```

1.2. Add, near the top after the existing imports:
```python
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import history_diff  # noqa: E402
```
(Mirrors the exact pattern `history_diff.py` already uses to import
`resolve_state_repo_path` — same directory, same style. Verify
`scripts/history_diff.py` has no import that would create a cycle back into
`render_topdown_ledger.py` — it does not, confirmed by reading the file.)

1.3. Extract the existing dict-literal (currently built inline right before
`with open(os.path.join(args.out_dir, LEDGER_JSON), "w") as f:`) into a
new function placed above `main()`:
```python
def build_ledger_dict(report: dict, captured_at: str) -> dict:
    buckets = report.get("granularity_buckets") or []
    oversize = report.get("oversize_indivisible_files") or []
    equation = report.get("accounting_equation") or {}
    return {
        "schema_version": SCHEMA_VERSION,
        "mode": report.get("mode"),
        "coverage_envelope": report.get("coverage_envelope"),
        "frontier_unfinished": report.get("frontier_unfinished"),
        "opaque_intrinsic_gates": report.get("opaque_intrinsic_gates"),
        "fda_preflight": report.get("fda_preflight"),
        "fda_probe_paths": report.get("fda_probe_paths"),
        "system_boundary_attestations": report.get("system_boundary_attestations"),
        "run_id": report.get("run_id"),
        "run_started_at": report.get("run_started_at"),
        "run_finished_at": report.get("run_finished_at"),
        "captured_at": captured_at,
        "hostname": report.get("hostname"),
        "disk_used_kb": report.get("disk_used_kb"),
        "residual_kb": report.get("residual_kb"),
        "purgeable_kb": report.get("purgeable_kb"),
        "granularity_buckets": buckets,
        "oversize_indivisible_files": oversize,
        "accounting_equation": equation,
    }
```
This is a byte-for-byte extraction of the existing dict (verify by diffing
field names against the current inline literal before deleting it) — no
field added or removed in this step.

1.4. In `main()`, replace the inline `ledger = {...}` literal (in the
`complete_coverage_envelope(report)` branch) with `ledger = build_ledger_dict(report, captured_at)`.

1.5. Immediately after the existing stale-check block
(`if age_hours > STALE_HOURS: ... return 0`) and the `os.makedirs(args.out_dir, exist_ok=True)`
call, and BEFORE the `if not complete_coverage_envelope(report):` branch,
insert:
```python
    partial_ledger = build_ledger_dict(report, captured_at)
    partial_ledger["unfinished_top_level_roots"] = [
        item.get("path")
        for item in (report.get("frontier_unfinished") or [])
        if isinstance(item, dict) and item.get("path")
    ]
    if partial_ledger["granularity_buckets"]:
        try:
            history_diff.validate_ledger(partial_ledger, label="partial-candidate")
        except history_diff.LedgerError as exc:
            print(f"render_topdown_ledger: skipping partial artifact — {exc}", file=sys.stderr)
        else:
            with open(os.path.join(args.out_dir, PARTIAL_LEDGER_JSON), "w") as f:
                json.dump(partial_ledger, f, indent=2)
                f.write("\n")
    else:
        print("render_topdown_ledger: skipping partial artifact — no granularity buckets in report", file=sys.stderr)
```
Note: this runs unconditionally (both the complete and incomplete branches
below still execute after it) — `topdown-5g.partial.json` is refreshed on
every fresh, reconciling, non-empty run, complete or not (design §2 Q1).

1.6. In the `if not complete_coverage_envelope(report):` branch, no other
change — it still only writes `topdown-5g.status.json` for the canonical
side, exactly as today.

1.7. In the complete branch (the code that writes `LEDGER_JSON`/`LEDGER_MD`),
no change other than step 1.4's dict-source swap.

**Tests — `tests/test_render_topdown_ledger.py`:**

1.8. Add `test_partial_run_writes_partial_json_canonical_untouched`:
build an incomplete-envelope fixture (existing `_fixture(age_hours=1,
mode="partial", envelope_complete=False)` helper — check it already
produces reconciling `granularity_buckets`/`residual_kb`/`disk_used_kb`; if
the existing fixture helper zeroes out buckets for partial mode, extend it
with a `buckets` kwarg defaulting to a single reconciling bucket so this
test has real data to assert on). Run the script twice: first assert
`topdown-5g.json` does NOT exist yet (fresh tmp dir), run with the partial
fixture, assert `topdown-5g.partial.json` exists, parses as JSON, has
`mode` matching the fixture, and `unfinished_top_level_roots` is a
non-empty list of strings when the fixture's `frontier_unfinished` is
non-empty. Assert `topdown-5g.json` still does not exist (canonical
untouched by a partial run when it never existed).

1.9. Add `test_complete_run_refreshes_both_canonical_and_partial`: run with
the existing complete fixture, assert both `topdown-5g.json` and
`topdown-5g.partial.json` exist and their `disk_used_kb`/`granularity_buckets`
fields are equal (same source ledger dict, written twice).

1.10. Add `test_partial_run_after_complete_run_leaves_canonical_untouched_but_refreshes_partial`:
run complete fixture first (capture `topdown-5g.json` mtime/content), then
run an incomplete fixture with a DIFFERENT `disk_used_kb`, assert
`topdown-5g.json` content is byte-identical to the first run's, but
`topdown-5g.partial.json` now reflects the second (incomplete) run's
`disk_used_kb`. This is the core regression guard for "canonical file
untouched."

1.11. Add `test_partial_run_with_nonreconciling_buckets_skips_write`: build
a fixture whose `buckets` + `residual_kb` deliberately do NOT sum to
`disk_used_kb` (e.g. off by one KB). Pre-create a `topdown-5g.partial.json`
with known sentinel content in the output dir. Run the script, assert exit
code 0 (fail-open, not a crash), assert stderr contains
`"skipping partial artifact"`, assert `topdown-5g.partial.json`'s content is
UNCHANGED (still the sentinel) — proves fail-closed-on-write, not
fail-closed-on-crash.

1.12. Add `test_stale_report_skips_partial_write_too`: reuse the existing
stale-report test's fixture (`age_hours` > 36), assert `topdown-5g.partial.json`
is not created (matches existing canonical stale-skip behavior).

1.13. In `tests/test_history_diff.py`, add
`test_render_topdown_ledger_partial_output_passes_validate_ledger`: import
both `render_topdown_ledger` and `history_diff` (both already importable
per each file's own test's `sys.path.insert` pattern — copy it), build a
minimal complete-mode report dict inline (or reuse
`render_topdown_ledger`'s own test fixture helper if trivially
importable — otherwise a small local literal is fine, this is an
integration smoke test not a full fixture reuse), call
`render_topdown_ledger.build_ledger_dict(report, captured_at)`, and assert
`history_diff.validate_ledger(result, label="t")` does not raise. This is
the drift guard between the two files' independent schema assumptions
mentioned in the design doc §0.2.

**Verify Step 1 in isolation:**
```
python3 -m pytest tests/test_render_topdown_ledger.py -q
python3 -m pytest tests/test_history_diff.py -q -k partial_output
```

## Step 2 — G: `disk_magician.sh growth-top10`

**New file:** `scripts/growth_top10.py`

2.1. Write the script per design §4's algorithm exactly. Skeleton:
```python
#!/usr/bin/env python3
"""growth_top10.py — print the top-N growing paths vs. the lowest-used
full-attribution ledger in the last N days (default 14), reusing
history_diff.py's floor selection and delta computation. No `du`, no
filesystem walk — reads only committed git history + the working-tree
ledger/topdown-5g.partial.json (falling back to topdown-5g.json).

Design: docs/superpowers/specs/2026-09-11-ledger-fresh-and-queryable-design.md
Component G. Bead: disk_magician-zyn.
"""
import argparse, json, os, pathlib, sys

import history_diff
import resolve_state_repo_path

GIB_KB = history_diff.GIB_KB
PARTIAL_LEDGER_REL_PATH = "ledger/topdown-5g.partial.json"
CANONICAL_LEDGER_REL_PATH = history_diff.LEDGER_REL_PATH


def load_current(state_dir: pathlib.Path):
    for rel_path, label in (
        (PARTIAL_LEDGER_REL_PATH, "partial"),
        (CANONICAL_LEDGER_REL_PATH, "canonical"),
    ):
        path = state_dir / rel_path
        try:
            ledger = json.loads(path.read_text())
            history_diff.validate_ledger(ledger, label=str(path))
        except (OSError, ValueError, history_diff.LedgerError):
            continue
        return ledger, label
    return None, None


def format_current_provenance(ledger: dict, label: str) -> str:
    if label == "partial" and ledger.get("mode") != "complete":
        envelope = ledger.get("coverage_envelope") or {}
        measured = envelope.get("measured_top_level_roots")
        reachable = envelope.get("reachable_top_level_roots")
        if isinstance(measured, int) and isinstance(reachable, int):
            return f"partial: {measured}/{reachable} roots measured"
        return "partial"
    return "complete"


def main(argv) -> int:
    parser = argparse.ArgumentParser(prog="disk-magician growth-top10")
    parser.add_argument("--days", type=int, default=14)
    parser.add_argument("--limit", type=int, default=10)
    parser.add_argument("--state-dir", default=None)
    args = parser.parse_args(argv)

    if args.days <= 0:
        parser.error("--days must be positive")
    if args.limit <= 0:
        parser.error("--limit must be positive")

    state_dir = pathlib.Path(args.state_dir) if args.state_dir else pathlib.Path(resolve_state_repo_path.resolve())
    if not (state_dir / ".git").is_dir():
        print(f"growth-top10: no state repo at {state_dir} (run: state init)", file=sys.stderr)
        return 1

    try:
        floor_ref, floor = history_diff.select_floor_ref(state_dir, args.days)
    except history_diff.LedgerError as exc:
        print(
            f"growth-top10: {exc} — see bead disk_magician-4y6 "
            "(root-privileged full-attribution scanner install blocked)",
            file=sys.stderr,
        )
        return 2

    current, current_label = load_current(state_dir)
    if current is None:
        print(
            "growth-top10: no valid ledger snapshot found "
            f"at {state_dir / PARTIAL_LEDGER_REL_PATH} or {state_dir / CANONICAL_LEDGER_REL_PATH} "
            "— run: ./disk_magician.sh frontier",
            file=sys.stderr,
        )
        return 1

    deltas, residual_delta = history_diff.compute_deltas(floor, current)
    positive = [item for item in deltas if item[1] > 0][: args.limit]

    print(
        f"floor ({args.days}d): {floor['disk_used_kb'] / GIB_KB:.2f} GiB used "
        f"at {floor.get('captured_at', 'unknown')} ({floor_ref})"
    )
    print(
        f"current: {current['disk_used_kb'] / GIB_KB:.2f} GiB used "
        f"at {current.get('captured_at', 'unknown')} ({format_current_provenance(current, current_label)})"
    )
    gap_kb = current["disk_used_kb"] - floor["disk_used_kb"]
    print(f"gap: {history_diff.format_kb(gap_kb)}")
    print()
    print(f"Top {args.limit} growing paths since floor:")
    for path, delta_kb in positive:
        print(f"{history_diff.format_kb(delta_kb)}  {path}")
    print(f"residual delta: {history_diff.format_kb(residual_delta)}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
```
(Skeleton is complete and executable as written; the executor should paste
it verbatim and only adjust if a test in 2.3 reveals a real discrepancy —
e.g. confirm `history_diff.LEDGER_REL_PATH` is exactly
`"ledger/topdown-5g.json"` as read in design §0, and confirm
`select_floor_ref`'s returned `floor` dict includes a `captured_at` key —
both already verified true by reading `history_diff.py` and
`render_topdown_ledger.py` during design.)

2.2. `disk_magician.sh`: add usage line after the existing `history diff
--days N` line:
```
  growth-top10  Top-10 growing paths vs the N-day floor (default 14), no du, <10s.
```
and a dispatch case (place near the `history)` case for readability):
```bash
  growth_top10|growth-top10)
    python3 "$SCRIPT_DIR/scripts/growth_top10.py" "$@"
    ;;
```

**Tests:**

2.3. New `tests/test_growth_top10.py` (unittest, mirror
`tests/test_history_diff.py`'s fixture style — a temp dir git-init'd as the
state repo, committed ledger snapshots via `git commit`). Cases:
- `test_happy_path_prints_floor_current_gap_and_top10`: seed 3 commits to
  `ledger/topdown-5g.json` over the window (all full-attribution, using the
  same fixture-building helper `test_history_diff_dispatch.sh`/
  `test_history_diff.py` already use — reuse it, don't reinvent), lowest one
  is the floor; write a `ledger/topdown-5g.partial.json` directly to the
  working tree (uncommitted — proves it's read from disk, not git) with one
  path showing a large positive delta and one showing a negative delta.
  Run `growth_top10.main(["--state-dir", str(state_dir)])` (call the
  function directly, capture stdout via `contextlib.redirect_stdout`, not a
  subprocess, for speed — matches `test_history_diff.py`'s style where it
  tests `main()` in-process). Assert: exit 0; stdout contains `"floor (14d)"`,
  `"gap:"`, the growing path, and does NOT contain the shrinking path
  (positive-only filter proven).
- `test_falls_back_to_canonical_when_partial_absent`: same fixture minus
  the partial.json write; assert current provenance line says `"complete"`
  and reads from the last committed canonical snapshot.
- `test_exit_2_when_no_full_attribution_floor_in_window`: git-init an empty
  state repo (no commits to `ledger/topdown-5g.json` at all, or only
  commits older than `--days`), assert exit code 2 and stderr mentions
  `"disk_magician-4y6"`.
- `test_exit_1_when_no_current_ledger_at_all`: seed a valid floor commit but
  no `ledger/topdown-5g.partial.json` or `topdown-5g.json` in the working
  tree; assert exit 1 and stderr suggests `"./disk_magician.sh frontier"`.
- `test_never_calls_du`: `unittest.mock.patch("subprocess.run")` (or assert
  no import of/call to a `du`-spawning helper) across the happy-path case,
  asserting no invocation's argv contains `"du"` — direct proof of the
  "no du" acceptance criterion at the unit level.

2.4. New `tests/test_growth_top10_dispatch.sh` (mirror
`tests/test_history_diff_dispatch.sh`'s exact structure: fake state dir via
`DISK_MAGICIAN_STATE_REPO`, seed with the same python heredoc fixture
pattern that file already uses). Cases:
- dispatch through `./disk_magician.sh growth-top10` end-to-end, assert
  output contains `"floor ("` and `"Top 10 growing paths"`.
- Wall-clock: capture `start=$(date +%s)` / `end=$(date +%s)` around the
  call, assert `end - start < 10` — the bash-level proof of the "<10s"
  acceptance criterion (unit tests mock too much to prove wall-clock time
  meaningfully; this is the right layer for it).

**Verify Step 2 in isolation:**
```
python3 -m pytest tests/test_growth_top10.py -q
bash tests/test_growth_top10_dispatch.sh
```

## Step 3 — ledger-freshness recognition

**New file:** `scripts/check_ledger_freshness.sh`

3.1. Write per design §6. Skeleton:
```bash
#!/usr/bin/env bash
# check_ledger_freshness.sh — read-only freshness check for
# ledger/topdown-5g.json (canonical, complete-only) and
# ledger/topdown-5g.partial.json (freshest scan, any completeness).
# Bead disk_magician-zyn. Exit 0 = fresh data available (partial or
# complete). Exit 1 = stale or missing. Never modifies anything.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STALE_HOURS=36  # must match render_topdown_ledger.py's STALE_HOURS

usage() {
  cat <<EOF
Usage: $(basename "$0") [-h|--help]
EOF
}
[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 0; }

STATE_DIR="$(python3 "$SCRIPT_DIR/resolve_state_repo_path.py" 2>/dev/null)"
LEDGER_DIR="$STATE_DIR/ledger"

read -r STATUS < <(python3 - "$LEDGER_DIR" <<'PY'
import json, os, sys, datetime

ledger_dir = sys.argv[1]
now = datetime.datetime.now(datetime.timezone.utc)

def load(name):
    path = os.path.join(ledger_dir, name)
    try:
        with open(path) as f:
            data = json.load(f)
    except (OSError, ValueError):
        return None
    captured_at = data.get("captured_at")
    try:
        ts = datetime.datetime.strptime(captured_at, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)
    except (TypeError, ValueError):
        return None
    age_hours = (now - ts).total_seconds() / 3600.0
    return {"captured_at": captured_at, "age_hours": age_hours, "data": data}

partial = load("topdown-5g.partial.json")
complete = load("topdown-5g.json")

result = {"partial": partial, "complete": complete}
print(json.dumps(result))
PY
)

# (bash-side parsing of $STATUS via python3 -c one-liners follows, mirroring
#  disk_magician.sh's own TOPDOWN_JSON extraction idiom — extract exact
#  fields needed with small `python3 -c "import json,sys; ..."` calls rather
#  than a bash JSON parser.)

FRESHEST_KIND=$(python3 -c "
import json, sys
d = json.loads(sys.argv[1])
c, p = d.get('complete'), d.get('partial')
if not c and not p:
    print('none'); sys.exit()
if c and (not p or c['age_hours'] <= p['age_hours']):
    print('complete' if c['age_hours'] <= $STALE_HOURS else 'stale')
else:
    print('partial' if p['age_hours'] <= $STALE_HOURS else 'stale')
" "$STATUS")

case "$FRESHEST_KIND" in
  complete)
    AGE=$(python3 -c "import json,sys; print(f\"{json.loads(sys.argv[1])['complete']['age_hours']:.1f}\")" "$STATUS")
    CAPTURED=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['complete']['captured_at'])" "$STATUS")
    echo "Ledger: fresh (complete, ${AGE}h old) — captured $CAPTURED"
    exit 0
    ;;
  partial)
    AGE=$(python3 -c "import json,sys; print(f\"{json.loads(sys.argv[1])['partial']['age_hours']:.1f}\")" "$STATUS")
    CAPTURED=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['partial']['captured_at'])" "$STATUS")
    ROOTS=$(python3 -c "
import json, sys
d = json.loads(sys.argv[1])['partial']['data'].get('coverage_envelope') or {}
m, r = d.get('measured_top_level_roots'), d.get('reachable_top_level_roots')
print(f'{m}/{r}' if isinstance(m, int) and isinstance(r, int) else 'unknown')
" "$STATUS")
    MODE=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['partial']['data'].get('mode', 'partial'))" "$STATUS")
    echo "Ledger: fresh (partial, ${MODE}, ${AGE}h old, ${ROOTS} roots measured) — captured $CAPTURED"
    exit 0
    ;;
  stale)
    LAST_COMPLETE=$(python3 -c "import json,sys; d=json.loads(sys.argv[1])['complete']; print(d['captured_at'] if d else 'none')" "$STATUS")
    LAST_PARTIAL=$(python3 -c "import json,sys; d=json.loads(sys.argv[1])['partial']; print(d['captured_at'] if d else 'none')" "$STATUS")
    echo "⚠️  Ledger: stale (> ${STALE_HOURS}h old) — last complete: $LAST_COMPLETE, last partial: $LAST_PARTIAL. Run: ./disk_magician.sh frontier"
    exit 1
    ;;
  none|*)
    echo "⚠️  Ledger: no data (neither topdown-5g.json nor topdown-5g.partial.json found at $LEDGER_DIR). Run: ./disk_magician.sh frontier"
    exit 1
    ;;
esac
```
(This shells to `python3` several times for field extraction, matching this
repo's existing idiom in `disk_magician.sh`'s own `TOPDOWN_JSON`/`TOPDOWN_ENABLED`
heredocs rather than a bash JSON parser. If the executor finds this too
chatty, consolidating into ONE python3 heredoc that prints the final
message + exit-code-via-stderr-sentinel is an acceptable equivalent
refactor — the test in 3.3 pins behavior, not implementation shape.)

3.2. `scripts/check_launchd_fleet.sh`: insert immediately before the
existing `if [[ $((missing + not_loaded + invalid)) -gt 0 ]]; then` block:
```bash
if [[ -x "$(dirname "$0")/check_ledger_freshness.sh" ]]; then
  "$(dirname "$0")/check_ledger_freshness.sh" || true
fi
```
Do not change anything below this line — the existing
`missing`/`not_loaded`/`invalid` exit-code logic is untouched (design §2 Q5:
ledger freshness never changes this script's exit code).

3.3. `disk_magician.sh`: add usage line after `check-launchd-fleet`'s line:
```
  ledger-freshness       Check freshness of ledger/topdown-5g(.partial).json (read-only).
```
and dispatch case near `check_launchd_fleet|check-launchd-fleet)`:
```bash
  ledger_freshness|ledger-freshness)
    "$SCRIPT_DIR/scripts/check_ledger_freshness.sh" "$@"
    ;;
```

**Tests — new `tests/test_check_ledger_freshness.sh`** (mirror
`tests/test_check_launchd_fleet.sh`'s fixture style: temp dir, fake
`DISK_MAGICIAN_STATE_REPO` env pointing `resolve_state_repo_path.py` at a
sandboxed `ledger/` dir with hand-written JSON fixtures — no real `$HOME`
touched). Cases:
- fresh partial only (recent `captured_at`, no `topdown-5g.json`) -> exit 0,
  output contains `"fresh (partial"`.
- fresh complete only -> exit 0, output contains `"fresh (complete"`.
- both stale (`captured_at` > 36h ago) -> exit 1, output contains `"stale"`.
- neither file present -> exit 1, output contains `"no data"`.
- both present, partial newer than complete -> freshest-wins logic picks
  partial's message.

3.4. New assertion in `tests/test_check_launchd_fleet.sh`: add a case
where the fleet fixture is fully healthy (existing "all OK" case) AND the
sandboxed ledger dir is deliberately stale/missing; assert
`check_launchd_fleet.sh`'s own exit code is still 0 (proves decoupling from
design §2 Q5 — this is the single most important regression guard for this
step, since accidentally coupling the two exit codes would silently break
every existing caller of `check_launchd_fleet.sh`).

**Verify Step 3 in isolation:**
```
bash tests/test_check_ledger_freshness.sh
bash tests/test_check_launchd_fleet.sh
```

## Step 4 — H: close the visibility gap

**File:** `config.json.template`

4.1. Insert this object into the `monitored_dirs` array (placement:
anywhere is functionally fine since it's consumed as a list; place it
directly after the existing `projects` entry for readability):
```json
    {
      "key": "roadmap",
      "path": "~/roadmap",
      "timeout": 300,
      "retry_timeout": 90
    },
```
Do not add a second `projects` entry — verify (`grep -c '"key": "projects"' config.json.template`
before and after this edit — must read `1` both times).

**File:** `scripts/disk_observer.py`

4.2. Change `DEFAULT_HOT_DIRS` (append, do not reorder existing 12 entries):
```python
DEFAULT_HOT_DIRS = [
    ".codex",
    ".cache",
    ".aside",
    ".ollama",
    ".openclaw",
    ".hermes",
    ".gemini",
    "/private/tmp",
    "/private/var/folders",
    "Library/Application Support/Cursor",
    "Library/Application Support/Aside",
    "Library/Caches",
    "roadmap",
    "projects",
]
```
Immediately after it, add:
```python
# Per-key du timeout override (bead disk_magician-zyn Component H): the
# shallow 8s default (_du_kb's fallback) is too tight for these two large,
# actively-written roots. Only exercised inside build_step_event_record(),
# itself gated behind check_step_event()'s rare >=10 GiB/30min trigger —
# never the steady 30-60s poll loop (verified: collect_hot_dir_sizes is
# called from exactly one call site).
DEFAULT_HOT_DIR_TIMEOUTS_SEC = {
    "roadmap": 90,
    "projects": 90,
}
```

4.3. Change `_du_kb`'s signature and body:
```python
def _du_kb(path: Path, run: Runner, timeout: int = 8) -> Optional[int]:
    result = run(["du", "-sk", str(path)], timeout)
    if result.returncode:
        return None
    fields = result.stdout.split()
    return _int(fields[0]) if fields else None
```
(Only the signature and the `run(...)` call's second argument change; the
rest of the body is unchanged. Both existing call sites in `collect_colima()`
— `_du_kb(root, run)` and `_du_kb(path, run)` — keep working unmodified via
the `timeout: int = 8` default; do not touch `collect_colima()`.)

4.4. Change `collect_hot_dir_sizes`:
```python
def collect_hot_dir_sizes(
    home: Path,
    run: Runner,
    hot_dirs: Sequence[str] = DEFAULT_HOT_DIRS,
    timeouts: Optional[dict] = None,
) -> dict:
    """... (existing docstring unchanged) ..."""
    timeouts = timeouts if timeouts is not None else DEFAULT_HOT_DIR_TIMEOUTS_SEC
    sizes = {}
    for name in hot_dirs:
        if name.startswith("/") or name.startswith("~"):
            path = Path(os.path.expanduser(name)) if name.startswith("~") else Path(name)
        else:
            path = home / name
        sizes[name] = _du_kb(path, run, timeout=timeouts.get(name, 8)) if path.exists() else None
    return sizes
```

4.5. Change `build_step_event_record`'s signature to accept and forward
`timeouts`:
```python
def build_step_event_record(
    now_epoch: int,
    event: dict,
    home: Path,
    run: Runner,
    hot_dirs: Sequence[str] = DEFAULT_HOT_DIRS,
    timeouts: Optional[dict] = None,
) -> dict:
    return {
        "schema_version": 1,
        "tool": "disk_observer_step_event",
        "timestamp": datetime.fromtimestamp(now_epoch, timezone.utc).isoformat().replace("+00:00", "Z"),
        "epoch": now_epoch,
        "delta_kb": event["delta_kb"],
        "direction": event["direction"],
        "window_seconds": event["window_seconds"],
        "hot_dirs_kb": collect_hot_dir_sizes(home, run, hot_dirs, timeouts),
    }
```

**Merge-safety check (design §2 Q9):** before landing, `git log --oneline
-- scripts/disk_observer.py` and check whether lane 6wd's hook has already
merged. If yes, `git diff` this step's patch against the current file state
and confirm no overlapping line ranges before committing; if the hook
touches `collect_hot_dir_sizes()`'s loop body directly, manually reconcile
rather than force-applying this plan's exact diff.

**Tests — `tests/test_disk_observer.py`:**

4.6. Update `test_default_hot_dirs_are_strictly_portable`'s `expected_dirs`
list: append `"roadmap"` and `"projects"` at the end. (The `disallowed`
host-specific-name check already passes for both — `"projects"` does not
start with `"project_"`, `"roadmap"` isn't in the disallowed set — no other
change needed in that test.)

4.7. Add `test_hot_dir_timeout_overrides_for_slow_keys`:
```python
def test_hot_dir_timeout_overrides_for_slow_keys(self):
    observer = load_module()
    calls = []

    def fake_run(argv, timeout=8):
        calls.append((argv[-1], timeout))
        return observer.CommandResult(0, f"100\t{argv[-1]}\n", "", False)

    with tempfile.TemporaryDirectory() as tmp:
        home = Path(tmp) / "user_home"
        home.mkdir()
        (home / "roadmap").mkdir()
        (home / "projects").mkdir()
        (home / ".codex").mkdir()

        observer.collect_hot_dir_sizes(
            home, fake_run, hot_dirs=["roadmap", "projects", ".codex"],
        )

    timeouts_by_target = {target: timeout for target, timeout in calls}
    self.assertEqual(timeouts_by_target[str(home / "roadmap")], 90)
    self.assertEqual(timeouts_by_target[str(home / "projects")], 90)
    self.assertEqual(timeouts_by_target[str(home / ".codex")], 8)
```

4.8. Add `test_build_step_event_record_forwards_timeouts` (small — proves
the passthrough kwarg wiring in 4.5 isn't dead code): call
`build_step_event_record` with a custom `timeouts={"roadmap": 5}` and a
`fake_run` that records timeouts, assert the recorded timeout for a
`roadmap`-containing `hot_dirs` list is `5`, not the module default `90`.

**Verify Step 4 in isolation:**
```
python3 -m pytest tests/test_disk_observer.py -q
python3 -c "import json; d=json.load(open('config.json.template')); \
  keys=[e['key'] for e in d['monitored_dirs']]; \
  assert keys.count('roadmap') == 1, keys; \
  assert keys.count('projects') == 1, keys; \
  print('OK', keys.count('roadmap'), keys.count('projects'))"
```

## Step 5 — CLAUDE.md documentation pointer

5.1. In this repo's `CLAUDE.md`, under "Investigation methodology — always
find the floor, always show the buckets", immediately after numbered item 2
(the "Pull per-directory granularity buckets" step) and before item 3,
insert:
```markdown
   **Fast path:** `./disk_magician.sh growth-top10` automates steps 1–2
   above — floor selection (lowest full-attribution `disk_used_kb` in the
   last 14 days) + per-path deltas vs. the current `ledger/topdown-5g(.partial).json`
   — in <10s with zero `du` calls (bead `disk_magician-zyn`). It exits 2 and
   names the blocker when no full-attribution floor exists in the window
   (currently possible while bead `disk_magician-4y6`'s root-privileged
   scanner remains unresolved) — steps 1–2 above remain the documented
   manual fallback for that case, and the specification `growth-top10` must
   reproduce.
```
Do not delete or reword steps 1–2 themselves — they remain the fallback and
spec, per design §4's final paragraph.

## Step 6 — sync, version, deploy note (do NOT skip, do NOT bump version)

6.1. Run `bash scripts/sync_package_tree.sh --check` first — expect it to
report every file touched in Steps 1–4 (plus the 2 new files) as
out-of-sync. Then run `bash scripts/sync_package_tree.sh` for real, which
copies the canonical root/`scripts/*` files into `src/disk_magician/`
(glob-based — confirmed in design §0.6 that no script change is needed for
the new files to be picked up).

6.2. Do NOT bump `pyproject.toml`'s `version` field — explicit hard
constraint from the bead. This means: after this PR merges, the **deployed
uv-tool copy** (`~/.local/share/uv/tools/disk-magician/...`, which runs the
35-min snapshot job per this repo's CLAUDE.md "Deployment" section) will
**not** pick up F/H's `render_topdown_ledger.py`/`disk_observer.py` changes
until a separate follow-up bumps the version and runs
`uv tool install --force --reinstall <repo path>`. `growth-top10` and
`ledger-freshness`, being invoked via `disk_magician.sh` (a repo-root
script, not part of the uv-tool package per this repo's "two consumers, two
paths" deployment note), are live immediately for anyone running the repo
script directly — but F's partial-ledger writes and H's observer changes
are NOT live in production until that follow-up version bump lands. State
this explicitly in the PR description; do not claim "H is live" without it.

## Step 7 — final verification (run once, after all 4 steps land in this
worktree, before opening the PR)

```
python3 -m pytest tests/test_render_topdown_ledger.py tests/test_history_diff.py tests/test_growth_top10.py tests/test_disk_observer.py -q
bash tests/test_growth_top10_dispatch.sh
bash tests/test_check_ledger_freshness.sh
bash tests/test_check_launchd_fleet.sh
bash tests/test_history_diff_dispatch.sh   # unmodified, regression guard
bash scripts/sync_package_tree.sh --check  # expect clean after step 6.1's real run
./disk_magician.sh growth-top10            # smoke test against this machine's real state repo — expect either a real report or a clearly-worded exit 1/2, not a traceback
./disk_magician.sh ledger-freshness        # smoke test — same bar
./disk_magician.sh check-launchd-fleet     # confirm ledger-freshness line appears, exit code still governed only by fleet health
```

If `./disk_magician.sh growth-top10` exits 2 on this machine (plausible —
this repo's own evidence bundle shows `disk_magician-4y6` currently
blocking new complete snapshots), that is a PASS for this PR: it proves the
fail-closed path works exactly as designed, not a failure to fix before
merging (fixing `disk_magician-4y6` is out of scope, tracked separately).
