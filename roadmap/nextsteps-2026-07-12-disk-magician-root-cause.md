# Nextsteps — disk_magician — 2026-07-12

## Executive summary

Session confirmed the active growth-class roots are still:

- fresh AO/private-PR scratch growth in `/private/tmp` (`pr*-evidence-*`, `worldarchitect-pr*`, `lane-*`)
- stale worktree and agent workspace retention
- Colima host + VM disk regrowth under CI pressure
- occasional OS/app cache accumulation not yet on safe auto-clean paths

This document captures all currently open disk_magician/related beads and the concrete roadmap solution path for each.

## Active bead ledger (disk recovery)

| Bead | Title | Priority | Type | Owner | Expected impact | Next solution step |
|---|---|---:|---|---|---|---|
| bd-m8w | Guard backup-home.sh from /tmp writes (user_scope) | P1 | task | jleechan | Prevents ~40G/day duplicate backup growth and unsafe rsync targeting | Stage user-scope fix in user_scope repo before AO scratch cleanup lands across repos. |
| jleechan-dqiz | Close fresh AO private-tmp scratch cleanup gap | P1 | bug | jleechan | Removes repeated ~40GB/day temporary growth class | Implement atomic register-on-start + dead-pid stale-sweep in AO producer flow, then `pressure_sweep --large` hardens fallback. |
| jleechan-etjw | Colima sparse VM disk inflates ~31.6GB/hr under ez-mac-runner CI churn; needs prune+trim cadence | P1 | task | jleechan | Reduces unplanned `~/.colima/_lima` inflation and reclaim cadence misses | Add wedge detection + restart+fstrim fallback in `cleanup_colima.sh`; keep 2h gate behavior in pressure sweep. |
| jleechan-dp2x | cleanup_apfs_snapshots.sh --clean fails with sudo required, weekly plist can't actually reclaim | P2 | bug | jleechan | Enables reclaim of stale OS update snapshots if present | Add privileged execution model (`sudoers` scoped command OR root LaunchDaemon`) and document operational runbook. |
| jleechan-p2gy | Migrate ~/projects node_modules to pnpm shared store (6.2G duplication) | P2 | task | jleechan | Recovers duplicate JavaScript dependency stores across worktrees | Evaluate low-risk symlinkdedupe script path first, then decide pnpm migration for low-touch repos. |
| jleechan-z2ya | Review iMessage attachments storage (~28.7G library_messages) | P2 | task | jleechan | Optional large reclaim if user allows | User-approved message cleanup in macOS Storage → Messages settings. |
| jleechan-u6zx | Review stale Codex session folders (~17.1G, manual only) | P2 | task | jleechan | Manual review-only under never-delete policy | Keep isolated from automation; user-approved cleanup only. |
| jleechan-yv7b | Fix Playwright canonical symlink + antigravity-cli cache growth | P1 | bug | jleechan | Removes recurring AO cache accumulation | Repair canonical cache bootstrap and keep `symlink-shared-playwright-cache.sh` healthy as a stable precondition. |
| jleechan-qijk | review disk_magician cleanup safety | P2 | task | jleechan | Close residual safety validation gaps | Reconcile docs/tests/gates against current behavior before further automation changes. |
| jleechan-emnx | disk_snapshot.sh JSON containers_captured bug | CLOSED (P2) | bug | jleechan | Prevents snapshot/audit false negatives during path-heavy scans | Fixed in `1fc5b6a`; keep JSON schema-safe emission in tests only. |
| jleechan-xadi | disk_magician backup repo: 623 snapshot commits unreachable from main, at risk of git gc loss | P2 | bug | jleechan | Protects historical trend data and prevents evidence-loss regressions | Finalize branch/tag or immutable archive policy for reclaimed commits and document runbook. |
| jleechan-ia86 | 100G-reclaim session pending user decisions A-E (3 gated items exceed script-only safe budget) | P1 | task | jleechan | Keeps remaining high-impact reclaim options explicit and user-queued | Use this as user decision log before any manual gated cleanup. |

## Execution order (recommended)

1. Finish `jleechan-dqiz` (agent scratch lifecycle) because it directly gates recurring daily growth spikes.
2. Finish `jleechan-etjw` once PR evidence cleanup is stable, because Colima can re-pressurize storage quickly.
3. Close `jleechan-dp2x` and lock APFS cleanup governance.
4. Workspace pruning remains contingent on reappearance of stale state: reassess `jleechan-p2gy`; `jleechan-g3d1` and `jleechan-8twx` are closed by runbook review.
5. Keep `jleechan-z2ya` and `jleechan-yv7b` as explicit user/housekeeping approvals.

## Verification notes

- Cleanup modes and approvals are now in "Delete-mode matrix" below; each row includes test or command evidence.
- Safety regression coverage: `bash tests/test_cleanup_safety.sh` (41 pass, 0 fail) run against current scripts.
- Before each merge, verify the corresponding bead description reflects the current scope and ownership.
- At weekly cadence, update this file and `roadmap/README.md` with changed bead status plus new blockers.
- Use `br show <bead-id>` for current status before any operations.

### Closed this cycle

- `jleechan-emnx` — fixed; JSON parser-safe emission is now enforced and snapshot audit accepts partial coverage paths without malformed JSON rejection.
- `jleechan-g3d1` — scripted review found 0 eligible stale-orphan deletions with 126 preserved worktrees (safe gate prevented script-only cleanup).
- `jleechan-8twx` — antigravity worktree root currently missing (`~/.gemini/antigravity/worktrees`), so no safe deletion path exists until it is recreated.
- `jleechan-9s68` — cleanup safety regression suite expanded and passing: `bash tests/test_cleanup_safety.sh` reports 41 pass / 0 fail.
- `jleechan-xk95` — behavior docs updated with safe/review/manual cleanup mode matrix.
- `jleechan-y1xm` — approved cleanup gates formalized in this doc and linked from `roadmap/README.md`.

## Delete-mode matrix (SAFE / REVIEW / MANUAL)

| Mode | Example targets | Trigger mechanism | Approval gate | Evidence |
|---|---|---|---|---|
| SAFE | OpenCode dylib stale files, dev caches, regular tmp/tmp-private cleanup classes, worktree venv reclamation | `disk_magician.sh clean`, `cleanup_dev_caches.sh`, `cleanup_tmp.sh`, `reclaim_worktree_venvs.sh` | None (dry-run first) | Script output plus `test_cleanup_safety.sh` Test 2, 4, and 9 |
| REVIEW | Large tmp cleanup, worktrees, Playwright AO dedup, APFS snapshots, code-sign clones | `disk_magician.sh clean-all`, explicit per-script `--large`, `--clean` with env token | `LARGE_TMP_APPROVED=1`, `WORKTREE_APPROVED=1`, `AO_PLAYWRIGHT_DEDUP_APPROVED=1`, `CODE_SIGN_CLONES_APPROVED=1`, `sudo/root runbook for APFS snapshots` | Script dry-run banners; refusal strings in `test_cleanup_safety.sh` tests 3, 8, 9 |
| MANUAL | Codex Sessions, iMessage attachments, non-dedicated message caches | OS-native settings or user review outside disk_magician scripts | Manual user confirmation + bead owner routing | User-owned decisions in this queue (`jleechan-u6zx`, `jleechan-z2ya`) |

**Note:** this matrix is intentionally conservative; scripts that require explicit approval continue to fail-closed when approvals are absent.

## Evidence anchors

- `roadmap/activity/2026-07-12.md` (session history and first-pass root-cause)
- `roadmap/nextsteps-2026-07-06-disk-magician-four-causes.md` (older queue and historical backlog)
- `br show jleechan-dqiz`, `br show jleechan-etjw`, `br show jleechan-dp2x`

---

# Roll-forward — 2026-07-14 (READ-ONLY recheck)

> **Canonical correction (23:53Z):** The two point-in-time roll-forwards below preserve the investigation timeline, but their earlier causal conclusions are superseded here. Sparse apparent capacities must not be added and reported as allocated storage. Snapshot `residual_gb` and `residual_delta_gb` are coverage/accounting fields, not physical allocation or reclaim. Live 45-second sampling tied rapid growth to repeated one-shot ezgha runner/container replacement; it did not establish crashes or OOMs. The 5.8 GiB to ~76–79 GiB physical recovery was not caused by the earlier pressure sweep or the no-op host guardian. A reboot at 21:13:33Z brackets the largest recovery and is consistent with release of deleted-but-open blocks, but the responsible process/file was not captured and remains open under `jleechan-w5is` and `jleechan-tbe3`. At 23:26Z the latest snapshot reported schema v2, 72.5% coverage, and 234.0 GiB residual; the first real frontier launchd run was started at 23:58Z. No deletion gate is implied by this report.

## Executive summary

Disk re-entered the **100% capacity / ~5.8 GiB free** state (2026-07-14 ~21:00Z). Snapshot v2 showed **coverage 46%, residual 472 GiB, residual_delta_gb +81.7**. Those residual fields quantify unmeasured/accounting space; they do not establish a matching physical regression. The five timed-out measured keys (`codex_sessions`, `gemini_root`, `hermes`, `library_caches`, `projects`) contributed to the coverage gap but cannot each be equated to the full residual. **No destructive action occurred in this read-only recheck.**

The live growth vectors (from `lsof`, snapshot, and `df` sampling) are the same four classes called out in the 07-12 root-cause doc, with two sharp new inflections:

1. The initial **~186 GiB Colima** total was invalid: it added sparse apparent capacities and aliases. Allocated-byte measurements later in the same investigation were about 22.4 GiB for `~/.colima` and 20.6 GiB for the active datadisk, then grew under verified one-shot runner replacement. Low host free space makes the documented Colima wedge mode a risk; it does not prove the guest was wedged at that timestamp.
2. **`~/.hermes/state.db` = 6.6 GiB** held open by Python process(es); **`~/.codex/logs_2.sqlite` = 3 GiB** held open by codex. Both are WAL/append-only growth, not cleanup-targetable through disk_magician scripts today.

## Live state (2026-07-14 ~21:00Z)

| Metric | Value | Source |
|---|---|---|
| `/System/Volumes/Data` free | **5.8 GiB** (5.8% usable) | `df -h` |
| Disk used (snapshot v2) | 874 GiB / 926 GiB | `backup/jeffreys-macbook-pro/disk_snapshot.json` |
| Snapshot coverage | **46.0%** (raw 46.9%) | snapshot_metadata.coverage_pct |
| Residual (unmeasured) | **472 GiB** | `residual_gb` |
| Residual growth vs prior snapshot | **+81.7 GiB** | `residual_delta_gb` |
| Timed-out keys | `codex_sessions, gemini_root, hermes, library_caches, projects` | `timeout_keys` |
| APFS local snapshots | 3 OS-update snapshots visible | `tmutil listlocalsnapshots /` |
| Floor-to-now growth (07-07 → 07-14) | ~36 GiB tracked, 472 GiB untracked | derived |

## Top measured consumers (snapshot v2, GiB)

| Rank | Key | GiB | Class |
|---:|---|---:|---|
| 1 | projects_other | 36.1 | source trees |
| 2 | root_library | 35.8 | Library/* |
| 3 | library_messages | 28.7 | iMessage attachments → `jleechan-z2ya` |
| 4 | projects_reference | 28.3 | source trees |
| 5 | codex_root | 27.8 | codex state (excl. 28G sessions/logs which timed out) |
| 6 | colima | 26.2 | measured snapshot view; sparse apparent capacity is not allocated storage |
| 7 | library_app_support | 25.4 | per-app caches |
| 8 | applications | 23.9 | installed apps |
| 9 | worktrees_dot | 20.5 | jleechan claw worktrees |
| 10 | opt | 16.1 | /opt (dev tools) |

## Open beads — disk recovery queue (refresh)

| Bead | P | Status | Expected impact | This session |
|---|---:|---|---|---|
| [jleechan-dqiz](https://github.com/jleechanorg/worldarchitect.ai/issues) | P1 | open | Stops repeated ~40 GiB/day AO private-tmp scratch growth | **revalidated live** — df swing over 15s still measurable; pressure_sweep gate holds at <40G |
| bd-m8w (user_scope backup-home /tmp guard) | P1 | open (cross-repo user_scope) | Stops ~40 GiB/day duplicate rsync growth | not modified this session; bead already on file |
| jleechan-etjw | P1 | open | Colima allocated bytes grow under verified one-shot runner churn | **NEEDED** — lifecycle prevention and safe trim recovery remain open |
| jleechan-dp2x | P2 | open | APFS snapshot reclaim needs sudoers model | partially shipped in 21c3de7 (privileged LaunchDaemon for apfs-snapshots) — verify it's running |
| jleechan-igr8 | P1 | open | Frontier-BFS total-coverage scanner (snapshot v2) | **directly relevant** — would have named the 472 GiB residual instead of leaving it as `null` |
| jleechan-wsbk | P2 | open | Coverage collapses under pressure → projects du timeout | live regression — `projects, projects_other, projects_reference` are the timed-out trio today |
| jleechan-xadi | P2 | open | 623 backup-repo commits unreachable from main | independent of today's pressure; remains low-urgency |
| jleechan-ia86 | P1 | open | 100G-reclaim session awaiting user decisions A–E | **DECISIONS E STILL NEEDED** — A/B are now urgent given 5.8 GiB free |
| jleechan-u6zx | P2 | open | Review stale Codex session folders (~17.1G) | **timed out in snapshot; likely grew** |
| jleechan-z2ya | P2 | open | iMessage attachments ~28.7G | measurable; user-owned |
| jleechan-yv7b | P1 | open | Playwright canonical symlink + antigravity-cli cache growth | unchanged this session |
| jleechan-p2gy | P2 | open | node_modules dedup via pnpm shared store (~6.2G) | low-priority vs pressure |

## Updated execution order (recommended, 07-14)

1. **EMERGENCY (next 30 min):** user decision on `jleechan-ia86` items A + B. Disk at 5.8 GiB free will wedge guest I/O on next CI cycle.
   - A) `SIM_DRAIN_APPROVED` (iOS Sim devices, no booted) — re-confirm; safe.
   - B) `VACATE_CI_RUNNERS_APPROVED` remains an exact gate. Re-quantify the active datadisk with allocated-byte measurements; do not use the discarded ~186 GiB apparent-capacity sum.
2. **Safety fix:** complete `jleechan-etjw` lifecycle prevention and the responsive-Docker/broken-Colima-control-plane trim path. Do not stop Colima while CI is active; measure before/after any separately approved operational recovery.
3. **Today:** verify `21c3de7` (privileged apfs-snapshots LaunchDaemon) is loaded — `sudo launchctl list | grep apfs-snapshots`. Reclaim up to 20 GiB if OS-update snapshots are stale (`tmutil thinlocalsnapshots / 9999999999 1`).
4. **Operational verification:** frontier-BFS integration is shipped. Verify the first launchd run and capture its complete/partial result before closing `jleechan-igr8`.
5. **Today:** `br update jleechan-dqiz --priority 0` (was P1) given active daily growth pressure.
6. **This week:** `jleechan-u6zx` manual review of `~/.codex/sessions/` — currently unmeasurable but likely ~25-30 GiB today; user-approved only.
7. **This week:** `jleechan-xadi` immutable-tag the reflog tip commits before reflog expiry (still pending root-cause).
8. **Hold:** `jleechan-z2ya`, `jleechan-p2gy`, `jleechan-yv7b` — non-urgent vs pressure.

## Verification notes (2026-07-14)

- All commands this session were **READ-ONLY** (`df`, `du -sh`, `lsof`, snapshot JSON parse, git log on backup repo). Nothing was deleted.
- Sweeper health was NOT re-verified in this session; last audit was `roadmap/activity/2026-07-12.md`.
- Coverage gap (472 GiB unmeasured) directly motivates shipping `jleechan-igr8` `topdown_enabled` ahead of the next pressure sweep window.
- Disk has only **5.8 GiB free**; any write to /tmp, ~/, or `/private/tmp` must be tiny. Do not start heavy AO workers until ≥15 GiB free.

## Bead ledger (refreshed 2026-07-14)

| Bead | Title | Link |
|---|---|---|
| jleechan-dqiz | Close fresh AO private-tmp scratch cleanup gap | [show](https://github.com/jleechanorg/worldarchitect.ai/issues) |
| jleechan-etjw | Colima sparse VM disk inflates ~31.6GB/hr | [show](https://github.com/jleechanorg/worldarchitect.ai/issues) |
| jleechan-dp2x | cleanup_apfs_snapshots.sh --clean sudo required | [show](https://github.com/jleechanorg/worldarchitect.ai/issues) |
| jleechan-igr8 | Implement frontier-BFS total-coverage scanner (snapshot v2) | [show](https://github.com/jleechanorg/worldarchitect.ai/issues) |
| jleechan-wsbk | Snapshot coverage collapses under disk pressure | [show](https://github.com/jleechanorg/worldarchitect.ai/issues) |
| jleechan-xadi | disk_magician backup repo: 623 snapshot commits unreachable | [show](https://github.com/jleechanorg/worldarchitect.ai/issues) |
| jleechan-ia86 | 100G-reclaim session pending user decisions A–E | [show](https://github.com/jleechanorg/worldarchitect.ai/issues) |
| jleechan-u6zx | Review stale Codex session folders (~17.1G, manual only) | [show](https://github.com/jleechanorg/worldarchitect.ai/issues) |
| jleechan-z2ya | Review iMessage attachments storage (~28.7G) | [show](https://github.com/jleechanorg/worldarchitect.ai/issues) |
| jleechan-yv7b | Fix Playwright canonical symlink + antigravity-cli cache | [show](https://github.com/jleechanorg/worldarchitect.ai/issues) |
| jleechan-p2gy | node_modules → pnpm shared store (6.2G duplication) | [show](https://github.com/jleechanorg/worldarchitect.ai/issues) |

## PR / merge state (last verified 2026-07-12; not re-verified this session)

- `a895c52 feat(sweepers): automatically configure passwordless sudoers rule for apfs-snapshots` — landed on main
- `74d7444 fix(worktrees): auto-discover registered repositories, support .ao/data/worktrees, and auto-unlock stale locks` — landed on main
- `21c3de7 fix(apfs-snapshots): install apfs-snapshots sweeper as privileged system LaunchDaemon and resolve jleechan-dp2x` — landed on main (close `jleechan-dp2x` once launchctl verification confirms running)
- `4220ff0 fix(pressure_sweep): run cleanup_tmp --large under disk pressure (jleechan-nkzj)` — landed on main
- `2dc1bd5 chore(disk_magician): add 2026-07-12 roadmap solutions and close cleanup docs beads` — landed on main

## Learnings pointer

- `~/roadmap/learnings-2026-07.md` — if updated separately, record the sparse-vs-allocated and residual-vs-physical corrections above; do not repeat the discarded ~186 GiB allocation claim.

## Roadmap pointer

- Appended `roadmap/activity/2026-07-14.md` — read-only pressure recheck, fan-out to /history+/ms+/swarm, no destructive action.

---

# Roll-forward #2 — 2026-07-14 ~21:30Z (snapshot recheck)

## Delta since the prior /nextsteps (~30 min earlier)

| Metric | 21:00Z | 21:20Z | Delta |
|---|---:|---:|---:|
| `/System/Volumes/Data` free | 5.8 GiB | **79.3 GiB** | **+73.5 GiB** in 30 min |
| disk used (snapshot) | 874 GiB | 850 GiB | -24 GiB |
| coverage_pct | 46.0 | **59.3** | +13.3 pp |
| residual_gb | 472 | **345.7** | **-126.3** |
| residual_delta_gb | +81.7 | **-126.3** | sign flipped |
| warning | low_coverage | low_coverage | unchanged |
| timed-out keys | 5 (hermes, codex_sessions, gemini_root, library_caches, projects) | **6 different keys** (library_messages, downloads, documents, desktop, library_mobile_documents, library_mail) | shifted to lighter-weight paths |
| frontier_last.json | partial, age unknown | partial, **age 10.2 h**, 219 unfinished frontier entries, 350 GiB residual | frontier-BFS partly wired |

This window combines a physical free-space recovery with a snapshot coverage/accounting change. Later timestamped evidence showed that the pressure sweep completed before the recovery window, the host guardian reclaimed zero bytes, and the nightly frontier job had not yet run; they must not be credited with the recovery.

## Live top consumers (21:20Z snapshot)

| Rank | Key | GiB | Class |
|---:|---|---:|---|
| 1 | **projects** | **142.1** | source trees (was timed out 30 min ago; now measured) |
| 2 | projects_other | 36.1 | source trees |
| 3 | projects_reference | 28.3 | source trees |
| 4 | codex_root | 27.8 | codex state |
| 5 | gemini_root | 25.3 | gemini state |
| 6 | applications | 23.9 | installed apps |
| 7 | project_siblings | 23.1 | other source trees |
| 8 | library_app_support | 22.5 | per-app caches |
| 9 | worktrees_dot | 20.5 | jleechan claw worktrees |
| 10 | codex_sessions | 17.3 | codex session logs |

`projects_other`, `projects_reference`, `worktrees_dot` are unchanged from 21:00Z — these are the stable 28–36 GiB base load.

## Live drill of new timed-out keys (small)

- `~/Downloads` = **5.7 GiB** (was timed out but small)
- `~/Documents` = **1.3 GiB**
- `~/Desktop` = **142 MiB**
- `~/Library/Mobile Documents` = **3.9 MiB**
- `~/Library/Messages/Attachments` = **timed out at 90s, ≥10 GiB estimated** — likely 10-30 GiB; safe user-side cleanup
- `~/Library/Mail` = timed out at 90s, unknown but Apple Mail + IMAP caches can be 5-15 GiB

## Launchd sweeper health (live, 21:30Z)

The listed disk_magician jobs were loaded, but loaded/last-exit metadata alone did not prove that every scheduled path had run successfully on this boot:

```
com.jleechan.disk-usage-alert                    exit=0
com.jleechan.cleanup-apfs-snapshots              exit=0
com.disk-magician.gemini-dedup                   exit=0
org.jleechanorg.host-disk-guardian               exit=0
com.disk-magician.colima-prune                   exit=0
com.disk-magician.playwright-dedup               exit=0
com.jleechanorg.disk-magician                    exit=0  ← main 35-min snapshot
com.jleechanorg.disk-magician-drilldown          exit=0
```

`host-disk-guardian` PID 765 looks odd (low PID; might be a separate namespace PID), but the rest are healthy.

## What changed vs the prior /nextsteps queue

The 4-class taxonomy from 07-12 is **still correct** and unchanged. What shifted:

1. **Immediate pressure eased, mechanism still open.** Free space recovered from 5.8 GiB → 79.3 GiB without a manual cleanup. Do not infer that the sweepers caused it. `jleechan-ia86` remains gated and can stay behind the prevention work.
2. **`projects=142 GiB` is the new top measured consumer** — it's been hidden for weeks (always timed out). Now measured, it confirms `jleechan-p2gy` (node_modules dedup) is real but small (~6 GiB) vs the **142 GiB project trees themselves**. Cleanup candidates within `projects` need fresh `du -sh` drilldown by cluster.
3. **Frontier-BFS is partial-mode wired** (topdown_coverage captured, 219 unfinished frontier entries). `jleechan-igr8` work is now visibly partial — the `topdown_enabled` flag needs full integration into `disk_snapshot.sh` to stop the 219 unfinished frontier entries from persisting.
4. **`library_messages` timed out at 142 MiB Desktop / 1.3 GiB Documents / 5.7 GiB Downloads is now in scope** — those are user-owned cleanup candidates; safe to recommend Manual review per the SAFE/REVIEW/MANUAL matrix.

## Updated execution order (recommended, 21:30Z)

1. **Today:** close the sweepers' gap on `projects=142 GiB` — drill into `~/projects/*` (top 15 subdirs by size) and identify which are active worktrees vs dormant. Reclaim candidates cluster around `worktree_*/node_modules`, `worktree_*/.venv`, merged-but-not-cleaned-up AO worktrees.
2. **Today:** finalize `jleechan-igr8` `topdown_enabled` integration — convert frontier from `partial-mode` (219 unfinished) to `complete-mode` so next snapshot's `library_messages` doesn't time out at 142 MiB Desktop.
3. **Today:** `jleechan-ia86` decisions A+B — demote from urgent to user-queue; reclaim math needs fresh measurement against 79 GiB free.
4. **This week:** `jleechan-etjw` — prevent one-shot runner churn from accumulating allocated Colima blocks, and make trim recovery work when Docker responds but the Colima control plane is broken. Re-quantify with `du`/allocated bytes, not sparse apparent capacity.
5. **This week:** `jleechan-u6zx` manual review — `~/.codex/sessions` is now measurable at 17.3 GiB (vs the 17.1 GiB 07-12 estimate); user-approved only.
6. **Hold:** `jleechan-z2ya` (iMessage attachments timed out; revisit after frontier integration), `jleechan-p2gy` (node_modules dedup; real but small).

## Verification notes (21:30Z recheck)

- All commands READ-ONLY (df, du -sh with 90s timeouts, snapshot JSON parse, launchctl list). Disk now at 79 GiB free → safe to start moderate write activity.
- Launchd load state was verified, but the nightly frontier job still had zero runs and load state alone was not end-to-end health proof.
- The +73.5 GiB physical free-space swing and -126.3 GiB residual change are different metrics. Measuring `projects` explains part of the residual/accounting shift but cannot free physical bytes. The physical recovery remains open pending direct process/file evidence.
- Disk above 75% capacity (`91%` per snapshot) → don't run heavy AO workers without confirming ≥15 GiB free first.

## Bead ledger (refreshed 21:30Z, no new creates this session)

| Bead | P | Status | Notes |
|---|---:|---|---|
| jleechan-qlo5 | P1 | open | this session's tracking bead |
| jleechan-igr8 | P1 | open | frontier partial→complete integration |
| jleechan-etjw | P1 | open | Colima wedge (re-quantify floor) |
| jleechan-ia86 | P1 | open | demoted to user-queue |
| jleechan-dqiz | P1 | open | unchanged |
| bd-m8w | P1 | open | cross-repo user_scope |
| jleechan-dp2x | P2 | open | APFS sudoers shipped in 21c3de7 — verify running |
| jleechan-wsbk | P2 | open | partial coverage addressed by igr8 |
| jleechan-xadi | P2 | open | independent |
| jleechan-u6zx | P2 | open | codex sessions now measurable at 17.3 GiB |
| jleechan-z2ya | P2 | open | messages attachments timed out |
| jleechan-yv7b | P1 | open | Playwright symlinks |

## PR / merge state (last verified 07-12; not re-verified this session)

- `a895c52` (sudoers rule for apfs-snapshots), `74d7444` (worktree auto-discover), `21c3de7` (apfs-snapshots LaunchDaemon), `4220ff0` (pressure_sweep --large), `2dc1bd5` (roadmap close beads) — all on `main`.

## Learnings pointer

- `~/roadmap/learnings-2026-07.md` — if updated separately, describe the +73.5 GiB physical recovery as unexplained/reboot-bracketed and the residual shift as measurement reclassification.

## Roadmap pointer

- Appended `roadmap/activity/2026-07-14.md` with a corrected second bullet separating physical recovery, residual accounting, and frontier operational state.
