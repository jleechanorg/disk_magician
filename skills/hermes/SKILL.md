---
name: disk-magician-hermes
description: Workstation maintenance and growth analytics tool for Hermes.
metadata:
  type: skill
  runtime: hermes
---

# Disk Magician — Hermes Skill

This skill teaches the Hermes agent how to manage disk usage, diagnose growth regressions, and execute cleanup tasks.

## Commands for Hermes

* **Validate System Health**:
  ```bash
  ./disk_magician.sh alert
  ```
* **Audit candidates for cleanup**:
  ```bash
  ./disk_magician.sh audit
  ```
* **Perform safe caches and temporary files deletion**:
  ```bash
  ./disk_magician.sh clean
  ```
* **Review history and regressions**:
  ```bash
  ./disk_magician.sh history
  ```

## Hermes Guardrails & Diagnostic Recipes
- Ensure you perform a dry-run check before executing any deletions.
- If deleting directories modified within the last 7 days, verify that user approval is in context or prompt the user for confirmation.
- **Worktree 7-day rule (single source of truth):** see repo `CLAUDE.md` section "Worktree 7-day rule". Recency comes from `scripts/lib/worktree_recency.sh`; never re-derive it from `stat <wt>/.git` or `stat <wt>` (both measure worktree creation, not use), and treat unmeasurable as protected.
- **Worktree Removal Forensics:** Before concluding that a missing worktree was cleanly removed with `git worktree remove`, inspect `ls -la $(git rev-parse --git-dir)/worktrees/<name>/` and `.git/worktrees/<name>/gitdir`. Admin directory presence proves the working tree was deleted manually via `rm -rf`, not clean `git worktree remove`.
- **Multi-Agent History Search:** When searching `/history` or investigating agent actions, search across Antigravity (`~/.gemini`), Cursor (`~/.cursor`), Hermes (`~/.hermes`), Claude (`~/.claude`), and Codex (`~/.codex`) in parallel (see `~/.claude/skills/history-search/SKILL.md`).
- **mem0 & Qdrant Diagnosis Recipe (Launcher vs API Key):**
  When `mem0 unavailable` or Qdrant connection errors occur, do NOT assume an embedder API key is missing (mem0 uses local FastEmbed + Ollama). Follow the 4-step recipe:
  1. *Probe reachability:* `lsof -nP -iTCP:6333 -sTCP:LISTEN` and `curl -sS -m 3 http://127.0.0.1:6333/healthz`
  2. *Inspect launchd:* `launchctl print gui/$(id -u)/ai.hermes.qdrant` and `tail -30 ~/Library/Logs/ai.hermes.qdrant.err.log` (check for Docker wait failure `no usable Docker context after 60s`; fix with native `/Users/jleechan/.local/bin/qdrant` binary, `WorkingDirectory`, `KeepAlive=true`, and `ProcessType: Interactive`).
  3. *Inspect cwd/storage permissions:* Check for `Failed to create snapshots temp directory` / `Read-only file system (os error 30)`. Fix with explicit `WorkingDirectory` and absolute paths in `config.yaml`.
  4. *Helper API compatibility:* mem0 2.x migration requires `filters={'user_id': ...}` instead of `user_id=` for `m.search()` and `m.get_all()`.

