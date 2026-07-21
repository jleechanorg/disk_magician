# jleechan-mrtr — Real snapshot in state-repo E2E — Design

## Exit criteria (binary, externally anchored)
- `tests/test_state_repo_e2e.sh` PASSES with **zero** calls to `write_fixture_ledger()`
  (the two current calls at lines ~134 and ~158 are removed).
- Criteria 2 and 3 of the E2E derive `ledger/topdown-5g.json` from the **real**
  disk_magician scanner/render path run against the controlled sandbox fixture at
  `$FIXTURE_FILE` (the sparse 6 GiB file) — not from fabricated JSON.
- The grown-state assertion still holds: the ledger's first bucket line is the
  `$FIXTURE_FILE` entry rendered as `+6.00 GiB` (existing line ~164 assertion).
- No production script behavior changes; the diff is confined to the test file
  (plus any minimal, additive test-only helper). `bash tests/test_state_repo_e2e.sh`
  exits 0 on macOS.

## Goal
Replace the fabricated `write_fixture_ledger()` shortcut (added because PR-2 hadn't
merged) with a real invocation of the merged snapshot→ledger write-path, so the E2E
exercises the real scanner end-to-end.

## Architecture / key facts (from repo exploration)
- The real ledger `ledger/topdown-5g.json` is written by
  `scripts/render_topdown_ledger.py` (`out_dir/topdown-5g.json`), which renders from
  the **frontier scanner's report**. Confirm whether `disk-magician snapshot`
  (`scripts/disk_snapshot.sh`) invokes this render step, or whether the frontier
  scan + `render_topdown_ledger.py` must be driven directly for a bounded sandbox.
- `disk_snapshot.sh` hardcodes `STATE_DIR="$HOME/.disk_magician_state"` and scans
  `MONITORED_PATHS`. The E2E must point the scan at the sandbox fixture and write
  the ledger under the test's `$STATE_DIR`, without touching the real host state dir.
  Prefer an env override (e.g. an existing `DISK_*`/`XDG_STATE_HOME` knob) over new
  production flags; add a minimal additive test-only override ONLY if none exists.
- Existing test infra to reuse: `$FIXTURE_FILE` (sparse 6 GiB img, line ~145-148),
  `$STATE_DIR`, `$FAKE_HOST`, the `history diff --validate` invocation.

## Error handling
- If the real scanner cannot be bounded to the sandbox without a production change,
  STOP and document the blocker in the PR body rather than editing production scan
  roots (root-cause-first: a test must not force a production behavior change).

## Out of scope
- Any change to `render_topdown_ledger.py`, `disk_snapshot.sh`, or the frontier
  scanner semantics. Any new production CLI flag. Non-mrtr tests.
