# PR1 "The fleet is real again" — Design

Bead: `disk_magician-hyr`. Source: `roadmap/2026-09-11-disk-recurrence-rootcause-and-automation.md`
§5 components B–E (component A, corruption forensics, already landed on
2026-09-11 — `cleanup_apfs_snapshots.sh:69-70` fixed, quarantine done,
`check_launchd_fleet.sh`'s corruption hint already ships).

## Goal

Close the four remaining ways this repo's own launchd fleet can silently rot
without an operator noticing, without adding any new deletion authority and
without loosening any existing safety gate:

1. A plist that is loaded and lints clean can still differ from what the
   installer actually wrote (a rewrite that stays valid XML, e.g. a partial
   `plutil -extract` variant that doesn't hit the `[`/`{` signature, or a
   manual edit) — nothing today detects that.
2. `sweeper-health` is the only watchdog and cannot see its own death; there
   is no second, independently-scheduled check.
3. Five weekly-cadence sweepers log to `/tmp/disk-magician-*.log`, and
   macOS's own `tmp_cleaner` reaps idle `/tmp` files >3 days — a 7-day
   cadence log is structurally guaranteed to be missing on >50% of health
   checks, producing the daily false-MISS auto-repair flap documented in
   §3.5.
4. `sweeper_health_check.sh`'s notify path gates on `command -v cmux`, which
   is absent from launchd's PATH — the alarm has fired zero times in
   production despite real degraded states, and the working, already-deployed
   Slack+SMTP alert script (`~/Library/Application Support/user-scope/bin/disk_usage_alert.sh`)
   is not reconciled into this repo at all.

## Assumptions and Recommended Defaults

For every fork below: question → recommended default → why (repo evidence).

- **Q: Where does the sha256 manifest live?**
  Default: `${DISK_MAGICIAN_STATE_DIR:-$HOME/.disk_magician_state}/launchd_manifest.json`,
  one JSON object keyed by label. Rationale: `~/.disk_magician_state/` is
  already the canonical home for every other piece of fleet/measurement
  state (`discover_last.json`, `frontier_last.json`, `coverage_streak.json`,
  `step_events.jsonl` — all read via `scripts/check_launchd_fleet.sh`'s
  sibling scripts with the same `DISK_MAGICIAN_STATE_DIR` override
  convention already used in `disk_usage_alert.sh` and
  `residual_drilldown.sh`). Not `~/Library/LaunchAgents/` itself — that
  directory's contents are exactly what's being verified, so the manifest
  must live outside the set it audits.

- **Q: What triggers a manifest write?**
  Default: every successful `install_plist()` call (i.e. every plist that
  passes the existing `plutil -lint` + top-level-`Label` preflight and is
  actually bootstrapped), record `{sha256, installed_at (UTC), src}`.
  Rationale: this is the exact point the installer already has a "this plist
  is known-good and was just written to launchd" guarantee — computing the
  hash anywhere else risks recording a hash for a plist that never actually
  got bootstrapped.

- **Q: Missing-manifest / missing-entry semantics — hard fail or informational?**
  Default: **fail closed to "cannot verify," never to "unhealthy."** If
  `launchd_manifest.json` doesn't exist at all (fresh install, older
  checkout before this lands), `check_launchd_fleet.sh` skips hash-drift
  entirely and says so once at the top of its output — it does NOT count
  every label as drifted. If the manifest exists but a specific label has no
  entry (installed via a path that predates this feature, or manually
  copied), print `HASH-UNKNOWN <label> (no manifest record — run
  install_launchd_sweepers.sh to record one)` as informational, not counted
  in the failure tally. Only a manifest entry that exists AND disagrees with
  the live file's sha256 counts as `HASH-DRIFT` and flips the exit code.
  Rationale: `CLAUDE.md`'s worktree-recency rule already establishes this
  repo's fail-closed convention ("cannot measure it → treat as active →
  preserve"); the mirror image here is "cannot measure hash → treat as
  unverified, not as broken" — a rollout day must not turn 16/16 green into
  16/16 red.

- **Q: Does the manifest replace or sit alongside the existing
  lint+Label structural check?**
  Default: alongside, as a third independent check, same as `check_launchd_fleet.sh`
  already runs two independent checks (loaded via `launchctl list`, valid via
  `plutil -lint` + Label). Hash-drift is orthogonal: a plist can be
  structurally valid, currently loaded by launchd's in-memory cache, and
  still differ on disk from what launchd actually bootstrapped (the state
  the 2026-09-11 postmortem calls "surviving only in launchd's in-memory
  cache" — §5 PR1 rationale). This is precisely the case hash-drift is for:
  it tells the operator disk state has moved out from under the running job
  even though nothing *looks* broken yet.

- **Q: Where does the redundant fleet check run — drilldown (4h) job, or a
  brand-new job?**
  Default: **drilldown job**, per the bead text and `roadmap/...#5` row C.
  Not a new job: this repo's own root-cause doc (§3.5, §5 "Deliberately NOT
  done") explicitly rejects adding new cadence surfaces where an existing one
  already fires reliably; `com.jleechanorg.disk-magician-drilldown` runs
  every 14400s (4h) and already logs to `/tmp/disk-magician-drilldown.log`
  (itself in scope for component D below). Not `pressure-sweep` (30 min,
  gated on free<40G — wrong trigger, this must run unconditionally) and not
  `frontier-nightly` (24h — too slow to be "redundant" against a watchdog
  that's supposed to catch same-day flaps).

- **Q: Does the fleet check's non-zero exit block the drilldown job's own
  logic?**
  Default: **no** — call it with `|| true` near the top of
  `residual_drilldown.sh`, after arg parsing, before its own residual logic,
  so its PASS/FAIL text lands in the shared log (`StandardOutPath` is the
  same file) but never prevents drilldown from doing its own job. Rationale:
  acceptance criterion 2 only requires the check to run and its output to
  *appear* in the drilldown log — coupling exit codes would mean a launchd
  restart storm on the drilldown job every time the fleet is degraded,
  which is a second, unrelated failure class the plan (§5 "Deliberately NOT
  done") already warns against introducing.

- **Q: Which 5 jobs get `StandardOutPath`/`StandardErrorPath` moved off
  `/tmp`, and to where?**
  Default: the 5 weekly-cadence jobs identified in §3.5 — `colima-prune`,
  `hermes-vacuum`, `playwright-dedup`, `worktree-venvs`, `sweeper-health` —
  move to `@HOME@/Library/Logs/disk-magician/<label-suffix>.log`.
  Rationale: `com.jleechanorg.disk-magician-frontier-nightly.plist.template`
  already uses `@HOME@/Library/Logs/disk-magician-frontier.log` as
  precedent inside this exact repo — `~/Library/Logs` is never touched by
  `tmp_cleaner`'s 3-day idle purge (a LaunchDaemon scoped to `/tmp` and
  `/var/folders`, confirmed via embedded strings in §3.5), and it's a
  per-user, backup-friendly location distinct from `/tmp`.

- **Q: A material finding surfaced during design read: these 5 files are
  named `com.disk-magician.<name>.plist` (no `.template` suffix) despite
  being `@REPO_ROOT@`/`@HOME@`/`@BASH@` templates, identical in every
  respect to the other 11 files that DO carry `.plist.template`. Fix or
  leave?**
  Default: **fix — rename all 5 to add the `.plist.template` suffix as part
  of this PR.** This is not cosmetic: `scripts/sync_package_tree.sh`'s
  `PATTERNS` array only globs `launchd/*.plist.template` (not
  `launchd/*.plist`), so these 5 files are **silently excluded from the
  repo-root → packaged-copy sync that ships production deploys**. Verified
  live: `src/disk_magician/launchd/com.disk-magician.colima-prune.plist`
  today still contains the **pre-2026-07-22-fix `StartCalendarInterval`
  Sunday-03:45 schedule** — the exact schedule root-cause doc §3.5 and the
  file's own repo-root comment block say "never fired in 16+ days" — while
  the repo-root copy has carried the fixed `StartInterval=604800` for weeks.
  This is a live, already-existing instance of the stale-deploy incident
  class `CLAUDE.md`'s Deployment section warns about (2026-07-11: "v2 code
  was committed for hours while production ran v1"), caught by this design
  pass, not previously tracked. Renaming is safe: `install_launchd_sweepers.sh`'s
  bulk-install glob already matches both `com.disk-magician.*.plist` and
  `com.disk-magician.*.plist.template` in the same loop (`install_plist()`
  reads the label from file content, not the filename), and
  `check_launchd_fleet.sh` matches installed **destination** plists in
  `~/Library/LaunchAgents/${label}.plist` — always the resolved `.plist`
  suffix regardless of source-template suffix — so neither consumer cares
  about the source filename. Two comment references
  (`scripts/vacuum_hermes_state.sh:26,31`) get their filename mentions
  updated to match, no behavior change.

- **Q: How does `sweeper_health_check.sh` reach the alert egress without
  rebuilding it?**
  Default: reconcile the deployed
  `~/Library/Application Support/user-scope/bin/disk_usage_alert.sh` into
  this repo as `scripts/disk_usage_alert.sh` (the repo already has a
  `scripts/disk_usage_alert.sh`, but it is the older, weaker copy per
  §3.3 — "a *separately deployed*, better copy... already has working
  Slack + SMTP egress"). Replace the repo copy's body with the deployed
  version's logic (df/threshold framing, Slack MCP + SMTP dual delivery,
  `--silence`/`--status`), preserving the repo copy's existing
  coverage-streak and step-event-attribution additions (`update_coverage_streak`,
  `get_recent_step_events`) as repo-specific extensions layered on top, since
  those integrate with `disk_observer.py`'s step-event JSONL that the
  deployed copy has no knowledge of and root-cause doc §5 does not ask to
  drop. Then in `sweeper_health_check.sh:239-244`, replace the
  `command -v cmux` gate with a direct, absolute-path call:
  `"$REPO_ROOT/scripts/disk_usage_alert.sh"` invoked with a
  degraded-state message (see Design, Component E). Add one new LaunchAgent
  template, `com.disk-magician.disk-usage-alert.plist.template`, on an
  hourly `StartInterval` (matches the deployed copy's existing "fires
  hourly" cadence per §3.3), since today `disk_usage_alert.sh` has **zero**
  launchd/cron job referencing it in this repo at all — it currently only
  runs when a human invokes it by hand.

- **Q: Does wiring sweeper-health's notify call into `disk_usage_alert.sh`
  change `disk_usage_alert.sh`'s own contract (free-space threshold check)?**
  Default: **no** — add a second, explicit invocation mode:
  `disk_usage_alert.sh --sweeper-degraded "<message>"` that unconditionally
  sends the given message through the same Slack+SMTP delivery functions,
  bypassing the free-space threshold math entirely (sweeper degradation is
  its own alert class, not a disk-usage-threshold event). This keeps the
  free-space codepath (already covered implicitly by its existing
  `--dry-run`/`--status` behavior) completely unchanged and just exposes the
  delivery machinery (`send_email`, `send_slack_to_all_channels`) as a
  reusable primitive.

## Options Considered (per component)

**Manifest + hash-drift (B):**
1. Store the manifest as a flat file of `label sha256` lines (grep-able,
   no `python3`/`jq` dependency). Rejected: every other piece of fleet state
   in this repo (`discover_last.json`, `coverage_streak.json`,
   `frontier_last.json`) is JSON, and the existing `disk_usage_alert.sh`
   already shells out to `python3` for JSON state (`update_coverage_streak`)
   — introducing a second ad hoc text format is unnecessary inconsistency.
2. Recompute the manifest by re-hashing `launchd/*.plist(.template)` +
   substituting placeholders live inside `check_launchd_fleet.sh`, with no
   separate manifest file. Rejected: this makes `check_launchd_fleet.sh`
   depend on `REPO_ROOT` resolution and template substitution logic
   duplicated from the installer — exactly the kind of duplicated judgment
   this repo's "root-cause-first" / centralization norms warn against, and
   it can't detect drift introduced by manual edits to the *destination*
   plist (the actual incident class), only drift between source and
   destination.
3. **Selected: installer writes a small JSON manifest keyed by label,
   `check_launchd_fleet.sh` reads it read-only.** Matches existing JSON-state
   conventions, keeps hash computation at the one place that has a
   known-good preflight, and directly detects "destination plist diverged
   from what was actually bootstrapped" — the real incident class.

**Redundant check (C):**
1. New standalone launchd job dedicated only to running
   `check_launchd_fleet.sh`. Rejected: root-cause doc explicitly cuts new
   cadence surfaces (§5 "Deliberately NOT done") and a second watchdog is
   itself another job that can flap.
2. **Selected: call from the existing drilldown job (4h cadence),
   non-fatal (`|| true`).** Reuses a cadence that's already proven live
   (frontier scans, drilldown, pressure-sweep all show in-window `df`
   evidence in the evidence bundle §A/§B), zero new plist to maintain.

**Log paths (D):**
1. Redirect to `/dev/null` and rely solely on the manifest/hash-drift and
   `launchctl print`'s own exit-code history. Rejected: `sweeper_health_check.sh`'s
   entire MISS/WARN/OK model depends on reading the log's mtime and tail —
   removing the log removes the primary detection signal it exists to
   provide, not just the flapping bug.
2. **Selected: move to `~/Library/Logs/disk-magician/`.** Matches existing
   precedent in this exact template family (frontier-nightly), never
   touched by `tmp_cleaner`.

**Alert egress (E):**
1. Rebuild Slack/SMTP delivery from scratch in the repo's own
   `disk_usage_alert.sh`. Rejected: root-cause doc explicitly says "No
   Slack/SMTP rebuild — the working implementation already exists" (§5
   "Deliberately NOT done") — a working, already-deployed 378-line
   implementation exists; duplicating it is waste and risks a second,
   subtly different bug surface.
2. **Selected: reconcile the deployed copy into the repo, preserving the
   repo's own step-event/coverage-streak additions as layered extensions,
   and call it from `sweeper_health_check.sh` via absolute path.**

## Design

### Component B — sha256 manifest + hash-drift check

`install_launchd_sweepers.sh`'s `install_plist()` (currently
`scripts/install_launchd_sweepers.sh:108-136`) gains, immediately after the
existing `launchctl bootstrap` call succeeds:

```bash
record_manifest_entry() {
  local label="$1" dst="$2"
  local sha
  sha="$(shasum -a 256 "$dst" | awk '{print $1}')"
  mkdir -p "$STATE_DIR"
  python3 - "$MANIFEST_FILE" "$label" "$sha" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$dst" <<'PY'
import json, sys, os
manifest_file, label, sha, ts, dst = sys.argv[1:6]
try:
    data = json.load(open(manifest_file))
except Exception:
    data = {}
data[label] = {"sha256": sha, "installed_at": ts, "path": dst}
tmp = manifest_file + ".tmp"
with open(tmp, "w") as f:
    json.dump(data, f, indent=2, sort_keys=True)
os.replace(tmp, manifest_file)
PY
}
```
where `MANIFEST_FILE="${DISK_MAGICIAN_LAUNCHD_MANIFEST:-$STATE_DIR/launchd_manifest.json}"`
and `STATE_DIR="${DISK_MAGICIAN_STATE_DIR:-$HOME/.disk_magician_state}"` are
declared near the top of the script alongside the existing `STATE_DIR`
lock-dir declaration (line 47) — reuse that variable, don't redeclare.
`install_plist()` calls `record_manifest_entry "$label" "$dst"` right after
the existing `echo "installed $label -> $dst"` line. Atomic write via
temp-file + `os.replace` avoids a torn manifest read if `check_launchd_fleet.sh`
runs concurrently (it's read-only, but a half-written JSON file would still
break its parse).

`check_launchd_fleet.sh` gains, inside the per-label loop, after the
existing "not loaded" check and before `ok=$(( ok + 1 ))`:

```bash
if [[ -f "$MANIFEST_FILE" ]]; then
  manifest_sha="$(python3 - "$MANIFEST_FILE" "$label" <<'PY'
import json, sys
try:
    data = json.load(open(sys.argv[1]))
except Exception:
    data = {}
print(data.get(sys.argv[2], {}).get("sha256", ""))
PY
)"
  if [[ -n "$manifest_sha" ]]; then
    live_sha="$(shasum -a 256 "$plist" | awk '{print $1}')"
    if [[ "$live_sha" != "$manifest_sha" ]]; then
      echo "  HASH-DRIFT      $label  ($plist differs from the sha256 recorded at install time — re-run install_launchd_sweepers.sh)"
      drift=$(( drift + 1 ))
      continue
    fi
  else
    echo "  HASH-UNKNOWN    $label  (no manifest record — informational only)"
  fi
fi
```
A new `drift=0` counter is declared alongside the existing
`missing/not_loaded/invalid/ok` counters, added into the final unhealthy-sum
and reported in the summary line and repair hint. When `$MANIFEST_FILE`
doesn't exist at all, the loop body above is skipped entirely (the
`[[ -f "$MANIFEST_FILE" ]]` guard) and one line is printed once, before the
loop starts: `"  (no launchd_manifest.json yet — hash-drift check skipped; will populate on next install_launchd_sweepers.sh run)"`.

### Component C — redundant check from the drilldown job

In `scripts/residual_drilldown.sh`, immediately after argument parsing and
`mkdir -p "$STATE_DIR"` (existing, near line ~30), add:

```bash
# Redundant fleet-health check (disk_magician-hyr, component C): sweeper-health
# is the only watchdog and cannot see its own death. Run on this independent
# 4h cadence too. Non-fatal: a degraded fleet must not block drilldown's own
# residual logic, and must not couple the two jobs' failure/restart behavior.
"$SCRIPT_DIR/check_launchd_fleet.sh" || true
```
This is the entire change to `residual_drilldown.sh` — no other line moves.
Its stdout/stderr already share the drilldown plist's `StandardOutPath`
(`/tmp/disk-magician-drilldown.log` today; see Component D below for its own
log-path move), so `check_launchd_fleet.sh`'s PASS/FAIL text appears in that
log on every 4h run, satisfying acceptance criterion 2 without a new plist.

### Component D — sweeper logs off `/tmp`

For each of the 5 templates (renamed with `.plist.template` suffix per the
Assumptions section above): `<key>StandardOutPath</key>` and
`<key>StandardErrorPath</key>` change from
`/tmp/disk-magician-<name>.log` to
`@HOME@/Library/Logs/disk-magician/<name>.log`. `install_plist()` needs one
addition: `mkdir -p "$(dirname "$dst_log")"` is not straightforward from
inside `install_plist()` (it only sees the rendered plist, not a parsed log
path) — simplest correct fix is a one-line unconditional
`mkdir -p "$HOME/Library/Logs/disk-magician"` near the top of
`install_launchd_sweepers.sh` (alongside the existing `mkdir -p "$DEST"` at
line 37), since the directory is a fixed, non-templated path. Also add a
comment at the top of each renamed template updating the existing
"Do not commit a fully-resolved path" note to mention the new log location
(pattern already used verbatim in `com.jleechanorg.disk-magician-frontier-nightly.plist.template`).

`sweeper_health_check.sh`'s `extract_log_path()` needs no change — it reads
`StandardOutPath` from the plist dynamically, so it automatically follows
the new path once the plists are reinstalled. This is precisely why the
acceptance criterion is phrased as "no plist... has StandardOutPath under
/tmp," not "sweeper_health_check.sh hardcodes a new path."

### Component E — wire the real alert channel

1. `scripts/disk_usage_alert.sh`: replace the free-space-threshold body and
   delivery functions with the deployed copy's logic (df framing using
   `total - available` instead of raw `df` used%, `send_email`,
   `ensure_slack_mcp_token`, `send_slack_to_all_channels`, `--silence` /
   `--unsilence` / `--status` / `--dry-run`), keep the repo's own
   `update_coverage_streak()` / `get_recent_step_events()` / streak-escalation
   block layered on top (called from the same place they are today), and add
   a new top-level branch:

```bash
if [[ "${1:-}" == "--sweeper-degraded" ]]; then
  shift
  subject="[disk-magician] sweeper-health degraded on ${HOSTNAME_VALUE}"
  body="$*"
  # (uses the same send_email / send_slack_to_all_channels functions,
  # bypassing the free-space threshold branch entirely)
  ...
  exit $(( email_failed && slack_failed ))
fi
```

2. `sweeper_health_check.sh:239-244` replaces:
```bash
if command -v cmux >/dev/null 2>&1; then
  cmux notify --title "disk-magician" --body "$notify_body" >/dev/null 2>&1 || true
fi
```
with:
```bash
"$REPO_ROOT/scripts/disk_usage_alert.sh" --sweeper-degraded "$notify_body" >/dev/null 2>&1 || true
```
(`REPO_ROOT` is already resolved at the top of the script, line 37 — reused,
not re-derived.) The `|| true` is preserved from the existing code: a failed
*delivery* must never turn a read-only health check into a script that exits
non-zero for a reason unrelated to sweeper health.

3. New template `launchd/com.disk-magician.disk-usage-alert.plist.template`:
`StartInterval=3600` (hourly, matching the deployed copy's observed cadence
per §3.3), `ProgramArguments = [@BASH@, @REPO_ROOT@/scripts/disk_usage_alert.sh]`
(no args — default free-space-threshold mode), `StandardOutPath`/`StandardErrorPath`
at `@HOME@/Library/Logs/disk-magician/disk-usage-alert.log` (same
`~/Library/Logs` convention as Component D, not `/tmp`, so this new job
doesn't reintroduce the exact bug D just fixed). Added to
`check_launchd_fleet.sh`'s `KNOWN_LABELS` array as
`com.disk-magician.disk-usage-alert`.

### Files touched (exact list)

- `scripts/install_launchd_sweepers.sh` — manifest write, log-dir mkdir, `MANIFEST_FILE`/`STATE_DIR` vars
- `scripts/check_launchd_fleet.sh` — hash-drift check, `drift` counter, new `KNOWN_LABELS` entry
- `scripts/residual_drilldown.sh` — one non-fatal call to `check_launchd_fleet.sh`
- `scripts/disk_usage_alert.sh` — body replaced with reconciled deployed logic + `--sweeper-degraded` mode, existing streak/step-event code preserved
- `scripts/sweeper_health_check.sh` — lines 239-244 notify egress swap
- `scripts/vacuum_hermes_state.sh` — 2 comment-only filename updates (lines 26, 31)
- `launchd/com.disk-magician.colima-prune.plist` → renamed `.plist.template`, StandardOut/ErrorPath changed
- `launchd/com.disk-magician.hermes-vacuum.plist` → renamed `.plist.template`, StandardOut/ErrorPath changed
- `launchd/com.disk-magician.playwright-dedup.plist` → renamed `.plist.template`, StandardOut/ErrorPath changed
- `launchd/com.disk-magician.worktree-venvs.plist` → renamed `.plist.template`, StandardOut/ErrorPath changed
- `launchd/com.disk-magician.sweeper-health.plist` → renamed `.plist.template`, StandardOut/ErrorPath changed
- `launchd/com.disk-magician.disk-usage-alert.plist.template` — new file
- `tests/test_check_launchd_fleet.sh` — extended with hash-drift cases (see Plan)
- `tests/test_install_launchd_sweepers_preflight.sh` or a new sibling test — manifest-write assertion (see Plan)
- new `tests/test_disk_usage_alert_sweeper_mode.sh`
- `src/disk_magician/**` — synced copies via `scripts/sync_package_tree.sh` (run at integration time, not hand-edited)
- `pyproject.toml` — version bump (done once at integration, per CLAUDE.md; not part of this design's line-by-line diff)

Not touched: `safety.local.json`, `scripts/lib/worktree_recency.sh`, any
deletion-authority code path, `scripts/cleanup_*.sh`, the never-delete list.

## Error Handling and Fail-Closed Behavior

- Manifest read failures (corrupt JSON, missing `python3`) must not crash
  `check_launchd_fleet.sh` — the inline `try/except -> {}` in the Python
  snippet already returns an empty dict, which resolves to `HASH-UNKNOWN`
  (informational), matching the "cannot measure → don't claim broken"
  convention.
- `record_manifest_entry` writes via temp-file + atomic rename so a crash
  mid-write never leaves a torn/partial JSON manifest for the reader to
  choke on.
- The drilldown job's new `check_launchd_fleet.sh` call is `|| true`:
  drilldown's own residual logic runs unconditionally regardless of fleet
  health, and a degraded fleet is reported (via that shared log), not acted
  on automatically — no new auto-repair trigger is added on the drilldown
  cadence (`sweeper-health --auto-repair` remains the only auto-repair path,
  unchanged).
- `disk_usage_alert.sh --sweeper-degraded` delivery failure (`|| true` at the
  `sweeper_health_check.sh` call site) never turns a health-check script into
  a non-zero exit for a reason unrelated to sweeper health — matches the
  existing comment-documented contract ("never alerts externally... wire an
  alerting layer onto the non-zero exit code" at the top of
  `sweeper_health_check.sh`, now literally true for the first time).

## Tests (exact files)

See Plan doc for the full list and behavioral assertions; summarized here:

- `tests/test_check_launchd_fleet.sh` (extend, don't replace) — 3 new cases:
  hash match → OK (no drift line); hash mismatch with a manifest entry
  present → `HASH-DRIFT` line + exit 1; manifest file present but label
  absent from it → `HASH-UNKNOWN` line, does NOT flip exit code (paired with
  an otherwise-all-OK fixture to prove it alone can't fail the run).
- `tests/test_install_launchd_sweepers_manifest.sh` (new) — installs a
  fixture plist through `install_plist()` with a stubbed `launchctl`,
  asserts `launchd_manifest.json` is created, contains the label with a
  sha256 that matches `shasum -a 256` of the installed destination file, and
  that a second install with unchanged content does not spuriously change
  `installed_at` semantics in a way that breaks idempotency (re-run is safe).
- `tests/test_disk_usage_alert_sweeper_mode.sh` (new) — stubs `send_email`
  and the Slack MCP path (or exercises them against a fake Slack MCP
  stdio server binary, mirroring `send_slack_to_all_channels`'s subprocess
  contract) and asserts `--sweeper-degraded "msg"` triggers a delivery
  attempt with the given message in the payload, independent of current
  free-space state (test forces `THRESHOLD_GB` unreachable to prove the
  degraded-mode branch bypasses the free-space gate).
- `tests/test_residual_drilldown_fleet_check.sh` (new, small) — stubs
  `check_launchd_fleet.sh` at `$SCRIPT_DIR` (via a fixture dir override or a
  PATH-shadow trick matching the existing `FAKE_BIN` pattern) returning
  exit 1 with known text, asserts `residual_drilldown.sh` still completes
  its own normal (dry-run) output and that the stub's text appears in
  captured combined output.

## Manual Verification Recipe (against the live fleet)

Run in order, on the real machine, no `WORKTREE_APPROVED` or destructive
gates involved (all read-only or additive):

```bash
cd ~/projects_other/disk_magician
bash tests/test_check_launchd_fleet.sh                       # existing regression, must still pass
bash tests/test_install_launchd_sweepers_manifest.sh          # new
bash tests/test_disk_usage_alert_sweeper_mode.sh               # new
bash tests/test_residual_drilldown_fleet_check.sh              # new
bash scripts/install_launchd_sweepers.sh                       # real install; writes real manifest
cat ~/.disk_magician_state/launchd_manifest.json | python3 -m json.tool | head -20
./disk_magician.sh check-launchd-fleet                         # expect 16 (or 17 w/ new alert job) OK, 0 HASH-DRIFT
# Force a drift to prove the negative path works:
plutil -replace CFBundleVersion -string x ~/Library/LaunchAgents/com.disk-magician.colima-prune.plist 2>/dev/null || \
  echo '<!-- touch -->' >> ~/Library/LaunchAgents/com.disk-magician.colima-prune.plist
./disk_magician.sh check-launchd-fleet                          # expect HASH-DRIFT for colima-prune
bash scripts/install_launchd_sweepers.sh colima-prune            # repairs + re-records manifest
./disk_magician.sh check-launchd-fleet                           # back to clean
ls -la ~/Library/Logs/disk-magician/                             # 6 logs now present (5 weekly + new alert job)
ls /tmp/disk-magician-*.log 2>/dev/null                          # should show NO entries for the 5 renamed jobs post-reinstall
grep -n "Fleet:" /tmp/disk-magician-drilldown.log | tail -3       # or its new ~/Library/Logs path — proves component C fired
bash scripts/sweeper_health_check.sh --threshold-days 0          # forces a MISS on every sweeper (0-day threshold)
tail -5 ~/Library/Logs/disk-magician/disk-usage-alert.log         # or wherever the forced-FAIL run logged — proves E fired
scripts/sync_package_tree.sh --check                              # expect the newly-renamed launchd files now IN sync
```
