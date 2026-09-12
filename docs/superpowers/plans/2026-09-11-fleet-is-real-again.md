# PR1 "The fleet is real again" — Implementation Plan

Bead: `disk_magician-hyr`. Design: `docs/superpowers/specs/2026-09-11-fleet-is-real-again-design.md`.
Read the design doc first — this plan assumes its Assumptions/Recommended
Defaults section as settled and does not re-derive them.

Branch/worktree: this plan is executor-grade for whoever implements it — use
a dedicated worktree per `~/.claude/skills/superpowers-using-git-worktrees/SKILL.md`,
NOT the design-only worktree this doc was written in. Do not commit from a
design-only lane.

## Step 0 — Baseline (no code changes)

1. `cd <impl-worktree> && bash tests/test_check_launchd_fleet.sh` — confirm
   green before touching anything (regression baseline).
2. `bash scripts/sync_package_tree.sh --check` — record current drift count
   (expected non-empty per `tests/test_package_sync.sh`'s own header comment
   — this is normal, not a blocker).
3. `ls -la src/disk_magician/launchd/com.disk-magician.colima-prune.plist
   launchd/com.disk-magician.colima-prune.plist` and diff them — confirms
   the stale-StartCalendarInterval finding from the design doc is still
   live before this PR fixes it (evidence for the PR description).

## Step 1 — Manifest write in `install_launchd_sweepers.sh`

File: `scripts/install_launchd_sweepers.sh`

1. Near line 47 (existing `STATE_DIR` declaration for the install lock),
   add directly below it:
   ```bash
   MANIFEST_FILE="${DISK_MAGICIAN_LAUNCHD_MANIFEST:-$STATE_DIR/launchd_manifest.json}"
   ```
2. Near line 37 (`mkdir -p "$DEST"`), add a sibling line:
   ```bash
   mkdir -p "$HOME/Library/Logs/disk-magician"
   ```
   (This directory is needed by Step 3 below; creating it unconditionally
   here is harmless even before any plist references it.)
3. Add a new function `record_manifest_entry()` immediately above
   `install_plist()` (current line 108), body exactly as specified in the
   design doc's Component B section (shasum + python3 atomic JSON
   read-modify-write via temp file + `os.replace`).
4. Inside `install_plist()`, immediately after the existing
   `echo "installed $label -> $dst"` line (current line 135), add:
   ```bash
   record_manifest_entry "$label" "$dst"
   ```

**Test first (TDD):** write `tests/test_install_launchd_sweepers_manifest.sh`
before making the above edits pass, following the exact scaffold pattern of
`tests/test_install_launchd_sweepers_preflight.sh` (temp `STATE_DIR`,
`LAUNCHAGENTS_DIR`, `MOCK_LAUNCHD_SRC`, `FAKE_BIN` with a stub `launchctl`
that just logs calls and exits 0, invoked via
`DISK_MAGICIAN_STATE_DIR=... DISK_MAGICIAN_LAUNCHAGENTS_DIR=... DISK_MAGICIAN_LAUNCHD_SRC=... PATH="$FAKE_BIN:$PATH" "$TARGET_SCRIPT" <fixture-name>`).
Assertions:
- After install, `$STATE_DIR/launchd_manifest.json` exists and is valid JSON
  (`python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$MANIFEST"`).
- The JSON's `[label]["sha256"]` equals
  `shasum -a 256 "$LAUNCHAGENTS_DIR/${label}.plist" | awk '{print $1}'`
  computed independently in the test.
- `[label]["installed_at"]` matches `^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$`.
- Re-running the installer against the same fixture a second time still
  leaves the manifest valid JSON with exactly one entry for the label (no
  duplicate keys, no corruption) — proves idempotency.
- A second, *different* label installed afterward leaves the first label's
  entry untouched (read-modify-write correctness, not a clobber).

Run: `bash tests/test_install_launchd_sweepers_manifest.sh` — must fail (RED)
before Step 1's edits, pass (GREEN) after.

## Step 2 — Hash-drift check in `check_launchd_fleet.sh`

File: `scripts/check_launchd_fleet.sh`

1. Near line 23 (`PLIST_DIR=...`), add:
   ```bash
   STATE_DIR="${DISK_MAGICIAN_STATE_DIR:-$HOME/.disk_magician_state}"
   MANIFEST_FILE="${DISK_MAGICIAN_LAUNCHD_MANIFEST:-$STATE_DIR/launchd_manifest.json}"
   ```
2. Near line 63-66 (counter declarations `missing=0 not_loaded=0 invalid=0 ok=0`),
   add `drift=0`.
3. Before the `for label in ...` loop (after line 71's `LAUNCHCTL_LIST=...`
   capture), add a one-time notice when the manifest is entirely absent:
   ```bash
   if [[ ! -f "$MANIFEST_FILE" ]]; then
     echo "  (no launchd_manifest.json yet — hash-drift check skipped; run install_launchd_sweepers.sh to populate one)"
   fi
   ```
4. Inside the loop, insert the hash-drift block from the design doc's
   Component B section between the existing "not loaded" check (ends at
   current line 108, `continue`) and `ok=$(( ok + 1 ))` (current line 109).
5. Update the final health-gate condition (current line 115,
   `if [[ $((missing + not_loaded + invalid)) -gt 0 ]]`) to include `+ drift`.
6. Update the summary line (current line 113,
   `echo "  Fleet: $ok/$total loaded and valid."`) — no change needed
   (drift count is reported via its own per-label lines plus the gate), but
   add one more line right after it when `drift -gt 0`:
   ```bash
   [[ $drift -gt 0 ]] && echo "  ⚠️  $drift plist(s) hash-drifted from their recorded install-time manifest."
   ```
7. Add `com.disk-magician.disk-usage-alert` to the `KNOWN_LABELS` array
   (alphabetically among the `com.disk-magician.*` entries, i.e. right
   after `com.disk-magician.cursor-logs-watchdog`) — this label doesn't
   exist yet; Step 5 creates its plist. Sequencing note: land Step 2's
   `KNOWN_LABELS` addition and Step 5's new plist in the same commit/PR (not
   split) so `check_launchd_fleet.sh` never reports a phantom `MISSING
   PLIST` for a label with no corresponding template yet.

**Test first (TDD):** extend `tests/test_check_launchd_fleet.sh` (do not
replace — it's the incident regression test for the 2026-09-06 class of
bug, keep every existing assertion). Add, after the existing fixture setup
(after line 65, before the `launchctl` stub):
- A `DISK_MAGICIAN_STATE_DIR="$TMP_DIR/state"` env var threaded into the
  script invocation (extend the existing `OUTPUT=$(...)` invocation line 80
  to also export it).
- Write `$TMP_DIR/state/launchd_manifest.json` with three entries:
  1. `com.disk-magician.sweeper-health` → sha256 of the fixture file exactly
     as written (matches → no drift line, no effect on OK classification).
  2. `com.disk-magician.colima-prune` → a deliberately wrong sha256
     (`"0000...0000"`) → expect `HASH-DRIFT` line for it in output (in
     addition to its pre-existing `NOT LOADED` line — the two are
     independent findings for the same label, both should appear).
  3. No entry at all for `com.jleechanorg.disk-magician` (the corrupt-array
     fixture) → since it already fails structural validation first
     (`continue`s before reaching the hash check), assert it does NOT also
     print `HASH-UNKNOWN` (structural-invalid short-circuits hash-drift,
     don't double-report).
- New assertion: a *fourth* fixture plist,
  `com.disk-magician.fsevents-projects.plist` (or reuse `sweeper-health`'s
  sibling pattern), valid + loaded, with NO manifest entry at all →
  expect `HASH-UNKNOWN` line, and expect exit code logic: build a
  second, separate invocation in the same test file where the *only*
  unhealthy signal is one `HASH-UNKNOWN` entry (all else OK) and assert
  exit code 0 (proves `HASH-UNKNOWN` alone never flips the gate — this is
  the fail-closed-to-informational contract from the design doc, and it
  needs its own minimal fixture set, not reuse of the drift-cases fixture
  set which is deliberately already unhealthy for other reasons).
- New assertion: a manifest-absent-entirely run (skip writing
  `launchd_manifest.json` at all, point `DISK_MAGICIAN_STATE_DIR` at an
  empty temp dir) → expect the "no launchd_manifest.json yet" notice line
  and zero `HASH-DRIFT`/`HASH-UNKNOWN` lines anywhere in output.

Run: `bash tests/test_check_launchd_fleet.sh` — new assertions RED before
Step 2's edits, GREEN after; all pre-existing assertions must remain GREEN
throughout (this is the regression test for a real production incident —
treat any existing assertion going red as a stop-the-line signal).

## Step 3 — Rename + relocate the 5 weekly plist templates

Files (git `mv`, preserving history):
```
git mv launchd/com.disk-magician.colima-prune.plist       launchd/com.disk-magician.colima-prune.plist.template
git mv launchd/com.disk-magician.hermes-vacuum.plist       launchd/com.disk-magician.hermes-vacuum.plist.template
git mv launchd/com.disk-magician.playwright-dedup.plist    launchd/com.disk-magician.playwright-dedup.plist.template
git mv launchd/com.disk-magician.worktree-venvs.plist      launchd/com.disk-magician.worktree-venvs.plist.template
git mv launchd/com.disk-magician.sweeper-health.plist      launchd/com.disk-magician.sweeper-health.plist.template
```
Also delete the now-orphaned stale packaged copies at
`src/disk_magician/launchd/com.disk-magician.{colima-prune,hermes-vacuum,playwright-dedup,worktree-venvs,sweeper-health}.plist`
— do NOT hand-edit them; `scripts/sync_package_tree.sh` (run in Step 7) will
recreate them correctly at the new `.plist.template` path once the
`PATTERNS` glob (`launchd/*.plist.template`, already present, unchanged)
picks up the renamed files and `remove_orphans()` removes the old
non-template stale copies automatically. Do not run `sync_package_tree.sh`
until Step 6's edits are also in the renamed files (avoid syncing an
intermediate half-edited state), so do this rename in this step but defer
running the sync script to Step 7.

In each of the 5 renamed files, change:
```xml
<key>StandardOutPath</key>
<string>/tmp/disk-magician-<name>.log</string>
<key>StandardErrorPath</key>
<string>/tmp/disk-magician-<name>.log</string>
```
to:
```xml
<key>StandardOutPath</key>
<string>@HOME@/Library/Logs/disk-magician/<name>.log</string>
<key>StandardErrorPath</key>
<string>@HOME@/Library/Logs/disk-magician/<name>.log</string>
```
where `<name>` is `colima-prune`, `hermes-vacuum`, `playwright-dedup`,
`worktree-venvs`, `sweeper-health` respectively (exact log basenames
unchanged, only the directory moves). Also update each file's existing
"Do not commit a fully-resolved path" comment block to mention the log
now lives under `~/Library/Logs/disk-magician/` (one-line addition, mirror
the phrasing already present in
`com.jleechanorg.disk-magician-frontier-nightly.plist.template`).

Update the two comment-only references:
- `scripts/vacuum_hermes_state.sh:26` — `com.disk-magician.hermes-vacuum.plist` → `com.disk-magician.hermes-vacuum.plist.template`
- `scripts/vacuum_hermes_state.sh:31` — same rename

No test is needed purely for the rename (filename doesn't affect installed
behavior, `install_launchd_sweepers.sh`'s glob already matches both
suffixes — verified in the design doc's Assumptions section), but Step 8's
manual verification recipe includes reinstalling and confirming
`/tmp/disk-magician-{colima-prune,hermes-vacuum,playwright-dedup,worktree-venvs,sweeper-health}.log`
no longer get new writes.

## Step 4 — Redundant fleet check from the drilldown job

File: `scripts/residual_drilldown.sh`

After the existing argument-parsing loop and the existing `mkdir -p "$STATE_DIR"`
line (locate via `grep -n 'mkdir -p "\$STATE_DIR"' scripts/residual_drilldown.sh`
— confirm exact line number before editing, do not assume it matches this
plan's earlier grep output verbatim since line numbers shift), add:
```bash
# Redundant fleet-health check (disk_magician-hyr, component C): sweeper-health
# is the only watchdog and cannot see its own death. Run on this independent
# 4h cadence too. Non-fatal: a degraded fleet must not block drilldown's own
# residual logic, and must not couple the two jobs' failure/restart behavior.
"$SCRIPT_DIR/check_launchd_fleet.sh" || true
```

**Test:** new file `tests/test_residual_drilldown_fleet_check.sh`, pattern:
```bash
TMP_DIR=$(mktemp -d -t drilldown_fleet_check_test.XXXXXX)
trap 'rm -rf "$TMP_DIR"' EXIT
FAKE_SCRIPT_DIR="$TMP_DIR/scripts"
mkdir -p "$FAKE_SCRIPT_DIR"
cp "$REPO_ROOT/scripts/residual_drilldown.sh" "$FAKE_SCRIPT_DIR/"
cat > "$FAKE_SCRIPT_DIR/check_launchd_fleet.sh" <<'EOF'
#!/usr/bin/env bash
echo "  Fleet: 3/16 loaded and valid. STUB-MARKER-UNHEALTHY"
exit 1
EOF
chmod +x "$FAKE_SCRIPT_DIR/check_launchd_fleet.sh" "$FAKE_SCRIPT_DIR/residual_drilldown.sh"
OUTPUT=$(bash "$FAKE_SCRIPT_DIR/residual_drilldown.sh" --dry-run \
  --snapshot-file "$TMP_DIR/nonexistent-snapshot.json" 2>&1) && RC=0 || RC=$?
grep -qF "STUB-MARKER-UNHEALTHY" <<<"$OUTPUT"   # fleet-check output appears
[[ "$RC" -ne 1 || true ]]  # drilldown's own exit code is NOT forced to the stub's 1
                            # (assert drilldown's real completion marker also present,
                            #  e.g. its own "Usage" or dry-run summary line)
```
Adjust the exact snapshot-missing-path handling to whatever
`residual_drilldown.sh --dry-run` actually does when its snapshot file is
absent (check this behavior directly — likely a clean early-exit with a
message, not a crash — and assert THAT completion marker, not a guessed
one). This test's real assertion is: (a) the stub's marker text appears in
combined stdout+stderr, (b) `residual_drilldown.sh` still runs to its own
normal completion afterward (not aborted by the stub's exit 1).

## Step 5 — New alert LaunchAgent template + `disk_usage_alert.sh` reconciliation

1. Create `launchd/com.disk-magician.disk-usage-alert.plist.template`:
   ```xml
   <?xml version="1.0" encoding="UTF-8"?>
   <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
   <!--
     Hourly disk-usage threshold alert (Slack + SMTP), reconciled from the
     separately-deployed ~/Library/Application Support/user-scope/bin/disk_usage_alert.sh
     copy per roadmap/2026-09-11-disk-recurrence-rootcause-and-automation.md §3.3/§5
     component E. Also serves as the delivery mechanism for
     sweeper_health_check.sh's --sweeper-degraded notifications (invoked
     directly by that script, not by this schedule).

     Schedule:  Hourly (StartInterval=3600), matches the deployed copy's cadence.
     Action:    runs scripts/disk_usage_alert.sh with no args (free-space
                threshold + coverage-streak + step-event checks; unchanged
                repo-specific behavior layered on the reconciled Slack/SMTP core).

     Template uses @HOME@ / @REPO_ROOT@ / @BASH@ placeholders — resolved by
     scripts/install_launchd_sweepers.sh at install time. Do not commit a
     fully-resolved path (see ~/.claude/skills/launchd-plist-template).
   -->
   <plist version="1.0">
   <dict>
     <key>Label</key>
     <string>com.disk-magician.disk-usage-alert</string>
     <key>ProgramArguments</key>
     <array>
       <string>@BASH@</string>
       <string>@REPO_ROOT@/scripts/disk_usage_alert.sh</string>
     </array>
     <key>EnvironmentVariables</key>
     <dict>
       <key>HOME</key>
       <string>@HOME@</string>
     </dict>
     <key>StartInterval</key>
     <integer>3600</integer>
     <key>StandardOutPath</key>
     <string>@HOME@/Library/Logs/disk-magician/disk-usage-alert.log</string>
     <key>StandardErrorPath</key>
     <string>@HOME@/Library/Logs/disk-magician/disk-usage-alert.log</string>
   </dict>
   </plist>
   ```

2. Reconcile `scripts/disk_usage_alert.sh`: read the deployed copy's full
   378 lines again at implementation time (path:
   `"~/Library/Application Support/user-scope/bin/disk_usage_alert.sh"`,
   read-only, never edit that file). Replace the repo copy's threshold/df
   framing (`CHECK_PATH`, `THRESHOLD_GB`, `df_line` parsing) and delivery
   functions (`send_email`, `ensure_slack_mcp_token`,
   `send_slack_to_all_channels`) verbatim from the deployed copy, adapted
   only to source env-var names already used in the repo copy where they
   overlap (e.g. keep `SILENCE_FILE` default as the repo's existing
   `$HOME/.disk_magician_alert.silenced`, not the deployed copy's
   `$HOME/.disk-usage-alert.silenced` — two different filenames would
   silently create two independent silence states; pick ONE, and since the
   repo copy's launchd wiring is what ships in this PR, keep the repo's
   existing filename to avoid breaking anyone who has already silenced via
   the old path). Keep the repo copy's `update_coverage_streak()`,
   `get_recent_step_events()`, `--status` extensions, and the existing
   `--silence`/`--unsilence` handlers, folding them into the reconciled
   `--status` output alongside the deployed copy's own status fields
   (threshold, check path, alert email — the deployed copy doesn't have
   coverage-streak concepts, the repo copy doesn't have Slack/SMTP; the
   merged `--status` shows all of it).
   Add the new mode:
   ```bash
   if [[ "${1:-}" == "--sweeper-degraded" ]]; then
     shift
     degraded_msg="$*"
     subject="[disk-magician] sweeper-health degraded on $(hostname -s 2>/dev/null || hostname)"
     body="$degraded_msg"
     email_failed=1; slack_failed=1
     send_email && email_failed=0
     send_slack_to_all_channels && slack_failed=0
     echo "SWEEPER_ALERT_TRIGGERED email=$([[ $email_failed -eq 0 ]] && echo sent || echo failed) slack=$([[ $slack_failed -eq 0 ]] && echo sent || echo failed)"
     [[ $email_failed -eq 1 && $slack_failed -eq 1 ]] && exit 1
     exit 0
   fi
   ```
   placed after `--dry-run`/`--status`/`--silence` arg handling, before the
   default free-space-threshold codepath, so it short-circuits cleanly.
   `subject`/`body` here are local to this branch (do not reuse the
   free-space branch's `$subject`/`$body` globals if that branch hasn't run
   yet — declare local vars, don't rely on the default path's variables
   existing).

3. `scripts/sweeper_health_check.sh:239-244` — replace the `cmux` block:
   ```bash
   # Operator notification trigger (disk_magician-sweeper-health-auto-repair-dzm,
   # wired to a real egress per disk_magician-hyr component E — cmux is not on
   # launchd's PATH and this alert previously fired zero times in production).
   if [[ "$NOTIFY" == true && ($MISS_COUNT -gt 0 || $WARN_COUNT -gt 0 || $CORRUPT_COUNT -gt 0) ]]; then
     notify_body="Sweeper health degraded: ${MISS_COUNT} silent/corrupt"
     [[ $CORRUPT_COUNT -gt 0 ]] && notify_body="${notify_body} (${CORRUPT_COUNT} corrupt)"
     [[ $WARN_COUNT -gt 0 ]] && notify_body="${notify_body}, ${WARN_COUNT} warnings"
     "$REPO_ROOT/scripts/disk_usage_alert.sh" --sweeper-degraded "$notify_body" >/dev/null 2>&1 || true
   fi
   ```

4. Add `com.disk-magician.disk-usage-alert` to `check_launchd_fleet.sh`'s
   `KNOWN_LABELS` (already scheduled as part of Step 2 — confirm it lands
   in the same commit as this step's new plist file, not separately).

**Test first (TDD):** new file `tests/test_disk_usage_alert_sweeper_mode.sh`.
Pattern (mirroring how the deployed script itself is structured — no real
network/Slack calls):
```bash
TMP_DIR=$(mktemp -d -t disk_usage_alert_sweeper_test.XXXXXX)
trap 'rm -rf "$TMP_DIR"' EXIT
FAKE_BIN="$TMP_DIR/bin"
mkdir -p "$FAKE_BIN"
# Stub curl (send_email path) to always fail (forces the slack path to be
# the one under test, and separately test slack-stub-success / both-fail).
cat > "$FAKE_BIN/curl" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$FAKE_BIN/curl"
# Stub the slack MCP server binary referenced by SLACK_MCP_SERVER_BIN to
# respond to the stdio JSON-RPC handshake with a synthetic success for
# conversations_add_message (mirror the real binary's line-delimited JSON
# contract closely enough for send_slack_to_all_channels's reader loop to
# terminate cleanly) OR, simpler: point SLACK_MCP_SERVER_BIN at a
# nonexistent path and assert send_slack_to_all_channels fails gracefully,
# then separately assert the overall --sweeper-degraded exit code is 1 with
# both delivery paths failing (this is the "test infra, not the real Slack
# API" case worth writing first; a true stdio-mock is a stretch goal, note
# it as a known gap in the test file's header comment if not implemented).
PATH="$FAKE_BIN:$PATH" ALERT_EMAIL="" SLACK_MCP_SERVER_BIN="/nonexistent" \
  bash "$REPO_ROOT/scripts/disk_usage_alert.sh" --sweeper-degraded "unit test message" \
  >"$TMP_DIR/out.log" 2>&1
RC=$?
grep -qF "SWEEPER_ALERT_TRIGGERED" "$TMP_DIR/out.log"
[[ "$RC" -eq 1 ]]   # both delivery paths unavailable -> exit 1
# Also assert the free-space threshold codepath is untouched: run with no args,
# a huge THRESHOLD_GB override, confirm it still prints "OK:" and exits 0,
# proving --sweeper-degraded didn't leak into or replace the default path.
DISK_ALERT_THRESHOLD_GB=999999 bash "$REPO_ROOT/scripts/disk_usage_alert.sh" | grep -q "^OK:"
```
Document in the test file's header comment that full Slack MCP delivery
success is not mocked end-to-end here (would require a working stdio JSON-RPC
stub server) — this test proves the dual-failure exit path and the
free-space-path non-interference; a live Slack send is proven manually in
Step 8's verification recipe, not by this unit test.

## Step 6 — Update `sync_package_tree.sh` consumer expectations (no code change)

No edit needed to `scripts/sync_package_tree.sh` itself — its
`launchd/*.plist.template` glob already covers the 5 renamed files from
Step 3 and the new file from Step 5. This step is a checkpoint, not a code
change: confirm this before Step 7.

## Step 7 — Deploy sync (integration-time, run once at the end)

1. `bash scripts/sync_package_tree.sh` (no `--check`) — syncs all edited
   root files (the 5 renamed+edited launchd templates, the new
   disk-usage-alert template, `install_launchd_sweepers.sh`,
   `check_launchd_fleet.sh`, `residual_drilldown.sh`,
   `sweeper_health_check.sh`, `disk_usage_alert.sh`) into
   `src/disk_magician/`, and removes the now-orphaned stale
   `src/disk_magician/launchd/com.disk-magician.{5 names}.plist` copies
   (the ones proven stale-schedule in Step 0).
2. Bump `pyproject.toml`'s `version = "0.2.99"` → `"0.3.0"` (or next patch
   per repo convention — check `test_check_version_monotonic.py`'s rule
   before picking the exact number; do this ONCE, at the end, per
   `CLAUDE.md`'s "bump the version in pyproject.toml (uv caches wheels by
   version)" rule — not per-commit during Steps 1-5).
3. `uv tool install --force --reinstall .` (from repo root).
4. Verify deployed tree matches: diff a representative changed file, e.g.
   ```bash
   diff scripts/check_launchd_fleet.sh \
     ~/.local/share/uv/tools/disk-magician/lib/python*/site-packages/disk_magician/scripts/check_launchd_fleet.sh
   ```
   (adjust the exact site-packages path glob to whatever `uv tool install`
   actually produces on this machine — confirm via
   `uv tool list -v` or `find ~/.local/share/uv/tools/disk-magician -name check_launchd_fleet.sh`
   rather than assuming the path structure).
5. `bash scripts/sync_package_tree.sh --check` — expect exit 0 for every
   file this PR touched (some pre-existing unrelated drift from other work
   may remain non-zero overall; the acceptance bar is "0 drift among files
   this PR changed," not "repo-wide 0 drift" — confirm which specific files
   are still flagged, if any, and that none of them are files this PR
   edited).

## Step 8 — Full test suite + manual verification

1. Run every test touched or added by this plan, plus the full existing
   suite (CI parity, per `.github/workflows/ci.yml`):
   ```bash
   python3 -m unittest discover -s tests -p 'test_*.py' -v
   for f in tests/test_*.sh; do echo "== $f =="; timeout 300 bash "$f" || echo "FAILED: $f"; done
   ```
   Confirm zero new failures relative to Step 0's baseline.
2. Run the Manual Verification Recipe from the design doc's final section
   verbatim, against the real live fleet on this machine. This is the step
   that proves acceptance criteria 1-4 (manifest+drift, drilldown-run
   check, no `/tmp` StandardOutPath, forced-FAIL Slack message) with real
   evidence, not test-fixture evidence.
3. Re-run `./disk_magician.sh check-launchd-fleet` one final time after all
   reinstalls — expect the full known-label count (17, including the new
   `disk-usage-alert` job) OK, 0 HASH-DRIFT, 0 HASH-UNKNOWN (every label
   now has a fresh manifest entry from the Step 7 real install).

## Acceptance Criteria Cross-Reference (bead `disk_magician-hyr`)

1. Manifest + HASH-DRIFT — Steps 1, 2.
2. `check_launchd_fleet` runs from drilldown, output in drilldown log — Step 4.
3. No plist under the two label prefixes has `StandardOutPath` under `/tmp` — Step 3 (5 renamed) + Step 5 (new alert job never uses `/tmp` in the first place). Note: this criterion is scoped to the 5 weekly sweepers named in the bead body; jobs already on `~/Library/Logs` (frontier-nightly) or using non-`/tmp` paths are unaffected and out of scope for re-verification beyond the existing spot-check in Step 8.2.
4. `sweeper_health_check` notify uses absolute-path egress; forced-FAIL run produces a Slack message — Step 5, verified live in Step 8.2 (real Slack send is a manual-recipe step, not a unit test, per the design doc's test-scope note).
5. `tests/test_check_launchd_fleet.sh` + new hash-drift test pass — Step 2's extended test file (no separate new file; extending, not adding a sibling, per the design's "extend, don't replace" note for this specific regression test).
6. pyproject bump + `uv tool install` + deployed-tree diff = 0 for touched files — Step 7.

## Explicitly Out of Scope (do not do these in this PR)

- Any change to `safety.local.json`, `worktree_recency.sh`, or deletion
  authority of any kind.
- Rebuilding Slack/SMTP delivery from scratch — Step 5 reconciles the
  existing deployed implementation, it does not reimplement it.
- Bumping `pyproject.toml` more than once, or mid-implementation — Step 7
  only, at the end.
- Fixing `frontier-root`'s broken path (bead `disk_magician-4y6`) — unrelated.
- Components F/G/H/I/J from the root-cause doc's §5 table — separate PRs
  (PR2, PR3) per that doc's sequencing; do not fold them in here even if a
  file happens to overlap.
