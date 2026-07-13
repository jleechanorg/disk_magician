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
