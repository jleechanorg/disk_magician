# disk_magician roadmap

## Recent activity (rolling)

- 2026-06-27 — Disk cleanup recovery and harness hardening:
  - Reclaimed non-worktree disk usage from `/private/tmp`, Ollama model blobs, Docker unused images, and Xcode DerivedData.
  - Added explicit cleanup targets for Docker, Ollama, and Xcode.
  - Gated worktree deletion behind `WORKTREE_APPROVED=1`.
  - Gated large `/private/tmp` cleanup behind `LARGE_TMP_APPROVED=1`, with temp worktrees further gated by `TMP_WORKTREES_APPROVED=1`.
  - Fixed `disk_history.sh` so `DISK_SNAPSHOT_JSON` resolves history from the configured backup repo.
  - Added cleanup safety regression coverage and documented the cleanup gates.
  - Follow-up beads/issues: `jleechan-p1cw` / https://github.com/jleechanorg/disk_magician/issues/5, `jleechan-9s68` / https://github.com/jleechanorg/disk_magician/issues/6, `jleechan-y1xm` / https://github.com/jleechanorg/disk_magician/issues/7.
