# Disk Magician — Design Specification

`disk_magician` is a generalized, zero-dependency disk usage diagnostic, history-tracking, and cleanup utility designed for agentic development workstations. It generalizes the site-specific scripts from `user_scope` into a portable toolkit that can be deployed on any macOS or Linux machine.

---

## 1. Repository Layout

```
disk_magician/
├── disk_magician.sh              # Main entry point / CLI orchestrator
├── README.md                     # User guide and setup instructions
├── DESIGN.md                     # Architecture and technical specification
├── config.json.template          # Default configurations template
├── scripts/
│   ├── snapshot_lib.sh           # Shared helper to resolve correct host snapshot
│   ├── disk_snapshot.sh          # Performs disk breakdown measurements -> JSON
│   ├── disk_audit.sh             # Analyzes snapshot and recommends cleanups
│   ├── disk_history.sh           # Graph/table generator of historical growth
│   ├── disk_usage_alert.sh       # Low disk alert daemon script
│   ├── cleanup_worktrees.sh      # Generalized git worktree cleanup
│   ├── cleanup_sessions.sh       # Generalized agent session cleanup
│   ├── cleanup_tmp.sh            # Generalized temporary folder cleanup
│   ├── cleanup_docker.sh         # Docker prune without volume deletion
│   ├── cleanup_ollama.sh         # Local Ollama model-store cleanup
│   └── cleanup_xcode.sh          # Xcode DerivedData and simulator cleanup
├── skills/
│   ├── claude/
│   │   └── SKILL.md              # Claude Code instruction skill
│   ├── codex/
│   │   └── SKILL.md              # Codex-compatible instruction skill
│   ├── hermes/
│   │   └── SKILL.md              # Hermes-compatible instruction skill
│   └── openclaw/
│       └── SKILL.md              # Openclaw-compatible instruction skill
└── tests/
    ├── test_snapshot.py          # Snapshot test suite
    └── test_audit.py             # Audit test suite
```

---

## 2. Generalization Strategy

### A. Dynamic Worktree Discovery (`cleanup_worktrees.sh`)
* **Problem in old script:** Hardcoded paths (`worldarchitect.ai` and `worktree_worldarchitect`).
* **Generalized solution:** Scan directories under common workspace roots (e.g. `~/.gemini/antigravity/worktrees/`). For each folder containing a `.git` file:
  1. Parse the `.git` file to read `gitdir: /path/to/main/repo/.git/worktrees/...`.
  2. Extract the main repository path.
  3. Query `git -C /path/to/main/repo worktree list` to get all registered worktrees.
  4. If the directory is not in the active worktrees, mark it as **orphaned** and delete it.
  5. If the directory does not contain a `.git` file, it represents a corrupted/incomplete checkout and is also safe to remove.
* **Safety gate:** `clean` and `clean-all` skip worktree deletion unless `WORKTREE_APPROVED=1` is present.

### B. Dynamic Temp Clone Discovery (`cleanup_tmp.sh`)
* **Problem in old script:** Only looked at `/private/tmp/worldarchitect.ai` and `pr-orch-bases`.
* **Generalized solution:** Scan `/tmp` and `/private/tmp` for directories older than a configurable threshold (e.g. 4 hours) that contain a `.git/` folder (indicating a Git clone). Filter out active/essential system directories (e.g. `claude-*` or directories currently open by a process) and clean them.
* **Large tmp mode:** `clean-all` calls `cleanup_tmp.sh --large` in dry-run/apply mode. Applying large tmp cleanup requires `LARGE_TMP_APPROVED=1`; `wt_*` and `worktree_*` directories remain skipped unless `TMP_WORKTREES_APPROVED=1` is also set.

### C. Host-Agnostic Snapshot Tracking (`snapshot_lib.sh` & `disk_history.sh`)
* **Problem in old script:** Relied on alphabetical globbing of folders, which could pick the wrong host's snapshot file.
* **Generalized solution:** Parse the `"timestamp"` embedded in each `disk_snapshot.json` and select the newest snapshot file. `disk_history.sh` dynamically parses the keys in the `"directories"` JSON object so that it automatically updates its columns based on whatever keys are tracked in the config.

### D. Large Cleanup Adapters
* **Docker:** `cleanup_docker.sh` previews or applies `docker system prune -a -f` and intentionally preserves volumes.
* **Ollama:** `cleanup_ollama.sh` previews or deletes the local model store (`~/.ollama/models` by default, or `OLLAMA_MODELS_DIR`).
* **Xcode:** `cleanup_xcode.sh` previews or clears DerivedData, CoreSimulator temp/cache directories, and unavailable simulators.

---

## 3. Core CLI Commands (`disk_magician.sh`)

1. **`setup`**: 
   * Prompts to create a local backup directory (defaulting to `~/.disk_magician_backup`).
   * Optionally creates a remote repo (e.g., `jleechanorg/disk_backup` or user-owned `disk_backup`) on GitHub.
   * Installs a `launchd` plist (macOS) or a `cron` job (Linux) to run a snapshot every 30 minutes, committing and pushing to the backup repo.
2. **`snapshot`**: Run the generalized snapshot script to generate a JSON report and write to the backup path.
3. **`audit`**: Run the diagnostics showing volume status, top directories, growth regressions, and cleanup candidates.
4. **`clean [--dry-run]`**: Clean up safe targets (stale temp directories, caches, logs). Worktrees are skipped unless `WORKTREE_APPROVED=1`.
5. **`clean-all [--dry-run]`**: Preview or apply larger cleanup for stale sessions, large tmp directories, worktrees, APFS snapshots, Docker, Ollama, and Xcode. Large tmp apply mode requires `LARGE_TMP_APPROVED=1`, and tmp worktree-style directories (`wt_*`, `worktree_*`) require `TMP_WORKTREES_APPROVED=1`.
6. **`history`**: Output historical growth chart using the Git commit logs of the snapshot file.
7. **`discover`**: Scan home directory for directories > 5 GB not currently tracked.

---

## 4. Integrations & Skills

Skills will be created for major LLM agents (Claude Code, Codex, Hermes, Openclaw) instructing them to use this CLI to diagnose, validate, and clean local systems, ensuring standard output formats and respecting guardrails (such as requiring approval for files modified < 14 days ago).
