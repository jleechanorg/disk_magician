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

# Roll-forward — 2026-07-15 (sustained /sidekick + /swarm + ultracode root-cause session)

## Table of contents (this section only — earlier sections predate the TOC convention)

- [Executive summary](#executive-summary-2026-07-15)
- [Context](#context-2026-07-15)
- [Bead index](#bead-index-2026-07-15)
- [Confirmed mechanisms](#confirmed-mechanisms-2026-07-15)
- [Fixes shipped](#fixes-shipped-2026-07-15)
- [Cleanups executed](#cleanups-executed-2026-07-15)
- [Work queue / open items](#work-queue--open-items-2026-07-15)
- [PR / merge state](#pr--merge-state-2026-07-15)
- [Learnings pointer](#learnings-pointer-2026-07-15)
- [Roadmap pointer](#roadmap-pointer-2026-07-15)

## Executive summary {#executive-summary-2026-07-15}

- Ran a multi-hour sustained investigation (two in-session sidekicks + one ultracode Workflow fan-out) to truly root-cause disk free-space swings, not just correlate them.
- **Two mechanisms confirmed with live/direct evidence** (not correlation): (1) OS reboot at 2026-07-14T21:13:33Z force-closing fds on a deleted-but-open file, explaining the 5.8GiB→76GiB recovery; (2) Colima guest-VM wedge → forced restart → in-VM `fstrim`, caught live 00:19-00:20Z with the datadisk file shrinking 50.5GB→23.8GB→7.6GB in real time — this is the recurring, actionable mechanism (matches an already-documented CLAUDE.md failure mode).
- **Rigorous disk accounting completed** (`jleechan-w5is` comments): ground truth 834.65 GiB used, 620.77 GiB directly measured via `du -xsk`, gap of 213.9 GiB fully named as TCC/SIP-protected paths (`~/.Trash`, ~20 `~/Library` subtrees — MobileSync backups called out as the likely largest single piece — 4 SIP dotdirs), not hand-waved.
- **Fixes shipped and deployed** (not just committed): `dua-cli` wired as a `du`-timeout fallback in `disk_snapshot.sh` (commits `74ded74`, `6bb839c`, v0.2.12→0.2.13; later PR #16 merged further Library-coverage work on top, now at v0.2.18 — re-verify fallback still intact post-merge before next claim).
- **Cleanups executed, real bytes freed:** Colima wedge-recovery run (32GiB→54GiB free, datadisk 27GB→4.2GB); `~/projects_reference` build-artifact purge (28.3GB→11GB — `.zig-cache`, Rust `target/`, Xcode `build/`, zero data loss); 2 genuinely-48h+-old `dk2d_evidence` items (~469MB, most candidates were disqualified on a per-file mtime check, not just directory mtime).
- **Blocked, needs user action:** MobileSync backup deletion — macOS TCC Full Disk Access is not granted to the hosting app (traced process tree to **cmux**, specifically "cmux DEV dev-fork"); `sudo -n` does not bypass this. User must grant via System Settings → Privacy & Security → Full Disk Access before this can proceed.
- **Still genuinely open:** `dk2d_evidence` has no retention policy and grew 24GB→37GB during this session alone (~13GB in a few hours) — the single fastest-growing untracked consumer found; the 2026-07-13 historical swing pair remains unexplained by any confirmed mechanism.

## Context {#context-2026-07-15}

Continuation of the 2026-07-12/07-14 disk-recovery investigation in this same rolling doc. Repo: `jleechanorg/disk_magician`, branch `main`, no PR (direct commits, matches this repo's evident direct-to-main convention). Session used `/cmux-goal` twice to self-enforce a Stop hook until root-cause criteria were met, `/sidekick` twice (`sidekick-root-cause-swing-mechanism`, `sidekick-real-accounting`, both in-session Agent-tool teammates per the DEFAULT visible-team mode), and one ultracode Workflow (`wf_c6e77463-977` then `wf_f93abdb9-502`) for adversarial 3-lens verification of candidate causes.

## Bead index {#bead-index-2026-07-15}

| Bead | Title | Status |
|---|---|---|
| [jleechan-w5is](https://github.com/jleechanorg/disk_magician/issues) | Root-cause the unexplained fast disk free-space swing mechanism (parent) | Open — see comments for full evidence trail |
| [jleechan-3umv](https://github.com/jleechanorg/disk_magician/issues) | Unexplained fast free-space recovery 5.8GiB→76GiB | Open — mechanism confirmed (reboot fd-release), culprit process forensically unreachable |
| [jleechan-tbe3](https://github.com/jleechanorg/disk_magician/issues) | Tight-cadence disk-free live logger | Done, ran ~3h, self-terminated at time-box |
| [jleechan-hjup](https://github.com/jleechanorg/disk_magician/issues) | APFS local-snapshot candidate | Refuted with direct storagekitd telemetry |
| [jleechan-pfxw](https://github.com/jleechanorg/disk_magician/issues) | Swapfile/other-launchd candidate | Corrected then refuted-for-the-flagship-event (swap is real but wrong path initially checked, and too small/wrong-window for the main event) |
| [jleechan-fslj](https://github.com/jleechanorg/disk_magician/issues) | Colima VM crash-looping, CI capacity degraded | Open — recovery run (see Cleanups), re-verify current state |
| [jleechan-rx6v](https://github.com/jleechanorg/disk_magician/issues) | host-disk-guardian log leaks plaintext GitHub PATs | **Open — still needs user credential rotation, not yet done** |
| [jleechan-772q](https://github.com/jleechanorg/disk_magician/issues) | disk_snapshot.sh never covers ~/Library as a whole tree | Open — PR #16 (merged) did some Library-coverage work; re-verify scope against this bead before closing |

Not repeated here in full — see `br show <id>` on each for the complete comment-level evidence trail (multiple long comments per bead from both sidekicks and the main session).

## Confirmed mechanisms {#confirmed-mechanisms-2026-07-15}

1. **OS reboot fd-release** (flagship event, 2026-07-14T21:13:33Z): `sysctl kern.boottime` + `last reboot` + storagekitd unified-log telemetry (free 0.5GB pre-reboot → 37-39GB by T+60-64s) triple-confirmed independently. Explains RECOVERY direction only; growth-side culprit process is forensically unreachable (reboot destroyed the process table).
2. **Colima wedge → forced-restart → in-VM trim** (live-caught 2026-07-15T00:19-00:21Z): growth side evidenced by `colima_datadisk_kb` climbing monotonically over ~2.5h tracking live ephemeral CI-container count (confirmed non-crash via `docker inspect RestartCount=0`); recovery side evidenced by the datadisk shrinking 50.5GB→23.8GB→7.6GB in the same 45s window `ezgha-watchdog.log` shows a forced restart attempt. This is the recurring, general-case mechanism — matches this repo's own CLAUDE.md-documented wedge scenario.
3. **Ruled out**: APFS snapshot purge (purgeable space telemetry stayed flat <0.5GB during a 73GB swing), swapfile-as-sole-cause for the flagship event (real mechanism, wrong magnitude/window), Time Machine local snapshot thinning.

## Fixes shipped {#fixes-shipped-2026-07-15}

- `scripts/disk_snapshot.sh` / `src/disk_magician/scripts/disk_snapshot.sh`: added `dua_size_kb()` fallback inside `dir_size_kb()` — when `du -sk` times out, retry once with `dua aggregate` (parallel scanner) before surfacing null. Targets the exact keys that were intermittently going null under pressure (`codex_sessions`, `gemini_root`, `hermes`, `library_caches`, `projects`), which is what produced the earlier false "+81.7GB/day leak" alarm. Commits `74ded74` (fix), `6bb839c` (sync to packaged `src/` tree + version bump 0.2.12→0.2.13 + `uv tool install --force --reinstall` + deployed-tree diff verification). **Note:** PR #16 merged additional Library-coverage commits on top (now v0.2.18) after this session's changes — re-diff before next claiming this fallback is live in the deployed tool.

## Cleanups executed {#cleanups-executed-2026-07-15}

| Action | Before | After | Method |
|---|---|---|---|
| Colima wedge recovery | 32GiB free, datadisk 27GB | 54GiB free, datadisk 4.2GB | `scripts/cleanup_colima.sh --clean` (has built-in wedge-recovery fallback) |
| `~/projects_reference` build-artifact purge | 28.3GB | 11GB | Deleted `cmux/ghostty/.zig-cache` (13GB, Zig build cache), `cmux_ubuntu/target` (4.0GB, Rust build output), `cmux/ghostty/macos/build` (370MB, Xcode build output) — all regeneratable, zero source/history loss |
| `dk2d_evidence` 48h+ purge | 24GB | ~23.5GB (small) | Per-file mtime check (not directory mtime, which was misleading — 7/10 candidates were disqualified because the mission writes into "old-looking" top-level dirs continuously); only 2 items were genuinely all-clear (~469MB) |
| Hermes old sessions | — | ~0.1GB | `cleanup_sessions.sh --clean`, 338 JSONLs >30d, not on never-delete list |
| tmp scratch | — | ~1.5GB | `cleanup_tmp.sh --clean --large` with `LARGE_TMP_APPROVED=1` |

Net free space across the session: ~2-5GiB free (start) → 62GiB (peak, post-projects_reference cleanup) → 45GiB (current, `dk2d_evidence` regrew ~13GB and Colima churn continues). **The disk is still net-growing faster than these one-time cleanups reclaim** — the real fix is the retention-policy item below, not repeated manual sweeps.

## Work queue / open items {#work-queue--open-items-2026-07-15}

1. **`dk2d_evidence` retention policy** — no bead created yet, should be. Grew 24GB→37GB in a few hours this session alone; needs a keep-last-N-runs or auto-compress-after-N-days policy, not manual review each time. Owner: whoever runs the DK2D mission.
2. **MobileSync backup deletion — blocked on user action.** Grant Full Disk Access to **cmux** (System Settings → Privacy & Security → Full Disk Access → add cmux/"cmux DEV dev-fork") before this can be measured or touched. Likely the single largest piece of the 213.9GB TCC-blocked residual (`jleechan-w5is` accounting comment).
3. **`jleechan-rx6v` — still open.** Two live GitHub PATs remain unrotated in a plaintext log file. Highest-priority non-disk item from this whole session.
4. **`jleechan-772q`** — re-verify scope against merged PR #16 before closing; confirm whether `~/Library` coverage is now complete or still partial.
5. **`jleechan-fslj`** — re-verify current Colima/CI-runner health; last known state was recovered via the wedge-recovery run, but confirm `ezgha-watchdog` isn't still flagging degraded capacity.
6. **2026-07-13 historical swing pair** — still unexplained by either confirmed mechanism; lowest priority, no active lead.

## PR / merge state {#pr--merge-state-2026-07-15}

- No PR opened this session — direct commits to `main` (`74ded74`, `6bb839c`), matching this repo's evident convention (recent history is direct-to-main commits, not PR-gated).
- `PR #16: MERGED` (`jleechanorg/disk_magician`, "assemble disk audit fixes for deployment" + Library frontier coverage work) — merged by another concurrent session during this investigation, landed on top of this session's commits. Not re-verified line-by-line against this session's `dua-cli` fallback; flagged above as a re-verify item.
- `PR #1` ("[antig] feat: port docker/antigravity cleanups and fill tests") — still OPEN as of this session, touches `scripts/disk_snapshot.sh` with a small (+6/-3) diff; flagged by the repo's merge_train hook as a potential future conflict with this session's changes, not resolved (informational only, warn-only hook).

## Learnings pointer {#learnings-pointer-2026-07-15}

- `~/roadmap/learnings-2026-07.md` — entry `2026-07-15 — disk_magician sustained root-cause session` logs: (a) directory-mtime is an unreliable proxy for "no recent writes" on actively-written trees, always verify per-file; (b) `du` without `-x` silently crosses APFS volume boundaries and inflates figures; (c) an installed `gdu` binary may be GNU coreutils' `du` (Homebrew `g`-prefix collision), not the Go disk-analyzer tool of the same name; (d) `dua-cli` can itself hang on very-many-entry directories despite being "parallel by default" — plain `du` + `xargs -P` was more reliable for a 589-entry top-level scan.

## Roadmap pointer {#roadmap-pointer-2026-07-15}

- Appended `roadmap/activity/2026-07-15.md` with this session's summary bullet (new date — also prepended a date link to `roadmap/README.md`'s Recent activity list).

# Roll-forward — 2026-07-15 (full-SSD top-down accounting and default-diagnostic decision)

## Table of contents — full-SSD accounting

- [Executive summary](#executive-summary-full-ssd-accounting)
- [Context](#context-full-ssd-accounting)
- [Bead index](#bead-index-full-ssd-accounting)
- [Work queue](#work-queue-full-ssd-accounting)
- [PR / merge state](#pr--merge-state-full-ssd-accounting)
- [Learnings pointer](#learnings-pointer-full-ssd-accounting)
- [Roadmap pointer](#roadmap-pointer-full-ssd-accounting)

## Executive summary {#executive-summary-full-ssd-accounting}

- Reconciled the complete marketed 1 TB internal SSD at one coherent sample: 931.840 GiB physical, including 821.124 GiB Data, 17.130 GiB sealed System, 14.178 GiB Preboot, 12.003 GiB VM, 3.132 GiB main-container support/overhead, 58.786 GiB main-container free, and 5.488 GiB separate Recovery/ISC capacity.
- Recursively measured every real home root at 5 GiB granularity: 570.645 GiB total, led by 266.5 GiB of repositories/worktrees/evidence and 78.4 GiB of Codex/Gemini/Hermes/Claude state. Symlink aliases and simulator disk-image mounts were excluded from double counting.
- Named the remaining 168.552 GiB honestly as an attribution residual: `Data physical allocation - readable directory allocation`. It is not a backup, purgeable-space estimate, or cleanup target. Data has zero snapshots and Time Machine has no destination configured.
- Established the new default diagnostic shape tracked by `jleechan-rvqz`: run full top-down accounting, snapshot deltas, and safe quick-win/outlier inspection concurrently. The repo's safe dispatcher reclaimed only 116 KiB and Colima prune reclaimed 0 host bytes in this pass, demonstrating why bottom-up cleanup cannot stand in for whole-disk accounting.
- Attribution is blocked by two independent ceilings: cmux lacks effective Full Disk Access for protected Data paths, and the latest frontier stopped 995 of 1,017 unfinished nodes at its node budget. FDA/root access alone will not make the current bounded frontier exhaustive.

## Context {#context-full-ssd-accounting}

This roll-forward follows the earlier root-cause investigation in `jleechanorg/disk_magician` on `main`. The user explicitly rejected gigabyte-at-a-time cleanup reports that did not explain the full disk and required a top-down report of the complete 1 TB at 5 GiB granularity. Parallel lanes reconciled physical APFS allocation, the writable Data volume, all home roots, snapshot state, readable non-home trees, and safe cleanup candidates. Measurements were read-only except for the separately authorized safe-cleanup lane; protected Codex/Claude session stores were not touched.

## Bead index {#bead-index-full-ssd-accounting}

| Bead | Priority/status | Scope |
|---|---|---|
| [jleechan-rvqz](https://github.com/jleechanorg/disk_magician/issues/18) | P1 blocked | Make the three-lane top-down diagnostic the default first-use workflow and repo skill; blocked on auto-factory multi-repo intake. |
| `jleechan-wsbk` | P2 open | Prevent snapshot coverage collapse under disk pressure and timeouts. |
| `jleechan-772q` | P1 in progress | Close the whole-`~/Library` coverage blind spot. |
| `jleechan-7jq3` | P1 open | Add retention for rapidly growing `dk2d_evidence`. |
| `jleechan-z2ya` | P2 open | Review 28.7 GiB Messages storage, including 26.7 GiB attachments. |
| `jleechan-p2gy` | P2 open | Reduce repeated dependency-store allocation across project trees. |
| [jleechan-5c5y](https://github.com/jleechanorg/llm-wiki/issues/21) | P2 open | Repair wiki-ingest adapters so `/learn` can complete its mandatory wiki sink. |

## Work queue {#work-queue-full-ssd-accounting}

1. Unblock and implement [jleechan-rvqz](https://github.com/jleechanorg/disk_magician/issues/18). The live auto-factory only polls `jleechanorg/worldarchitect.ai`, so it did not adopt the labeled `disk_magician` issue; this is tracked by [dark-factory issue 280](https://github.com/jleechanorg/dark-factory/issues/280) and [PR 283](https://github.com/jleechanorg/dark-factory/pull/283). Once routed, the default first-use command must start three independent lanes concurrently: (a) physical APFS → Data → home top-down reconciliation with every individual bucket at least 5 GiB and a named residual, (b) coverage-validated snapshot deltas, and (c) safety-gated quick wins and obvious outliers. Reuse `scripts/disk_audit.sh`, `scripts/disk_frontier_scan.py`, and existing cleanup scripts; do not add a second scanner. The worktree-cleanup component of lane (c) is already implemented: `scripts/worktree_hygiene.sh` (jleechan-ue9w) automates the IDENTIFY/TRIAGE/CLASSIFY/DELETE steps proven manually in the 2026-07-16 `jleechan-w5is` investigation — dry-run by default, `--execute`/`--min-age` flags gate any deletion. Lane (c)'s wiring work is to invoke it (and the other existing safe-cleanup scripts) concurrently with lanes (a)/(b), not to reimplement its logic.
2. Make permissions and scan limits explicit acceptance criteria. A complete report must record the hosting app's Full Disk Access state, sudo availability, denied paths, node/time-budget exhaustion, and remaining residual. Granting FDA improves attribution but does not reclaim storage.
3. Add RED/GREEN tests for the repo-level skill and script behavior. Baseline pressure case: a new user asks why a nearly full 1 TB disk is growing; the old workflow must be shown to stop at quick cleanup candidates or partial snapshots. Green behavior must reconcile the whole disk before making cleanup claims.
4. Repair snapshot coverage through `jleechan-wsbk` and `jleechan-772q`. Snapshot deltas are evidence only when coverage is valid; null/timeouts and changing coverage must not be described as physical growth or reclaim.
5. Address known real growth separately: `jleechan-7jq3` for evidence retention, `jleechan-z2ya` for Messages attachments review, and `jleechan-p2gy` for repeated dependencies. Keep session stores on the never-delete list.
6. After implementation, run package-tree sync, version bump, forced uv-tool reinstall, deployed-tree verification, and a first-use smoke run. The 35-minute launchd snapshot consumer uses the packaged copy, not repo-root code.
7. Fix [jleechan-5c5y](https://github.com/jleechanorg/llm-wiki/issues/21). The Codex adapter currently passes an unsupported flag, while the Claude adapters returned without producing required artifacts or a final actionable error. `/learn` must not silently bypass this sink.

## PR / merge state {#pr--merge-state-full-ssd-accounting}

- No PR exists yet for [jleechan-rvqz](https://github.com/jleechanorg/disk_magician/issues/18). Auto-factory adoption is **BLOCKED** because the live intake polls one configured repository and does not see `disk_magician`; no worker or PR was spawned. Evidence and blocker comment: [issue comment](https://github.com/jleechanorg/disk_magician/issues/18#issuecomment-4987222786). No merge action is recommended.

## Learnings pointer {#learnings-pointer-full-ssd-accounting}

- `/Users/jleechan/roadmap/learnings-2026-07.md` — entry `2026-07-15 — Full-disk diagnosis must run top-down and bottom-up concurrently`.

## Roadmap pointer {#roadmap-pointer-full-ssd-accounting}

- Appended `/Users/jleechan/projects_other/disk_magician/roadmap/activity/2026-07-15.md`. The date already existed in `roadmap/README.md`, so no duplicate README link was added.

# Roll-forward — 2026-07-16 (100GB-reclaim swarm, crash-resume, regrowth root-cause cross-reference)

## Table of contents {#toc-2026-07-16-reclaim}

- [Executive summary](#executive-summary-2026-07-16-reclaim)
- [Context](#context-2026-07-16-reclaim)
- [Bead index](#bead-index-2026-07-16-reclaim)
- [Work queue](#work-queue-2026-07-16-reclaim)
- [Learnings pointer](#learnings-pointer-2026-07-16-reclaim)
- [Roadmap pointer](#roadmap-pointer-2026-07-16-reclaim)

## Executive summary {#executive-summary-2026-07-16-reclaim}

- Reclaimed ~38.8 GiB total against the user's "save another 100GB" request via fully verified, reversible deletions (git-ignored/untracked cache dirs, worktrees with merged PRs and zero local changes, worktrees whose commits were already captured on other remote branches). Zero data loss. Free space moved 83.0GiB -> 111.4GiB in the first pass.
- Ran a 4-lane `/swarm` sweep (dark-factory, `~/.hermes`, ez-gh-actions+merge_train+disk_magician, worldarchitect.ai 87-candidate review) using in-session Agent Team teammates. The full unscoped `scripts/worktree_hygiene.sh --min-age 14` run against all 375 worldarchitect.ai worktrees hung twice (once in the swarm lane, once again in the prior session) — sequential real `git push`+`gh pr list` per candidate does not finish in reasonable time at this scale. Root-caused and worked around by scoping the network check to only the "ahead-of-main but locally clean" subset (32 candidates), where a merge/close verdict actually changes the outcome; the dirty/diverged subset needs human review regardless of network calls, so skipping the full run there costs nothing.
- Session crashed (real reboot — `/tmp` wiped, cmux surface_ref changed `surface:2`->`surface:1`). Resumed cleanly: confirmed continuity via the session's own JSONL transcript, restarted the `/cmux-goal` Stop-hook on the new surface, continued via the goal condition directly.
- **Regrowth observed**: free space dropped 111.4GiB -> 88.0GiB in the session-crash gap (a few hours). This is NOT a new mechanism — it is the same already-tracked `~/projects`/`.worktrees` churn pattern. Cross-referenced against existing beads (see below) rather than creating a duplicate; posted this session's numbers as a comment onto the existing ledger bead `jleechan-mf2b` instead of re-diagnosing from scratch.
- Resolved one long-standing ambiguity: `~/.pyenv/versions/3.11.10` (3.9GiB) is NOT orphaned — it backs a live `devpi-server` launchd daemon invoked by direct binary path (bypassing the `pyenv` shim, which is why `pyenv versions` falsely reported "not installed"). Do not delete.
- Filed 9 new beads for genuinely orphaned non-trivial work discovered during worktree triage (not root-cause/regrowth beads — individual pieces of uncaptured work): `jleechan-g54u`, `trt2`, `pnxs`, `mxax`, `by8p`, `mu42`, `dlpr`, `6s8p`, `8t49`.

## Context {#context-2026-07-16-reclaim}

Continuation of the 2026-07-12 through 2026-07-15 root-cause work in this same doc. This section covers only the 2026-07-16 "another 100GB" reclaim push, the crash/resume, and the explicit user question "did we make beads/roadmap already for regrowth?" — answered by cross-referencing existing coverage rather than creating parallel tracking.

## Bead index {#bead-index-2026-07-16-reclaim}

| Bead | Priority/status | Scope |
|---|---|---|
| `jleechan-mf2b` (no GitHub issue — see `br show jleechan-mf2b`) | P1 BLOCKED | Attribution/reclaim ledger for `~/projects`+`.worktrees` growth — pre-existing, closest match to today's regrowth observation; updated with today's numbers as a comment, not duplicated. |
| `jleechan-bd-vgyk-7f08` (no GitHub issue — see `br show jleechan-bd-vgyk-7f08`) | P1 OPEN | The actual structural fix: port upstream AO lifecycle ownership so managed worktrees/temp resources tear down on session exit. This is what would stop the regrowth at the source; manual sweeps (today's work) cannot outrun it. |
| `jleechan-dqiz` | P1 OPEN | Adjacent but distinct: `/private/tmp` scratch clone teardown gap, not `~/projects` worktree churn. |
| `jleechan-g54u`, `trt2`, `pnxs`, `mxax`, `by8p`, `mu42`, `dlpr`, `6s8p`, `8t49` | P2-P3 OPEN | Individual orphaned-work findings from today's worktree triage (not regrowth-root-cause beads). |

## Work queue {#work-queue-2026-07-16-reclaim}

1. The next real gain is **jleechan-bd-vgyk-7f08**, not another manual sweep — AO lifecycle teardown on session exit is what stops `~/projects`/`.worktrees` from regrowing ~10-20GiB/hour. Manual `worktree_hygiene.sh` sweeps are a valid stopgap but structurally cannot win against live churn.
2. `jleechan-mf2b` remains BLOCKED on missing 7/30-day child-level snapshot keys for delta reconstruction — unrelated to today's manual findings, still needs the snapshot schema fix to unblock properly.
3. Fix `scripts/worktree_hygiene.sh`'s full-run performance: an unscoped run over 300+ worktrees with real `git push`+`gh pr list` per candidate hangs/times out in practice (hit twice now — 2026-07-15 and 2026-07-16). Either parallelize the network-check phase, or default `--min-age` runs to the "ahead-but-clean" scoping used manually today (skip push/PR-check entirely for candidates already known-dirty, since the network call can't change their verdict).
4. Review the remaining 50 dirty / 7 diverged worldarchitect.ai worktree candidates — these need human judgment (uncommitted/untracked changes), not automation. Not actioned this session.
5. Messages attachment dedup (~1.74GiB, dry-run script from 2026-07-15 lost in the 2026-07-16 crash) — low priority relative to the structural AO-lifecycle fix; regenerate only if reclaim is urgent again.

## Learnings pointer {#learnings-pointer-2026-07-16-reclaim}

- `~/roadmap/learnings-2026-07.md` — entry to be added: "2026-07-16 — worktree_hygiene.sh full-run performance ceiling; pyenv 3.11.10 false-orphan (live devpi-server); regrowth is already-tracked, cross-reference before re-diagnosing."

## Roadmap pointer {#roadmap-pointer-2026-07-16-reclaim}

- Appended this section to `roadmap/nextsteps-2026-07-12-disk-magician-root-cause.md` (existing rolling doc, per this repo's append-don't-fragment convention). `roadmap/activity/2026-07-16.md` not yet created — pending.

> ⚠️ **CORRECTED BELOW**: An external review (2026-07-17) found this section's headline claim false — the displayed ≥5GiB bucket table (sums to 262.57 GiB) was compared against a residual computed from a *different* number (`measured_total_kb`, 206.85 GiB), so the equation only "balanced" by construction, not because the bucket table itself reconciles (this is exactly bug `jleechan-df3k`, which this section documents but then contradictorily claims to satisfy). Ground truth was also already stale by the time this was read. A superseding, corrected measurement is in the next roll-forward section below — treat everything in THIS section as a historical snapshot of a flawed intermediate result, not a current-truth report.

# Roll-forward — 2026-07-16 part 2 (5GiB top-down breakdown swarm + worktree_hygiene.sh perf fix) — SUPERSEDED, see correction notice above

## Table of contents {#toc-2026-07-16-part2}

- [Executive summary](#executive-summary-2026-07-16-part2)
- [Context](#context-2026-07-16-part2)
- [Bead index](#bead-index-2026-07-16-part2)
- [5GiB top-down breakdown](#5gib-top-down-breakdown-2026-07-16)
- [Work queue](#work-queue-2026-07-16-part2)
- [PR / merge state](#pr--merge-state-2026-07-16-part2)
- [Learnings pointer](#learnings-pointer-2026-07-16-part2)
- [Roadmap pointer](#roadmap-pointer-2026-07-16-part2)

## Executive summary {#executive-summary-2026-07-16-part2}

- Fixed `scripts/worktree_hygiene.sh`'s full-run hang on 300+ candidates. PR [jleechanorg/disk_magician#20](https://github.com/jleechanorg/disk_magician/pull/20) **MERGED** (SHA `46c75cd`), deployed to production, beads `jleechan-q912` (no GitHub issue — see `br show jleechan-q912`) and `jleechan-20gm` (no GitHub issue — see `br show jleechan-20gm`) closed.
- Ran the repo's own three-lane default diagnostic (`scripts/disk_diagnostic.sh`'s constituent scripts, run individually via a swarm of Agent Team lanes) to attempt a 5GiB-granularity top-down breakdown. The default node budget (500) exhausted before subdividing `/Users`; the supplementary `--max-nodes 8000` run remained partial at 25.38% coverage and **did not satisfy** the accounting contract because its displayed buckets and residual used different bases. Filed [jleechan-sdlv / issue 22](https://github.com/jleechanorg/disk_magician/issues/22) and [jleechan-df3k / issue 23](https://github.com/jleechanorg/disk_magician/issues/23).
- lane-history's 7-day regression check found no size regressions (net -7 GiB improvement) but flagged the nightly snapshot mechanism's coverage collapsing 50.7%→5.6% — logged onto the existing bead `jleechan-wsbk` (no GitHub issue — see `br show jleechan-wsbk`), not a new issue.
- lane-quickaudit flagged ~39.1 GiB of "safe" quick-win candidates; independently verified the Colima 35.6 GiB figure is real allocated disk (not a sparse-file artifact) but reclaiming it on the host needs `colima stop/start` + in-VM `fstrim` per this repo's own CLAUDE.md, not just `cleanup_colima.sh --clean` alone — flagging this nuance so a future session doesn't over-claim reclaim from a docker-prune-only pass.
- Operational finding, hit by two independent agents (me and a swarm lane) in this session and once in the prior session: `disk_frontier_scan.py` does not stream progress — it batches all output at the end of its wall-clock budget. Retrying because "there's been no output for N seconds" produces duplicate concurrent scans racing on the same output file, which is itself the actual cause of apparent hangs. Worth a `README`/`--help` note in the script itself (not filed as a bead — low severity, operational-only).

## Context {#context-2026-07-16-part2}

Continuation of the same 2026-07-16 session as the "100GB-reclaim swarm" roll-forward earlier in this doc. This section covers the `/swarm`-orchestrated worktree_hygiene.sh perf fix (via an isolated `/newb` worktree, merged with `/advice` approval) and the subsequent 5GiB top-down breakdown swarm requested directly by the user ("its suppose to be in 5G increments... use swarm to make report in parallel").

## Bead index {#bead-index-2026-07-16-part2}

| Bead | Priority/status | Scope |
|---|---|---|
| `jleechan-q912` | P1 CLOSED | worktree_hygiene.sh full-run hang — fixed, merged in PR #20 |
| `jleechan-20gm` | P2 CLOSED | `.git` pointer file exclusion gap — fixed as a side effect of #20 |
| `jleechan-sdlv` | P1 OPEN | disk_frontier_scan.py default 500-node budget exhausted before reaching `/Users` |
| `jleechan-df3k` | P2 OPEN | disk_frontier_scan.py `granularity_buckets` vs `measured_total_kb` 55.7 GiB internal accounting gap |
| `jleechan-wsbk` | P2 OPEN | Snapshot coverage collapse (updated with 2026-07-16 data point: 50.7%→5.6%) |

## 5GiB top-down breakdown {#5gib-top-down-breakdown-2026-07-16}

**Captured Data-volume sample (2026-07-16T20:13:20Z; not the complete physical-container equation):** 815.095539 GiB allocated to Data. The corrected whole-container equation is in the superseding section below.

**Invalid intermediate measurement:** `python3 scripts/disk_frontier_scan.py --granularity-gib 5 --max-nodes 8000 --output-default` produced a partial run: 25.38% coverage, 4,293 unfinished paths, and a 480-second wall-clock exhaustion. Its hidden equation `206.850929 measured + 608.244610 residual = 815.095539 Data` balances by construction, but the displayed bucket rows total 262.570343 GiB. Therefore `262.570343 displayed + 608.244610 residual = 870.814953 GiB`, which exceeds Data by 55.719414 GiB. The numeric purgeable value of zero means unavailable, not proven zero. Raw evidence SHA-256: `d3086ffb5a02c67f074c0ba2061f15dd3696cc68d68f40d491d7a31ec15f0b2e` (`/tmp/frontier_5g_scan_v2.json`).

**≥5 GiB buckets, verified non-overlapping (no path is a prefix of another in this list):**

| GiB | Path |
|---|---|
| 38.26 | `~/.colima/_lima` |
| 28.89 | `~/.codex` |
| 22.57 | `/Applications` |
| 19.18 | `~/dk2d_evidence` |
| 17.83 | `~/.worktrees` |
| 17.09 | `~/projects_other` |
| 15.12 | `~/.hermes` |
| 13.77 | `~/Pictures/Photos Library.photoslibrary` |
| 12.94 | `~/project_worldaiclaw` |
| 11.19 | `~/projects_reference` |
| 8.50 | `/System/Library/AssetsV2/...iOSSimulatorRuntime` |
| 8.21 | `/opt/homebrew/Cellar` |
| 7.79 | `~/.ao` |
| 7.16 | `~/.claude/projects` (never-delete list) |
| 6.32 | `~/repos` |
| 6.23 | `/opt/homebrew/lib` |
| 5.79 | `/Library/Developer` |
| 5.43 | `~/.local/share` |
| 5.29 | `/private/tmp/worldarchitect.ai` |
| 5.03 | `~/.lima/colima` |

**Sibling APFS volumes** (separate from the Data volume, not double-counted into the table above): Macintosh HD (System) 17.13 GiB, Preboot 14.18 GiB, Recovery 2.19 GiB, Update 0.75 GiB, VM 7.00 GiB — 41.25 GiB total.

**Known-real but not yet resolved to named sub-buckets:** `~/projects` (~119 GiB per an earlier manual `du -xsk` cross-check this session) and `~/Library` (~85.5 GiB) are inside the 608.24 GiB residual — the frontier scanner descended into both but ran out of wall-clock time mid-subdivision (`~/projects` alone fanned into 100+ still-unfinished worktree subdirectories). They are real and not lost, just not yet broken into named ≥5GiB pieces by this specific run.

**Quick-win candidates** (from `disk_audit.sh --no-history`, unexecuted, needs verification before trusting the full amount): Colima VM disk ~35.6 GiB (real allocated size, confirmed via sparse-aware `du -k` cross-check — but reclaiming on the host needs `colima stop/start` + in-VM `fstrim`, not just `cleanup_colima.sh --clean`'s docker/image prune), code_sign_clone caches ~3.5 GiB (`cleanup_code_sign_clones.sh --clean`, requires `CODE_SIGN_CLONES_APPROVED=1` + quitting apps first), Codex Sessions ~18.3 GiB (flagged for manual review only — protected by the never-delete list, not auto-purgeable).

**Worktree hygiene preview** (`worktree_hygiene.sh --skip-push --skip-gh`, 120s timeout, partial — 75 of an unknown larger total evaluated): 1 SAFE (`~/.worktrees/agent-orchestrator/ao-lifecycle`), 41 PRESERVE (young), 33 NEEDS-REVIEW (unpushed-ahead/dirty/untracked).

## Work queue {#work-queue-2026-07-16-part2}

1. Fix [jleechan-df3k / issue 23](https://github.com/jleechanorg/disk_magician/issues/23) first — reconcile `granularity_buckets` against the accepted leaf ledger so displayed buckets, sub-5GiB tail, residual, and Data allocation share one base.
2. Fix [jleechan-sdlv / issue 22](https://github.com/jleechanorg/disk_magician/issues/22) — prioritize `/Users` and other high-value roots within a bounded default, rather than relying only on a larger node limit.
3. Investigate `jleechan-wsbk` (no GitHub issue — see `br show jleechan-wsbk`)'s latest data point — snapshot coverage crash to 5.6% on 2026-07-16 needs root-causing (likely `projects*` du timeout under concurrent AO churn, matching the bead's existing framing).
4. Re-run `disk_frontier_scan.py --max-nodes 8000` (or higher) scoped specifically to `~/projects` and `~/Library` once #1 is fixed, to resolve the two known-but-unnamed big buckets into real sub-attribution.
5. Structural fix still outstanding from earlier today: `jleechan-bd-vgyk-7f08` (AO lifecycle teardown) — the actual fix for the underlying disk-churn pattern that keeps re-filling every bucket this report names.

## PR / merge state {#pr--merge-state-2026-07-16-part2}

- [jleechanorg/disk_magician#20](https://github.com/jleechanorg/disk_magician/pull/20) — **MERGED** (SHA `46c75cd`, 2026-07-16T19:08:20Z).

## Learnings pointer {#learnings-pointer-2026-07-16-part2}

- `~/roadmap/learnings-2026-07.md` — entry `2026-07-16 — disk_frontier_scan.py doesn't stream progress; retrying on "no output" causes duplicate concurrent scans`.

## Roadmap pointer {#roadmap-pointer-2026-07-16-part2}

- Appended to `roadmap/activity/2026-07-16.md` (same-date file, no README re-prepend needed).

---

# Roll-forward — 2026-07-17 correction and concrete next steps

## Table of contents {#toc-2026-07-17-correction}

- [Executive summary](#executive-summary-2026-07-17-correction)
- [Context and evidence contract](#context-and-evidence-contract-2026-07-17)
- [Bead index](#bead-index-2026-07-17)
- [Corrected top-down report](#corrected-top-down-report-2026-07-17)
- [Concrete work queue](#concrete-work-queue-2026-07-17)
- [PR and issue state](#pr-and-issue-state-2026-07-17)
- [Learnings pointer](#learnings-pointer-2026-07-17)
- [Roadmap pointer](#roadmap-pointer-2026-07-17)

## Executive summary {#executive-summary-2026-07-17-correction}

- The prior frontier table is retained only as invalid bug evidence. Its visible rows plus residual exceed Data by **55.719414 GiB**.
- The captured whole-container equation balances: **815.095539 GiB Data + 41.247948 GiB sibling volumes + 0.192493 GiB APFS overhead + 69.815739 GiB free = 926.351719 GiB**.
- A supplementary APFS-native root allocation pass names the previously unexplained space, especially `/private/var/dirs_cleaner` (**165.011 GiB**) and `/.Spotlight-V100` (**17.780 GiB**). Its root rollup needs only a **1.319 GiB** cross-scan/shared-allocation adjustment, below the user's 50 GiB unknown ceiling.
- The default-diagnostic feature bead `jleechan-rvqz` must be open again: the proof used to close it did not meet its own additive-ledger acceptance criterion. Scanner correctness precedes another coverage run or cleanup ranking.

## Context and evidence contract {#context-and-evidence-contract-2026-07-17}

The container equation and the supplementary root allocation are distinct captured samples; they are shown separately so live AO/Colima churn is not hidden by mixing timestamps. A future PASS requires one atomic run whose displayed `>=5 GiB` rows, explicit sub-5GiB tail, residual, Data allocation, sibling volumes, overhead, and free space all reconcile. `balanced: true` is insufficient unless it validates the displayed report, and unavailable purgeable data must remain `unknown`, not numeric zero.

Durable evidence anchors for the rejected frontier run:

- command: `python3 scripts/disk_frontier_scan.py --granularity-gib 5 --max-nodes 8000 --output-default`
- captured: `2026-07-16T20:13:20Z`; elapsed 481 seconds; 4,649 nodes processed; 4,293 unfinished
- raw file: `/tmp/frontier_5g_scan_v2.json`; SHA-256 `d3086ffb5a02c67f074c0ba2061f15dd3696cc68d68f40d491d7a31ec15f0b2e`
- arithmetic: `262.570343 displayed + 608.244610 residual - 815.095539 Data = 55.719414 GiB overage`

## Bead index {#bead-index-2026-07-17}

| Bead | Status | Concrete scope |
|---|---|---|
| `jleechan-rvqz` / [issue 18](https://github.com/jleechanorg/disk_magician/issues/18) | P1 OPEN | Restore the default diagnostic's real whole-disk additive contract; prior close proof was invalid. |
| `jleechan-df3k` / [issue 23](https://github.com/jleechanorg/disk_magician/issues/23) | P1 OPEN | Make displayed buckets derive from the same accepted leaf ledger as measured total and residual. |
| `jleechan-sdlv` / [issue 22](https://github.com/jleechanorg/disk_magician/issues/22) | P1 OPEN | Make the bounded default reach `/Users` and other high-value roots. |
| `jleechan-wsbk` | P2 OPEN | Snapshot runtime is recovered; remaining concrete gap is the 20-second `~/projects` timeout. |
| `jleechan-772q` | P1 IN PROGRESS | Improve byte coverage of the enumerated Library frontier and keep TCC denials explicit. |
| `jleechan-ue9w` | CLOSED | Worktree hygiene workflow shipped; performance/correctness follow-up landed in PR 20. |
| `jleechan-q912`, `jleechan-20gm` | CLOSED | Merged and deployed through [PR 20](https://github.com/jleechanorg/disk_magician/pull/20). |

## Corrected top-down report {#corrected-top-down-report-2026-07-17}

### Captured physical-container equation

| Allocation | GiB |
|---|---:|
| Data volume | 815.095539 |
| System, Preboot, Recovery, Update, and VM sibling volumes | 41.247948 |
| APFS container overhead/shared allocation | 0.192493 |
| Free | 69.815739 |
| **Physical container total** | **926.351719** |

### Supplementary Data root allocation

| Data root or adjustment | GiB |
|---|---:|
| `/Users` | 545.535 |
| `/private` | 187.011 |
| `/System` | 23.750 |
| `/Applications` | 18.377 |
| `/.Spotlight-V100` | 17.780 |
| `/opt` | 16.102 |
| `/Library` | 8.241 |
| Smaller Data roots | 0.193 |
| Child-root rollup | 816.989 |
| Cross-scan/shared-allocation adjustment | -1.319 |
| **APFS-native Data baseline** | **815.670** |

The **1.319 GiB adjustment** is the remaining attribution uncertainty in this rollup. It is not labeled reclaimable. This table durably preserves the supplementary lane's exact summary, including the two dominant allocations omitted by the frontier table; its raw APFS-native output was not persisted, so the atomic acceptance rerun in the work queue remains mandatory.

### `/private` drilldown

| Path | GiB |
|---|---:|
| `/private/var/dirs_cleaner` | 165.011 |
| `/private/tmp` | 9.201 |
| `/private/var/folders` | 5.524 |
| `/private/var/db` | 5.347 |
| Remaining `/private` entries | 1.929 |
| **Rounded subtotal** | **187.012** |

### Home ledger at 5 GiB granularity

The exhaustive home pass measured 601 of 601 direct children with zero command errors: **539.969 GiB** total. Rows are rounded, so their displayed sum can differ by 0.001 GiB.

| Home child | GiB |
|---|---:|
| `~/projects` | 119.451 |
| `~/Library` | 85.547 |
| `~/.colima` | 35.644 |
| `~/.codex` | 28.888 |
| `~/.gemini` | 23.181 |
| `~/dk2d_evidence` | 19.181 |
| `~/.worktrees` | 17.828 |
| `~/projects_other` | 17.086 |
| `~/.hermes` | 15.107 |
| `~/Pictures` | 13.762 |
| `~/project_worldaiclaw` | 12.942 |
| `~/projects_reference` | 11.185 |
| `~/.local` | 9.914 |
| `~/.claude` | 9.176 |
| `~/.ao` | 7.787 |
| `~/repos` | 6.323 |
| `~/.nvm` | 5.625 |
| `~/.lima` | 5.027 |
| 583 children below 5 GiB each | 96.316 |
| **Home total from raw ledger** | **539.969** |

Raw home-ledger evidence was captured in `/tmp/home_top_level_ledger_20260716.tsv` (SHA-256 `61d6b1ee4345dfb0a4c83244e868344915055fa957cf234e54ab36dfb240cca0`) with drilldowns in `/tmp/home_ge5_drilldown_20260716.tsv` (`4da7ffd476c5d670974150af4a15648b51bbd2a424b33b63ecd20b4e8c944217`) and `/tmp/home_ge5_second_drilldown_20260716.tsv` (`7be2da2ec3be35550b377dfdc2c50a7002ca95baf35670718bb0d80a457d66b1`).

**Durable copies** (the `/tmp` originals are volatile and will not survive reboot/cleanup): `roadmap/evidence/home_top_level_ledger_20260716.tsv`, `roadmap/evidence/home_ge5_drilldown_20260716.tsv`, `roadmap/evidence/home_ge5_second_drilldown_20260716.tsv` — hashes independently re-verified by a second session before commit; the top-level ledger's 601 OK rows sum to 539.969 GiB with zero errors, matching this section's claim exactly, and the physical-container equation (815.095539 + 41.247948 + 0.192493 + 69.815739 = 926.351719 GiB) was independently recomputed and confirmed.

## Concrete work queue {#concrete-work-queue-2026-07-17}

1. **Fix accounting correctness first — `jleechan-df3k`.** Build displayed buckets only from accepted, non-overlapping ledger leaves; add a sub-5GiB tail; fail closed unless `displayed + tail + residual = Data` in raw KiB.
2. **Fix default traversal — `jleechan-sdlv`.** Prioritize `/Users`, `/private`, Spotlight, `/opt`, and `/Library` within the bounded default. Raising the node cap alone is not sufficient.
3. **Revalidate `jleechan-rvqz` end to end.** Re-run the normal three-lane entrypoint and persist one timestamped physical-container/Data report. Acceptance: no table/base mismatch, explicit permission and budget frontier, and at most 50 GiB truly unknown.
4. **Narrow snapshot completeness — `jleechan-wsbk`.** The latest authoritative snapshot (`2026-07-17T00:13:41Z`) recovered to 49.2% coverage, measured 76/77 configured paths in 139 seconds, did not exhaust the total budget, and timed out only on `projects`. Implement an adaptive or cached strategy for that path.
5. **Keep Library permission truth separate — `jleechan-772q`.** Improve sizing completeness without treating TCC-protected Mail/Messages paths as numeric zero.
6. **Only after steps 1–5, rank cleanup.** Run dry-run safety-gated quick wins beside the trusted report; do not present them as the explanation of capacity.

## PR and issue state {#pr-and-issue-state-2026-07-17}

- [Issue 18](https://github.com/jleechanorg/disk_magician/issues/18) — reopened because the shipped default diagnostic failed its additive-report acceptance criterion.
- [Issue 22](https://github.com/jleechanorg/disk_magician/issues/22) — open, default frontier budget/traversal defect.
- [Issue 23](https://github.com/jleechanorg/disk_magician/issues/23) — open, displayed-bucket accounting defect.
- [PR 20](https://github.com/jleechanorg/disk_magician/pull/20) — merged at `46c75cd1f580a6ec1ba674bd7a5cae2522762f3d`; worktree-hygiene beads remain correctly closed.

## Learnings pointer {#learnings-pointer-2026-07-17}

- `/Users/jleechan/roadmap/learnings-2026-07.md` — appended the additive-report acceptance rule and correction provenance.

## Roadmap pointer {#roadmap-pointer-2026-07-17}

- `/Users/jleechan/projects_other/disk_magician/roadmap/activity/2026-07-16.md` — corrected the same-session activity entry; the date was already indexed, so no duplicate README prepend was required.
