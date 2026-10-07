# Implementation Plan: 200+ GiB Disk Reclaim Wave 2 (Targets 1–4)

**Document Path**: `/Users/jleechan/projects_other/disk_magician/docs/superpowers/plans/2026-10-04-disk-reclaim-wave-2.md`  
**Creation Date**: 2026-10-04  
**Author**: Antigravity Genesis Assistant  
**Status**: REVISED (Incorporating `/advice` Codex + Opus and `/wa` Perplexity findings)

---

## 1. Executive Summary & Yield Matrix

In Wave 1 of this session, routine stack cleanups and targeted pruning successfully reclaimed **+107 GiB of free disk space**, taking the volume from an emergency 10 GiB free up to **117 GiB free** (778 GiB used, down from 876 GiB; shrinking the gap to the 60-day historical floor from +154 GiB to +56 GiB).

To achieve the full 200+ GiB reclamation target and restore the workstation below its 60-day historical floor (722 GiB), Wave 2 was submitted to formal adversarial review via `/advice` (Codex + Opus) and `/wa` (Perplexity Web). Based on empirical filesystem inspection and consensus review findings, the execution order is structured into immediate safe execution (Phase 1 & 2) and guarded investigation (Phase 3 & 4):

| Execution Phase | Target | Category / Path | Current Size | Reclamation Mechanism | Expected Yield | Reviewer Disposition |
|---|---|---|---|---|---|---|
| **Phase 1 (Immediate)** | **Target 4** | Homebrew Cellar & Caches (`/opt/homebrew`) | 38.6 GiB | Canonical `brew cleanup -s` removing stale version bottles and download cache | **5–10 GiB** | **APPROVED** (Codex, Opus, Perplexity) |
| **Phase 2 (Immediate)** | **Target 3** | Stale Worktrees & Venvs (`~/project_worldaiclaw`) | 34.2 GiB | Stripping dormant venvs (`>=7d`) + pruning merged worktrees (`>=7d`) via canonical scripts | **15–20 GiB** | **APPROVED** (Codex, Opus, Perplexity) |
| **Phase 3 (Guarded)** | **Target 2** | Cloud Storage Local Eviction (`~/Library/CloudStorage`) | 50.1 GiB | Provider-specific inspection; manual Finder "Remove Download" or official sync rules | **20–30 GiB** | **CAUTION** (`fileproviderctl evict` removed in Sonoma 14.4+) |
| **Phase 4 (Preserved)** | **Target 1** | Codex Historical Sessions (`~/.codex/sessions`) | 29.3 GiB | **PRESERVED**: 34,979 files already `.jsonl.zst`; `rollout_path` expects `.jsonl`; zero files >30d | **0 GiB (Preserved)** | **NEVER-DELETE** (Strict invariant enforced; no renaming) |

Combined with the 107 GiB already freed in Wave 1, executing Phases 1 and 2 will bring total space reclaimed to **~130–140 GiB**, expanding free disk space to **~140–150 GiB**.

---

## 2. Reviewer Findings & Dispositions

### A. Codex (`gpt-5.6-terra`)
- **Verdict**: Revise before implementation: retain Targets 3–4, but make Target 1’s never-delete exception explicit and add provider-proven safeguards for Target 2.
- **Key Finding**: Unlinking Codex sessions contradicts never-delete invariants; `state_5.sqlite` compatibility must not be broken; CloudStorage xattrs are insufficient without provider-specific confirmation.

### B. Opus (`claude-3-opus`)
- **Verdict**: Don't approve as written. Drop Target 1, add concrete sync checks to Target 2, and let Targets 3 and 4 go ahead through canonical scripts.
- **Empirical Discovery**: Probed `~/.codex/sessions`: 34,979 files are *already* compressed as `.jsonl.zst` (~7.6 GiB) and active `.jsonl` files are only ~21.7 GiB total. Zero raw files are older than 30 days. Renaming breaks SQLite `threads.rollout_path` references.

### C. Perplexity Web (`Kimi K3 Thinking`)
- **Verdict**: CHANGES REQUESTED.
- **Key Finding**: `fileproviderctl evict` was removed from macOS in Sonoma 14.4+; Codex CLI already auto-compresses rollouts after 7 days; Targets 3 and 4 are completely sound and should run first in order **4 → 3**.

---

## 3. Revised Execution Protocol

### Step 1: Execute Target 4 (Homebrew Cleanup)
1. Run `brew cleanup -s` to safely prune orphaned bottle archives in `~/Library/Caches/Homebrew` and unlinked cellar versions.
2. Verified invariant: Does not remove currently linked software or alter `$PATH`.

### Step 2: Execute Target 3 (`~/project_worldaiclaw` Worktree & Venv Pruning)
1. Strip dormant virtualenvs:
   - Run `scripts/cleanup_worktree_venvs.sh --clean --root /Users/jleechan/project_worldaiclaw`.
   - Strips `.venv`/`venv` from worktrees inactive for >=7 days.
2. Prune merged, dormant worktrees:
   - Run `env WORKTREE_APPROVED=1 scripts/cleanup_worktrees.sh --clean --roots /Users/jleechan/project_worldaiclaw`.
   - Strictly enforces 7-day recency floor (`worktree_age_days >= 7`).
   - Verifies zero uncommitted changes and zero unpushed commits.

### Step 3: Cloud Storage Handling (Target 2)
1. Avoid unproven CLI eviction scripts that risk deleting saved versions on Sonoma/Sequoia.
2. Direct operator to use Finder's native right-click -> "Remove Download" on verified historical directories in `~/Library/CloudStorage` if additional immediate space is desired.

### Step 4: Codex Sessions Preservation (Target 1)
1. Retain `~/.codex/sessions` untouched.
2. Rely on Codex's built-in 7-day background zstd compressor, preserving SQLite `rollout_path` referential integrity and honoring the repo's hard Never-Delete invariant.
