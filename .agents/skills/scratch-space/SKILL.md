---
name: scratch-space
description: Single source of truth for agent scratch, temporary files, disposable builds, and evidence paths across macOS and Linux. Use whenever an agent, skill, or workflow needs a scratch directory, temporary file path, build output folder, or evidence directory instead of hardcoding /tmp or OS-specific mountpoints.
---

# Scratch Space (`/scratch-space`) — Single Source of Truth

## Purpose (Ponytail / DRY / ZFC Invariant)

Do **not** hardcode `/tmp/...`, `/private/tmp/...`, `/Volumes/diskm-scratch`, or `/home/jleechan/Scratch` across individual skills, prompts, or agent instruction files.

All temporary, disposable build, test scratch, and evidence paths resolve dynamically through **one canonical interface** backed by `diskm` (`~/.config/disk-magician/config.json`) and exported by default in all shell/agent environments via `$DISKM_SCRATCH` and `$CLAUDE_CODE_TMPDIR`:

0. **Default Environment Variables (Pre-exported in `~/.zshenv`, `~/.bashrc`, `~/.profile`, and `~/.claude/settings.json`)**
   - `DISKM_SCRATCH`: Pre-set to the host's active Scratch volume (`/Volumes/diskm-scratch` on macOS, `/home/jleechan/Scratch` on Linux).
   - `CLAUDE_CODE_TMPDIR`: Pre-set to `${DISKM_SCRATCH}/tmp` so Claude Code task scratchpads (`claude-*`) use the Scratch volume automatically by default.

1. **Repo-Scoped Build, Test & Evidence Directories (Managed Lease + Admission)**
   ```bash
   # Allocate a managed build or evidence directory (auto-falls back to /tmp/<repo>/<kind>/... only if no Scratch volume is configured)
   OUT_DIR="$(diskm scratch-new <repo-path> <purpose> --kind build)"
   EVIDENCE_DIR="$(diskm scratch-new <repo-path> <purpose> --kind evidence)"
   # ...produce output in "$OUT_DIR"...
   diskm scratch-finish "$OUT_DIR" completed   # or: abandoned
   ```
   - Any process of the same user may run `scratch-finish`; it does not have to be the allocating shell.
   - A build run that is never finished becomes removable once its recorded owner has exited and its files have been untouched for the default content floor (`CONTENT_FLOOR_HOURS` in diskm's `rust/src/time_windows.rs`). Open files, live working directories, repositories and PR-evidence holds still protect it. Evidence runs are never removed this way.
   - Pass `--owner-pid <PID>` (a process of the same user) to bind the run to a long-lived producer; the run is then kept while that process lives.
   - Put run output here, not under `scratch-dir`. Scratch folders outside a leased run are removed by the scheduled expired sweep (`diskm scratch-sweep --expired --clean`) once their newest content is past the content floor and no hold applies, whatever the Scratch fill level. Keep durable output in Git, a leased evidence run, or the evidence gist route.
   - `diskm scratch-new --kind build|evidence` places new leased runs at `<Scratch>/runs/YYYYMMDD/<repo>/<purpose>-<UTC timestamp>-<allocator pid>-<nonce>/`. The lease records its kind and producer owner. Detached Git worktrees created with `--detach` stay under `~/.worktrees/<repo>/`. The ordinary cleanup floor is `CONTENT_FLOOR_HOURS` in `rust/src/time_windows.rs`. See the [operator playbook](../../../docs/operator-playbook.md#disposable-content-uses-the-default-content-floor) for cleanup policy and scoped overrides.

2. **Ad-Hoc Helper Files, PR Bodies, Frame Dumps, Server Logs & Ephemeral Scripts**
   ```bash
   # Resolve the host's active Scratch root (or create/return a subdirectory inside it)
   SCRATCH_ROOT="$(~/.claude/skills/scratch-space/scripts/scratch-dir.sh)"
   SCRATCH_TMP="$(~/.claude/skills/scratch-space/scripts/scratch-dir.sh tmp)"
   ```
   - Example (`gh` PR/issue body file):
     ```bash
     BODY_FILE="$(~/.claude/skills/scratch-space/scripts/scratch-dir.sh gh)/pr_body_$$.md"
     ```
   - Example (ephemeral `mktemp` directory for video frames, clones, or probes):
     ```bash
     WORK_DIR="$(mktemp -d "$(~/.claude/skills/scratch-space/scripts/scratch-dir.sh tmp)/work.XXXXXX")"
     ```
   - Example (dev/test server logs):
     ```bash
     LOG_DIR="$(~/.claude/skills/scratch-space/scripts/scratch-dir.sh "logs/${REPO_NAME}/${BRANCH_NAME}")"
     ```

## What NOT to Put in Scratch

- **Git worktrees**: Always use `~/.worktrees/<repo>/<name>` via `diskm worktree-new <repo-path> <branch>`. Never put git worktrees in Scratch or `/tmp`.
- **Durable reports & roadmaps**: Keep in `~/roadmap/`.
- **Mutable agent state, credentials & transcripts**: Keep in `$HOME` (`~/.claude`, `~/.codex`, `~/.gemini`, `~/.config`).
- **Global `TMPDIR`**: Never remap global `TMPDIR` or replace `/tmp`.

## Host Provisioning Reference

Operators provision or inspect the quota-bounded Scratch volume via `diskm`:
- Provision (optional, recommended 200 GiB): `diskm setup --scratch [--quota-gb 200]`
- Query active mountpoint: `diskm volume path scratch`
- Check volume status: `diskm volume status scratch`
