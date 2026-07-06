# disk_magician roadmap

## Recent activity (rolling)

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
  - Follow-up beads/issues: `jleechan-qoss` (Playwright cache dedup across AO sessions, ~3GB, NOT yet actioned — user has a standing leave-sessions-alone policy), `jleechan-80wj` (generalize the jc-1933-style nested-orchestrator sweep), `jleechan-p2gy` (Node `node_modules` pnpm migration, 6.2G), `jleechan-8twx` (Antigravity worktrees triage, 6.0G), `jleechan-emnx`, `jleechan-dp2x`.
  - Nextsteps doc: `~/roadmap/nextsteps-2026-07-03-ao-session-dedup.md`.

- 2026-06-27 — Disk cleanup recovery and harness hardening:
  - Reclaimed non-worktree disk usage from `/private/tmp`, Ollama model blobs, Docker unused images, and Xcode DerivedData.
  - Added explicit cleanup targets for Docker, Ollama, and Xcode.
  - Gated worktree deletion behind `WORKTREE_APPROVED=1`.
  - Gated large `/private/tmp` cleanup behind `LARGE_TMP_APPROVED=1`, with temp worktrees further gated by `TMP_WORKTREES_APPROVED=1`.
  - Fixed `disk_history.sh` so `DISK_SNAPSHOT_JSON` resolves history from the configured backup repo.
  - Added cleanup safety regression coverage and documented the cleanup gates.
  - Follow-up beads/issues: `jleechan-p1cw` / https://github.com/jleechanorg/disk_magician/issues/5, `jleechan-9s68` / https://github.com/jleechanorg/disk_magician/issues/6, `jleechan-y1xm` / https://github.com/jleechanorg/disk_magician/issues/7.
