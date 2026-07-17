# disk_magician roadmap

## Recent activity (by day)

- [2026-07-17](activity/2026-07-17.md) — Root-caused Colima's regrowth via the 1-min fast-swing observer log: 33.20→43.44 GiB in a 90-min window from CI-runner churn, while the automated trim-guard was broken (`shlock` stale-lock detection failure, confirmed reproducible). Manually recovered (+38.4 GiB), fixed the guard, filed [jleechan-wy3s](https://github.com/jleechanorg/disk_magician/issues/24) for both bugs. Also cut `~/dk2d_evidence` to a strict 2-day retention per user request (57→1 dirs, −19 GiB).
- [2026-07-16](activity/2026-07-16.md) — ~38.8GiB reclaimed; worktree-hygiene performance fix merged; the first 5GiB frontier report was rejected for a 55.719414GiB displayed-ledger mismatch. Corrected container/Data rollups and concrete queue persisted; `jleechan-rvqz` and issue 18 reopened, with `jleechan-df3k` now P1. Roll-forward in [nextsteps-2026-07-12-disk-magician-root-cause.md](nextsteps-2026-07-12-disk-magician-root-cause.md) (2026-07-17 correction section).
- [2026-07-15](activity/2026-07-15.md) — Sustained root-cause session (sidekick + swarm + ultracode): two mechanisms confirmed with live evidence (reboot fd-release, Colima wedge/trim cycle), rigorous 834.65GiB disk accounting with 213.9GiB gap fully named, `dua-cli` fallback shipped+deployed, 22GiB+ freed via Colima recovery + build-artifact cleanup, live credential leak found and filed. Roll-forward in [nextsteps-2026-07-12-disk-magician-root-cause.md](nextsteps-2026-07-12-disk-magician-root-cause.md) (2026-07-15 section).
- [2026-07-14](activity/2026-07-14.md) — Disk pressure recheck and correction: the early ~186 GiB Colima figure summed sparse apparent capacities, not allocated bytes; snapshot residual deltas are coverage/accounting changes, not physical reclaim. Live evidence instead ties rapid growth to one-shot ezgha runner replacement, while the largest recovery remains open pending a direct catch. Roll-forward in [nextsteps-2026-07-12-disk-magician-root-cause.md](nextsteps-2026-07-12-disk-magician-root-cause.md) (2026-07-14 section).
- [2026-07-12](activity/2026-07-12.md) — Disk crisis recovery, four leak-class root causes, prevention plan (/secondo)
  - [nextsteps-2026-07-12-disk-magician-root-cause.md](nextsteps-2026-07-12-disk-magician-root-cause.md) — open action queue + owner matrix for all disk beacons
  - Cleanup modes and approvals are documented in that nextsteps doc: SAFE/REVIEW/MANUAL classes + env-gate map.

## Recent activity (rolling)

- 2026-07-06 (evening) — Post-#8 portability: README launchd docs, disk_history backup fallback, find_stale_large_dirs.sh; closed jleechan-p1cw.

- 2026-07-06 (Phase 2) — Gemini centralization + host remediation (~116 Gi reclaimed):
  - **Gemini dedup**: `symlink-shared-gemini.sh --clean` — 819 sessions symlinked; `~/.ao-sessions` 70G → 2.0G (~68 Gi). PR [disk_magician#8](https://github.com/jleechanorg/disk_magician/pull/8) OPEN; spawn fix [agent-orchestrator#751](https://github.com/jleechanorg/agent-orchestrator/pull/751) OPEN.
  - **Colima second pass**: orphaned volumes + `fstrim`; `~/.colima/_lima` 59G → 23G (~36 Gi additional).
  - **AO runtime**: `ao-update` on `main` (#746 Playwright symlink deployed). #751 gemini symlink pending merge + second update.
  - **Launchd loaded**: `com.jleechan.disk-magician-{colima-prune,playwright-dedup,gemini-dedup}` (Sun 03:45 / 04:15 / 04:30).
  - **Disk**: Data volume ~123 Gi free (86%). Beads: `jleechan-cwgj` open (deploy); `jleechan-emnx` closed.
  - Nextsteps: `~/roadmap/nextsteps-2026-07-06-disk-magician-four-causes.md`.

- 2026-07-06 — Four root-cause disk growth cleanup (short-term + long-term):
  - **Live reclaim**: Data volume free 37Gi → 106Gi (~69Gi). Playwright dedup 11.1GB (93 ao-* caches symlinked); /private/tmp −6GB; Colima orphaned org-runner-* volumes removed + `fstrim` (_lima 61G → 11G).
  - **New**: `scripts/cleanup_colima.sh` (builder/image prune, orphaned volume sweep, `colima ssh -- sudo fstrim -av`).
  - **Wired**: `disk_audit.sh` clean-all gates for `AO_PLAYWRIGHT_DEDUP_APPROVED`, `VENV_RECLAIM_APPROVED`, `DOCKER_VOLUMES_APPROVED`; Colima + Playwright findings in audit.
  - **Launchd**: `com.jleechan.disk-magician-colima-prune` (Sun 03:45), `com.jleechan.disk-magician-playwright-dedup` (Sun 04:15).
  - **Bead closed**: `jleechan-qoss` (Playwright dedup). Still open: `jleechan-dp2x`, `jleechan-p2gy`.
  - Nextsteps: `~/roadmap/nextsteps-2026-07-06-disk-magician-four-causes.md`.

- 2026-07-05 — Multi-day regrowth fixed structurally:
  - Antigravity plugin patch: PR jleechanorg/agent-orchestrator#746 (AO_ORIGINAL_HOME env + Playwright cache symlink).
  - reapStaleSessions loop: PR jleechanorg/agent-orchestrator#747.
  - user_scope cleanup-ao-sessions.sh (12444 B, in `origin/main` d8ae86b9f): added to sparse-checkout; previously-missing launchd plist body.
  - scripts/set_gc_worktree_prune.sh: NEW. Walks 7 repos, sets gc.worktreePruneExpire=7.days.ago.
  - scripts/cleanup_apfs_snapshots.sh: parser hardened for `com.apple.os.update-<64-hex-UUID>` via XID-ordering fallback (active-root XID safety invariant).
  - scripts/cleanup_agent_artifacts.sh: 3 new TARGETS (jleechanclaw, antigravity-ide, antigravity-browser-profile) → ~6 GB reclaimed live.
  - scripts/cleanup_sessions.sh: hermes cron/output (14d) + ~/.hermes/sessions (30d) targets.
  - scripts/cleanup_dev_caches.sh: claude-cli-nodejs + go-build added.
  - scripts/vacuum_hermes_state.sh: NEW + plist com.jleechan.disk-magician-hermes-vacuum (Sun 04:30).
  - scripts/disk_snapshot.sh: tiny fix (containers_captured `|| true`) preventing malformed JSON.
  - ~/.hermes_prod/agent-orchestrator.yaml: 6 entries flipped pruneWorktrees false→true (pre-applied for #747 merge).
  - 50 orphan worktree dirs (>7d, broken .git pointer) reclaimed ~5 GB; 42 with real work preserved.
  - Live net: ~+28 Gi free; partially offset by 19 Gi in-session Antigravity regrowth (vector fixed structurally; cleanup queued behind launchd plist).

- 2026-07-03 — Venv/session dedup pass: reclaimed ~19GB total:
  - `disk_magician.sh clean` (DISK_MAGICIAN_AUTO_CLEAN=1): ~3.4GB (dev caches, tmp, supervisor logs).
  - `scripts/symlink-shared-venvs.sh --clean` + new `scripts/reclaim_worktree_venvs.sh`: 13.3GB across 18+6 `~/projects` worktree venvs, backup-then-symlink pattern (`.bak.<timestamp>`, verify, delete backup).
  - Cleaned AO orchestrator session `jc-1933` (jleechanclaw project, confirmed dead process): removed 48 nested sub-worker config/cache homes (2.5G, zero git risk) + 15 of 21 nested git worktrees (confirmed clean + fully pushed), preserving 6 with real unpushed work.
  - Filed a fixed parser bug in `cleanup_apfs_snapshots.sh` (now uses `diskutil apfs listSnapshots` for the `com.apple.os.update-*` UUID form) and a weekly launchd plist, but the actual delete needs `sudo` (launchd runs unprivileged) — unresolved, `jleechan-dp2x`.
  - Found a new bug: `disk_snapshot.sh` can emit malformed JSON (`containers_captured` multi-line value) that silently breaks `disk_magician.sh audit` — `jleechan-emnx`.
  - Follow-up beads/issues: `jleechan-qoss` (Playwright cache dedup across AO sessions, ~3GB, NOT yet actioned — user has a standing leave-sessions-alone policy), `jleechan-80wj` (generalize the jc-1933-style nested-orchestrator sweep), `jleechan-p2gy` (Node `node_modules` pnpm migration, 6.2G), `jleechan-emnx`, `jleechan-dp2x`.
  - Nextsteps doc: `~/roadmap/nextsteps-2026-07-03-ao-session-dedup.md`.

- 2026-06-27 — Disk cleanup recovery and harness hardening:
  - Reclaimed non-worktree disk usage from `/private/tmp`, Ollama model blobs, Docker unused images, and Xcode DerivedData.
  - Added explicit cleanup targets for Docker, Ollama, and Xcode.
  - Gated worktree deletion behind `WORKTREE_APPROVED=1`.
  - Gated large `/private/tmp` cleanup behind `LARGE_TMP_APPROVED=1`, with temp worktrees further gated by `TMP_WORKTREES_APPROVED=1`.
  - Fixed `disk_history.sh` so `DISK_SNAPSHOT_JSON` resolves history from the configured backup repo.
  - Added cleanup safety regression coverage and documented the cleanup gates.
  - Follow-up beads/issues: `jleechan-p1cw` / https://github.com/jleechanorg/disk_magician/issues/5, `jleechan-9s68` / https://github.com/jleechanorg/disk_magician/issues/6, `jleechan-y1xm` / https://github.com/jleechanorg/disk_magician/issues/7.
