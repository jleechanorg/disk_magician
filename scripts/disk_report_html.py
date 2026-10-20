#!/usr/bin/env python3
"""disk_report_html.py — Generate an interactive self-contained HTML Treemap &
Canonical `diskm` Cleanup Dashboard from `disk_snapshot.json` + `frontier_last.json`.

Runs in <1s purely from persisted snapshot and frontier JSON artifacts without
invoking `du` or scanning the live filesystem. Enforces Disk Magician's safety
policy:
- Never-Delete Protected State (`~/.codex/sessions*`, `~/.codex/state*.sqlite`,
  `~/.codex/log`, `~/.claude/projects`, `~/projects_reference`) is locked and
  non-deletable.
- Safe routine targets map to canonical `diskm <subcommand> --clean` commands.
- Worktree and scratch targets map to gated `WORKTREE_APPROVED=1 diskm ...`
  commands.
"""

from __future__ import annotations

import argparse
import datetime
import html
import json
import math
import os
from pathlib import Path
import subprocess
import sys
from typing import Any, Dict, List, Optional, Tuple

GIB_KB = 1024.0 * 1024.0

SCRIPTS_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPTS_DIR.parent
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))


def _load_key_path_map() -> Dict[str, str]:
    """Load key -> path/pattern mapping from config.json or config.json.template."""
    mapping: Dict[str, str] = {}
    for candidate in (REPO_ROOT / "config.json", REPO_ROOT / "config.json.template"):
        if candidate.is_file():
            try:
                cfg = json.loads(candidate.read_text(encoding="utf-8"))
                for section in ("monitored_dirs", "monitored_globs", "monitored_file_globs"):
                    for entry in cfg.get(section, []) or []:
                        if isinstance(entry, dict) and entry.get("key"):
                            p = entry.get("path") or entry.get("pattern") or ""
                            if p:
                                mapping[str(entry["key"])] = str(p)
                if mapping:
                    break
            except Exception:
                continue
    return mapping


def resolve_default_snapshot_path(explicit: Optional[str] = None) -> Path:
    """Resolve the freshest snapshot JSON path without scanning the disk."""
    if explicit:
        return Path(os.path.expanduser(explicit)).resolve()
    for env_key in ("DISK_SNAPSHOT_JSON", "DISK_MAGICIAN_SNAPSHOT_FILE"):
        env_val = os.environ.get(env_key, "").strip()
        if env_val:
            p = Path(os.path.expanduser(env_val)).resolve()
            if p.is_file():
                return p
    home = Path.home()
    candidates: List[Path] = []
    # Try resolve_snapshot_json.sh helper
    helper = SCRIPTS_DIR / "lib" / "resolve_snapshot_json.sh"
    if helper.is_file():
        try:
            proc = subprocess.run(
                ["bash", "-c", f'source "{helper}" && resolve_snapshot_json'],
                capture_output=True,
                text=True,
                timeout=1.0,
                check=False,
            )
            candidate_str = proc.stdout.strip()
            if candidate_str:
                p = Path(os.path.expanduser(candidate_str)).resolve()
                if p.is_file():
                    candidates.append(p)
        except Exception:
            pass
    for c in (
        home / ".disk_magician_backup" / "snapshots" / "disk_snapshot.json",
        home / ".local" / "state" / "disk-magician" / "snapshots" / "disk_snapshot.json",
    ):
        if c.is_file():
            rc = c.resolve()
            if rc not in candidates:
                candidates.append(rc)
    if candidates:
        candidates.sort(key=lambda x: x.stat().st_mtime, reverse=True)
        return candidates[0]
    return (home / ".disk_magician_backup" / "snapshots" / "disk_snapshot.json").resolve()


def resolve_default_frontier_path(explicit: Optional[str] = None, snapshot_path: Optional[Path] = None) -> Optional[Path]:
    """Resolve optional frontier_last.json or ledger/topdown-5g.json path."""
    if explicit:
        p = Path(os.path.expanduser(explicit)).resolve()
        return p if p.is_file() else None
    env_val = os.environ.get("DISK_FRONTIER_JSON", "").strip()
    if env_val:
        p = Path(os.path.expanduser(env_val)).resolve()
        if p.is_file():
            return p
    home = Path.home()
    candidates: List[Path] = [
        home / ".disk_magician_state" / "frontier_last.json",
    ]
    if snapshot_path is not None:
        candidates.append(snapshot_path.parent.parent / "ledger" / "topdown-5g.json")
    candidates.extend([
        home / ".disk_magician_backup" / "ledger" / "topdown-5g.json",
        home / ".local" / "state" / "disk-magician" / "ledger" / "topdown-5g.json",
    ])
    for c in candidates:
        if c.is_file():
            return c.resolve()
    return None


def _try_load_previous_snapshot_dirs(snapshot_path: Path) -> Dict[str, float]:
    """Best-effort fast git lookup (<0.25s) of an earlier snapshot for growth deltas."""
    repo_dir = snapshot_path.parent.parent
    if not (repo_dir / ".git").exists():
        return {}
    rel_path = snapshot_path.relative_to(repo_dir)
    for rev in ("HEAD~6", "HEAD~2", "HEAD~1"):
        try:
            proc = subprocess.run(
                ["git", "-C", str(repo_dir), "show", f"{rev}:{rel_path}"],
                capture_output=True,
                text=True,
                timeout=0.25,
                check=False,
            )
            if proc.returncode == 0 and proc.stdout:
                prev_data = json.loads(proc.stdout)
                prev_dirs = prev_data.get("directories")
                if isinstance(prev_dirs, dict):
                    out: Dict[str, float] = {}
                    for k, v in prev_dirs.items():
                        if isinstance(v, (int, float)) and not isinstance(v, bool):
                            out[k] = float(v) / GIB_KB
                    for ck in prev_data.get("carried_keys", []) or []:
                        if isinstance(ck, dict) and ck.get("key") and isinstance(ck.get("kb"), (int, float)):
                            k = str(ck["key"])
                            if k not in out or out[k] == 0:
                                out[k] = float(ck["kb"]) / GIB_KB
                    return out
        except Exception:
            continue
    return {}


def _load_worktree_ledger_summary() -> Dict[str, Any]:
    """Optionally read ~/.disk_magician_state/worktree_cleanup_ledger.tsv if present."""
    ledger_path = Path.home() / ".disk_magician_state" / "worktree_cleanup_ledger.tsv"
    if not ledger_path.is_file():
        return {"present": False, "entries": 0}
    try:
        lines = [ln for ln in ledger_path.read_text(encoding="utf-8", errors="replace").splitlines() if ln.strip()]
        return {"present": True, "entries": max(0, len(lines) - 1), "path": str(ledger_path)}
    except Exception:
        return {"present": False, "entries": 0}


# Canonical classification rules mapping snapshot keys -> (bucket, category, title, path_override, command, description, default_checked)
# Buckets:
#   "safe"      -> Safe to remove (via diskm) — checked by default
#   "gated"     -> Gated / Review first (via diskm) — unchecked by default
#   "protected" -> Protected (Never-Delete List & active user data) — non-deletable lock badge
#   "system"    -> System & Residual — system/APFS/residual space
CATALOG_RULES: Dict[str, Dict[str, Any]] = {
    # --- SAFE TO REMOVE (VIA DISKM) ---
    "colima": {
        "bucket": "safe",
        "category": "Containers & VMs",
        "name": "Colima VM & Docker Sparse Disk",
        "path": "~/.colima",
        "command": "diskm cleanup-colima --clean",
        "explanation": "Prunes unused Docker images/containers and runs in-VM fstrim -av to shrink ~/.colima sparse disk.",
        "checked": True,
    },
    "docker_raw": {
        "bucket": "gated",
        "category": "Containers & VMs",
        "name": "Docker Desktop VM Disk",
        "path": "~/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw",
        "command": "manual review (no diskm command reclaims this path)",
        "explanation": "cleanup-colima prunes Colima, not Docker Desktop; reclaim Docker.raw from Docker Desktop.",
        "checked": False,
    },
    "library_caches": {
        "bucket": "safe",
        "category": "Developer Caches",
        "name": "macOS User Library Caches",
        "path": "~/Library/Caches",
        "command": "diskm cleanup-dev-caches --clean",
        "explanation": "Cleans rebuildable compiler, Playwright, pip, uv, and browser/app caches under ~/Library/Caches.",
        "checked": True,
    },
    "cache_dir": {
        "bucket": "safe",
        "category": "Developer Caches",
        "name": "XDG & Tool Caches (~/.cache)",
        "path": "~/.cache",
        "command": "diskm cleanup-dev-caches --clean",
        "explanation": "Cleans rebuildable pip, pre-commit, huggingface, codex-runtimes, and build caches in ~/.cache.",
        "checked": True,
    },
    "library_pnpm": {
        "bucket": "gated",
        "category": "Developer Caches",
        "name": "pnpm Content-Addressable Store",
        "path": "~/Library/pnpm",
        "command": "manual review (no diskm command reclaims this path)",
        "explanation": "Not pruned by cleanup-dev-caches; review manually (pnpm store prune).",
        "checked": False,
    },
    "npm_cache": {
        "bucket": "safe",
        "category": "Developer Caches",
        "name": "npm Package Cache",
        "path": "~/.npm",
        "command": "diskm cleanup-dev-caches --clean",
        "explanation": "Clears rebuildable npm tarball cache in ~/.npm.",
        "checked": True,
    },
    "cargo": {
        "bucket": "gated",
        "category": "Developer Caches",
        "name": "Rust Cargo Registry & Git Cache",
        "path": "~/.cargo",
        "command": "manual review (no diskm command reclaims this path)",
        "explanation": "Not pruned by cleanup-dev-caches; review manually (cargo cache tools).",
        "checked": False,
    },
    "gradle": {
        "bucket": "gated",
        "category": "Developer Caches",
        "name": "Gradle Build & Wrapper Cache",
        "path": "~/.gradle",
        "command": "manual review (no diskm command reclaims this path)",
        "explanation": "Not pruned by cleanup-dev-caches; review manually.",
        "checked": False,
    },
    "library_developer": {
        "bucket": "gated",
        "category": "Xcode & Simulators",
        "name": "Xcode DerivedData & CoreSimulator Caches",
        "path": "~/Library/Developer",
        "command": "manual review (no diskm command reclaims this path)",
        "explanation": "cleanup_xcode.sh has no diskm subcommand; it runs in the scheduled routine and prunes only DerivedData and simulator temp.",
        "checked": False,
    },
    "tmp_private": {
        "bucket": "safe",
        "category": "Temp & Scratch",
        "name": "System Ephemeral Temp (/private/tmp)",
        "path": "/private/tmp",
        "command": "diskm cleanup-tmp --clean",
        "explanation": "Removes stale ephemeral directories, test harnesses, and expired scratch in /private/tmp older than retention.",
        "checked": True,
    },
    "home_tmp": {
        "bucket": "gated",
        "category": "Temp & Scratch",
        "name": "User Scratch Temp (~/tmp)",
        "path": "~/tmp",
        "command": "manual review (no diskm command reclaims this path)",
        "explanation": "cleanup-tmp scans /private/tmp, /tmp and the per-user temp dir, not ~/tmp; review manually.",
        "checked": False,
    },
    "tmp_pr_scratch": {
        "bucket": "gated",
        "category": "Temp & Scratch",
        "name": "Abandoned PR Analyzer Scratch",
        "path": "/tmp/pr*",
        "command": "diskm cleanup-pr-scratch --clean",
        "explanation": "Subset of /private/tmp (counted there); cleanup-pr-scratch prunes aged pr*/claude* dirs.",
        "checked": False,
    },
    "llm_inspector": {
        "bucket": "gated",
        "category": "Temp & Scratch",
        "name": "LLM Inspector Payload Traces",
        "path": "~/.llm-inspector",
        "command": "manual review (no diskm command reclaims this path)",
        "explanation": "Not scanned by cleanup-pr-scratch; review manually.",
        "checked": False,
    },
    "tmp_task_scratch": {
        "bucket": "gated",
        "category": "Temp & Scratch",
        "name": "Aged Task Scratch Containers",
        "path": "~/projects & /tmp/task*",
        "command": "diskm cleanup-task-scratch --clean",
        "explanation": "Overlaps /private/tmp and ~/projects; cleanup-task-scratch prunes aged scratch containers only.",
        "checked": False,
    },
    "aside": {
        "bucket": "safe",
        "category": "Browser & Agent Sessions",
        "name": "Aside Browser Sessions & Assets",
        "path": "~/.aside",
        "command": "diskm prune-aside-sessions --clean",
        "explanation": "Prunes stale Aside browser sessions (>7d/14d) and hardlink-deduplicates static assets across retained sessions.",
        "checked": True,
    },
    "gemini_root": {
        "bucket": "safe",
        "category": "Agent State Compaction",
        "name": "Antigravity Brain & Completed Task Logs",
        "path": "~/.gemini",
        "command": "diskm cleanup-antigravity-brain --clean",
        "explanation": "Losslessly compacts completed Antigravity task logs, brain dirs, and .backup leftovers (>=7d).",
        "checked": True,
    },
    "antigravity_dot": {
        "bucket": "gated",
        "category": "Agent State Compaction",
        "name": "Antigravity Legacy State (~/.antigravity)",
        "path": "~/.antigravity",
        "command": "manual review (no diskm command reclaims this path)",
        "explanation": "cleanup-antigravity-brain compacts ~/.gemini, not ~/.antigravity; review manually.",
        "checked": False,
    },
    "library_logs": {
        "bucket": "gated",
        "category": "Logs & Diagnostics",
        "name": "Rotated Supervisor & User Logs",
        "path": "~/Library/Logs",
        "command": "manual review (no diskm command reclaims this path)",
        "explanation": "Not pruned by cleanup-supervisor-logs; review manually.",
        "checked": False,
    },
    "var_log": {
        "bucket": "gated",
        "category": "Logs & Diagnostics",
        "name": "System Rotated Logs (/var/log)",
        "path": "/var/log",
        "command": "manual review (no diskm command reclaims this path)",
        "explanation": "System logs; not pruned by cleanup-supervisor-logs.",
        "checked": False,
    },
    "local_dir": {
        "bucket": "gated",
        "category": "Developer Caches",
        "name": "~/.local (mixed app data; only the uv cache is pruned)",
        "path": "~/.local",
        "command": "manual review (no diskm command reclaims this path)",
        "explanation": "Mixed application data. cleanup-uv-cache prunes only orphaned uv cache entries, so most of this total is not reclaimable by it.",
        "checked": False,
    },
    "dark_factory": {
        "bucket": "safe",
        "category": "Agent State Compaction",
        "name": "Stale Dark-Factory Runs (~/.dark-factory)",
        "path": "~/.dark-factory",
        "command": "diskm cleanup-dark-factory --clean",
        "explanation": "Prunes stale dark-factory releases, runs, and df-* AO session homes.",
        "checked": True,
    },
    "hermes": {
        "bucket": "safe",
        "category": "Agent State Compaction",
        "name": "Hermes Agent State & SQLite WAL",
        "path": "~/.hermes",
        "command": "diskm vacuum-hermes-state --clean",
        "explanation": "Losslessly vacuums SQLite state databases and truncates WAL files in ~/.hermes.",
        "checked": True,
    },

    # --- GATED / REVIEW FIRST (VIA DISKM) ---
    "worktrees_dot": {
        "bucket": "gated",
        "category": "Git Worktrees (Gated)",
        "name": "Canonical Git Worktrees (~/.worktrees)",
        "path": "~/.worktrees",
        "command": "WORKTREE_APPROVED=1 diskm cleanup-worktrees --clean",
        "explanation": "Prunes clean, pushed/merged git worktrees inactive >=3d (enforces live-cwd, secret-file, and AO safety gates).",
        "checked": False,
    },
    "wf_checkouts": {
        "bucket": "gated",
        "category": "Git Worktrees (Gated)",
        "name": "Workflow Worktree Checkouts (~/wf_*)",
        "path": "~/wf_*",
        "command": "WORKTREE_APPROVED=1 diskm cleanup-worktrees --clean",
        "explanation": "Audits and prunes merged/stale ~/wf_* worktrees inactive >=3d with full safety-gate verification.",
        "checked": False,
    },
    "worktrees_home": {
        "bucket": "gated",
        "category": "Git Worktrees (Gated)",
        "name": "Home Worktree Checkouts (~/worktree_*)",
        "path": "~/worktree_*",
        "command": "WORKTREE_APPROVED=1 diskm cleanup-worktrees --clean",
        "explanation": "Prunes merged/clean ~/worktree_* directories inactive >=3d after verifying no unpushed commits or secrets.",
        "checked": False,
    },
    "worktrees_hub": {
        "bucket": "gated",
        "category": "Git Worktrees (Gated)",
        "name": "Worktrees Hub (~/worktrees)",
        "path": "~/worktrees",
        "command": "WORKTREE_APPROVED=1 diskm cleanup-worktrees --clean",
        "explanation": "Prunes dormant merged worktrees under ~/worktrees (>=3d floor).",
        "checked": False,
    },
    "wc_wt": {
        "bucket": "gated",
        "category": "Git Worktrees (Gated)",
        "name": "WorldAI Claw Worktrees (~/wc-wt)",
        "path": "~/wc-wt",
        "command": "WORKTREE_APPROVED=1 diskm cleanup-worktrees --clean",
        "explanation": "Prunes dormant merged worktrees under ~/wc-wt (>=3d floor).",
        "checked": False,
    },
    "projects": {
        "bucket": "gated",
        "category": "Worktree Deps & Venvs (Gated)",
        "name": "Primary Projects & Worktree Deps (~/projects)",
        "path": "~/projects",
        "command": "WORKTREE_APPROVED=1 diskm cleanup-worktree-deps --clean",
        "explanation": "Strips rebuildable node_modules, target, and .mypy_cache from dormant worktrees (>=3d) without touching source.",
        "checked": False,
    },
    "projects_other": {
        "bucket": "gated",
        "category": "Worktree Deps & Venvs (Gated)",
        "name": "Secondary Projects & Worktrees (~/projects_other)",
        "path": "~/projects_other",
        "command": "WORKTREE_APPROVED=1 diskm cleanup-worktree-deps --clean",
        "explanation": "Strips rebuildable dependency dirs (node_modules, target) from dormant worktrees (>=3d) under ~/projects_other.",
        "checked": False,
    },
    "project_worldaiclaw": {
        "bucket": "gated",
        "category": "Worktree Deps & Venvs (Gated)",
        "name": "WorldAI Claw Checkouts (~/project_worldaiclaw)",
        "path": "~/project_worldaiclaw",
        "command": "WORKTREE_APPROVED=1 diskm cleanup-worktree-deps --clean",
        "explanation": "Strips rebuildable node_modules and Python venvs from dormant checkouts (>=3d/7d).",
        "checked": False,
    },
    "repos": {
        "bucket": "gated",
        "category": "Worktree Deps & Venvs (Gated)",
        "name": "Repositories & Dormant Venvs (~/repos)",
        "path": "~/repos",
        "command": "WORKTREE_APPROVED=1 diskm cleanup-worktree-venvs --clean",
        "explanation": "Strips rebuildable Python .venv/venv directories from dormant worktrees inactive >=7d.",
        "checked": False,
    },
    "documents_codex": {
        "bucket": "gated",
        "category": "Git Worktrees (Gated)",
        "name": "Codex Task Scratch (~/Documents/Codex)",
        "path": "~/Documents/Codex",
        "command": "diskm cleanup-codex-documents --clean",
        "explanation": "Removes old, clean, pushed ~/Documents/Codex/<date>/<task> scratch checkouts.",
        "checked": False,
    },
    "claude_root_other": {
        "bucket": "gated",
        "category": "Agent State Compaction",
        "name": "Claude Ephemeral State (~/.claude non-projects)",
        "path": "~/.claude (excluding ~/.claude/projects)",
        "command": "diskm cleanup-claude-state --clean",
        "explanation": "Runs guarded Claude state maintenance while strictly preserving ~/.claude/projects.",
        "checked": False,
    },

    # --- PROTECTED (NEVER-DELETE LIST) ---
    "codex_sessions": {
        "bucket": "protected",
        "category": "Protected State (Never-Delete)",
        "name": "Codex Agent Sessions (~/.codex/sessions*)",
        "path": "~/.codex/sessions*",
        "command": "diskm cleanup-codex-db --clean",
        "explanation": "PROTECTED — Never-Delete List; use diskm cleanup-codex-db --clean for lossless SQLite VACUUM only.",
        "checked": False,
        "never_delete": True,
    },
    "codex_state_db": {
        "bucket": "protected",
        "category": "Protected State (Never-Delete)",
        "name": "Codex SQLite State & Logs (~/.codex/state*.sqlite, ~/.codex/log)",
        "path": "~/.codex/state*.sqlite & ~/.codex/log",
        "command": "diskm cleanup-codex-db --clean",
        "explanation": "PROTECTED — Never-Delete List; use diskm cleanup-codex-db --clean for lossless SQLite VACUUM only.",
        "checked": False,
        "never_delete": True,
    },
    "claude_projects": {
        "bucket": "protected",
        "category": "Protected State (Never-Delete)",
        "name": "Claude Code Projects & Memories (~/.claude/projects)",
        "path": "~/.claude/projects",
        "command": "PROTECTED (Never-Delete List)",
        "explanation": "PROTECTED — Never-Delete List; contains authoritative Claude Code project transcripts and memories.",
        "checked": False,
        "never_delete": True,
    },
    "projects_reference": {
        "bucket": "protected",
        "category": "Protected State (Never-Delete)",
        "name": "Reference Repositories (~/projects_reference)",
        "path": "~/projects_reference",
        "command": "PROTECTED (Never-Delete List)",
        "explanation": "PROTECTED — Never-Delete List; canonical reference repositories and baselines.",
        "checked": False,
        "never_delete": True,
    },

    # --- SYSTEM & RESIDUAL ---
    "private_var": {
        "bucket": "system",
        "category": "System & Residual",
        "name": "System /private/var & dirs_cleaner Staging",
        "path": "/private/var",
        "command": "diskm cleanup-dirs-cleaner --clean",
        "explanation": "Safely cleans /private/var/dirs_cleaner staging accumulation and diagnoses system daemon state.",
        "checked": False,
    },
    "system_data_volume": {
        "bucket": "system",
        "category": "System & Residual",
        "name": "macOS Data Volume System Assets",
        "path": "/System/Volumes/Data/System",
        "command": "diskm check-system-residual",
        "explanation": "macOS system MobileAssets and UAF models on the Data volume; inspect via diskm check-system-residual.",
        "checked": False,
    },
    "root_library": {
        "bucket": "system",
        "category": "System & Residual",
        "name": "macOS Root /Library",
        "path": "/Library",
        "command": "diskm check-system-residual",
        "explanation": "System-wide /Library frameworks, Application Support, and caches.",
        "checked": False,
    },
}


def build_report_model(
    snapshot: Dict[str, Any],
    frontier: Optional[Dict[str, Any]],
    snapshot_path: Path,
    frontier_path: Optional[Path],
) -> Dict[str, Any]:
    """Transform snapshot + frontier JSONs into the 4-bucket dashboard model."""
    key_path_map = _load_key_path_map()
    prev_dirs_gb = _try_load_previous_snapshot_dirs(snapshot_path)
    wt_ledger = _load_worktree_ledger_summary()

    disk_total_gb = float(snapshot.get("disk_total_gb") or 0.0)
    disk_used_gb = float(snapshot.get("disk_used_gb") or 0.0)
    disk_free_gb = float(snapshot.get("disk_free_gb") or 0.0)
    disk_pct = float(snapshot.get("disk_pct") or (round((disk_used_gb / disk_total_gb) * 100.0, 1) if disk_total_gb > 0 else 0.0))
    timestamp = str(snapshot.get("timestamp") or snapshot.get("snapshot_metadata", {}).get("captured_at") or "unknown")
    coverage_pct = float(
        snapshot.get("snapshot_coverage_pct")
        or snapshot.get("snapshot_metadata", {}).get("coverage_pct")
        or 0.0
    )
    coverage_effective_pct = float(snapshot.get("coverage_effective_pct") or coverage_pct)
    residual_gb = float(snapshot.get("residual_gb") or 0.0)
    residual_delta_gb = float(snapshot.get("residual_delta_gb") or 0.0)
    swap_used_gb = float(snapshot.get("swap_used_gb") or 0.0)
    vm_volume_used_gb = float(snapshot.get("vm_volume_used_gb") or 0.0)
    local_snapshots_count = int(snapshot.get("local_snapshots_count") or 0)
    local_snapshot_names = list(snapshot.get("local_snapshot_names") or [])

    # Extract raw KB values per key from snapshot["directories"] + snapshot["carried_keys"]
    raw_dirs = snapshot.get("directories") or {}
    carried_map: Dict[str, Tuple[float, float]] = {}
    for ck in snapshot.get("carried_keys", []) or []:
        if isinstance(ck, dict) and ck.get("key") and isinstance(ck.get("kb"), (int, float)):
            carried_map[str(ck["key"])] = (float(ck["kb"]), float(ck.get("age_hours") or 0.0))

    # Optional explicit delta overrides inside snapshot (useful for deterministic tests)
    explicit_deltas_gb: Dict[str, float] = {}
    if isinstance(snapshot.get("directory_deltas_gb"), dict):
        for k, v in snapshot["directory_deltas_gb"].items():
            if isinstance(v, (int, float)):
                explicit_deltas_gb[str(k)] = float(v)

    kb_by_key: Dict[str, float] = {}
    is_carried_key: Dict[str, bool] = {}
    custom_path_by_key: Dict[str, str] = {}

    if isinstance(raw_dirs, dict):
        for k, v in raw_dirs.items():
            key = str(k)
            if isinstance(v, (int, float)) and not isinstance(v, bool):
                kb_by_key[key] = float(v)
                is_carried_key[key] = False
            elif isinstance(v, dict):
                if isinstance(v.get("size_gb"), (int, float)):
                    kb_by_key[key] = float(v["size_gb"]) * GIB_KB
                elif isinstance(v.get("kb"), (int, float)):
                    kb_by_key[key] = float(v["kb"])
                elif isinstance(v.get("size_kb"), (int, float)):
                    kb_by_key[key] = float(v["size_kb"])
                if isinstance(v.get("delta_gb"), (int, float)):
                    explicit_deltas_gb[key] = float(v["delta_gb"])
                if isinstance(v.get("path"), str):
                    custom_path_by_key[key] = v["path"]
                is_carried_key[key] = bool(v.get("carried", False))
            elif v is None and key in carried_map:
                kb_by_key[key] = carried_map[key][0]
                is_carried_key[key] = True

    for key, (ck_kb, _) in carried_map.items():
        if key not in kb_by_key or kb_by_key[key] <= 0:
            kb_by_key[key] = ck_kb
            is_carried_key[key] = True

    # Enrich missing/zero keys from frontier_last.json if provided
    frontier_measured: Dict[str, float] = {}
    if isinstance(frontier, dict) and isinstance(frontier.get("measured"), dict):
        for fp, fkb in frontier["measured"].items():
            if isinstance(fkb, (int, float)) and not isinstance(fkb, bool):
                norm_p = str(fp)
                if norm_p.startswith("/System/Volumes/Data/"):
                    norm_p = norm_p[len("/System/Volumes/Data"):]
                frontier_measured[norm_p] = float(fkb)

    home_str = str(Path.home())
    for key, cfg_path in key_path_map.items():
        if kb_by_key.get(key, 0.0) <= 0 and frontier_measured:
            abs_p = cfg_path.replace("~", home_str)
            if abs_p in frontier_measured and frontier_measured[abs_p] > 0:
                kb_by_key[key] = frontier_measured[abs_p]
                is_carried_key[key] = True

    # Handle parent/child splits so Never-Delete and Gated subtrees are surfaced without double-counting:
    # 1. codex_root (~/.codex) -> codex_sessions (~/.codex/sessions*) + codex_state_db (~/.codex/state*.sqlite & ~/.codex/log)
    codex_root_kb = kb_by_key.pop("codex_root", 0.0)
    codex_sessions_kb = kb_by_key.get("codex_sessions", 0.0)
    if codex_root_kb > 0 or codex_sessions_kb > 0:
        if codex_sessions_kb <= 0 and codex_root_kb > 0:
            codex_sessions_kb = round(codex_root_kb * 0.65)
            kb_by_key["codex_sessions"] = codex_sessions_kb
        codex_db_kb = max(0.0, codex_root_kb - codex_sessions_kb)
        if codex_db_kb > 0:
            kb_by_key["codex_state_db"] = codex_db_kb

    # 2. claude_root (~/.claude) -> claude_projects (~/.claude/projects) + claude_root_other (~/.claude non-projects)
    claude_root_kb = kb_by_key.pop("claude_root", 0.0)
    claude_projects_kb = kb_by_key.get("claude_projects", 0.0)
    if claude_root_kb > 0 or claude_projects_kb > 0:
        if claude_projects_kb <= 0 and claude_root_kb > 0:
            claude_projects_kb = round(claude_root_kb * 0.85)
            kb_by_key["claude_projects"] = claude_projects_kb
        claude_other_kb = max(0.0, claude_root_kb - claude_projects_kb)
        if claude_other_kb > 0:
            kb_by_key["claude_root_other"] = claude_other_kb

    # 3. documents (~/Documents) -> documents_codex (~/Documents/Codex) + documents (~/Documents other)
    docs_kb = kb_by_key.get("documents", 0.0)
    docs_codex_kb = kb_by_key.get("documents_codex", 0.0)
    if docs_kb > 0 and docs_codex_kb > 0:
        kb_by_key["documents"] = max(0.0, docs_kb - docs_codex_kb)

    # Deduplicate remaining nested keys listed in dedup_excluded (except those we explicitly split above)
    explicitly_split = {"codex_sessions", "claude_projects", "documents_codex"}
    for ex in snapshot.get("dedup_excluded", []) or []:
        if isinstance(ex, dict):
            ex_key = str(ex.get("key") or "")
            if ex_key and ex_key not in explicitly_split:
                kb_by_key.pop(ex_key, None)

    # Build item records
    items: List[Dict[str, Any]] = []

    def _compute_delta_gb(key: str, current_gb: float) -> float:
        if key in explicit_deltas_gb:
            return round(explicit_deltas_gb[key], 2)
        if key == "codex_state_db" and "codex_root" in prev_dirs_gb:
            prev_db = max(0.0, prev_dirs_gb.get("codex_root", 0.0) - prev_dirs_gb.get("codex_sessions", 0.0))
            return round(current_gb - prev_db, 2)
        if key == "claude_root_other" and "claude_root" in prev_dirs_gb:
            prev_other = max(0.0, prev_dirs_gb.get("claude_root", 0.0) - prev_dirs_gb.get("claude_projects", 0.0))
            return round(current_gb - prev_other, 2)
        if key in prev_dirs_gb:
            return round(current_gb - prev_dirs_gb[key], 2)
        return 0.0

    # Ensure core policy items are always present in the catalog even if 0 GiB in a tiny fixture,
    # or include all items with size >= 0.05 GiB plus all CATALOG_RULES items with size > 0.
    seen_keys = set()
    for key, kb in sorted(kb_by_key.items(), key=lambda kv: kv[1], reverse=True):
        gb = round(kb / GIB_KB, 2)
        rule = CATALOG_RULES.get(key)
        if gb < 0.15 and rule is None:
            continue
        if gb <= 0.0 and rule is None:
            continue
        seen_keys.add(key)
        if rule is not None:
            bucket = rule["bucket"]
            category = rule["category"]
            name = rule["name"]
            path_str = custom_path_by_key.get(key) or rule.get("path") or key_path_map.get(key) or key
            command = rule["command"]
            explanation = rule["explanation"]
            checked = bool(rule.get("checked", False))
            never_delete = bool(rule.get("never_delete", False))
        else:
            path_str = custom_path_by_key.get(key) or key_path_map.get(key) or f"~/{key}"
            bucket = "protected"
            category = "User & App Data"
            name = f"{key.replace('_', ' ').title()} ({path_str})"
            command = "PROTECTED (Active User/App Data)"
            explanation = "Active user, application, or workspace directory; preserved by default."
            checked = False
            never_delete = False

        items.append({
            "id": key,
            "name": name,
            "path": path_str,
            "size_gb": gb,
            "delta_gb": _compute_delta_gb(key, gb),
            "bucket": bucket,
            "category": category,
            "command": command,
            "explanation": explanation,
            "checked": checked,
            "never_delete": never_delete,
            "carried": bool(is_carried_key.get(key, False)),
        })

    # Ensure key canonical rules are always represented in the UI even if missing/0 in a minimal test snapshot
    mandatory_keys = [
        "colima",
        "library_caches",
        "library_developer",
        "tmp_private",
        "tmp_pr_scratch",
        "tmp_task_scratch",
        "aside",
        "gemini_root",
        "library_logs",
        "local_dir",
        "worktrees_dot",
        "projects",
        "repos",
        "documents_codex",
        "codex_sessions",
        "codex_state_db",
        "claude_projects",
        "projects_reference",
        "private_var",
    ]
    for mkey in mandatory_keys:
        if mkey not in seen_keys and mkey in CATALOG_RULES:
            rule = CATALOG_RULES[mkey]
            items.append({
                "id": mkey,
                "name": rule["name"],
                "path": rule["path"],
                "size_gb": 0.0,
                "delta_gb": _compute_delta_gb(mkey, 0.0),
                "bucket": rule["bucket"],
                "category": rule["category"],
                "command": rule["command"],
                "explanation": rule["explanation"],
                "checked": bool(rule.get("checked", False)),
                "never_delete": bool(rule.get("never_delete", False)),
                "carried": False,
            })

    # Add System & Residual items explicitly so the treemap and script builder cover system residual, APFS snapshots, and code_sign_clones
    items.append({
        "id": "system_residual_unaccounted",
        "name": "Unaccounted / System Residual Space",
        "path": "/System/Volumes/Data (residual)",
        "size_gb": round(residual_gb, 2),
        "delta_gb": round(residual_delta_gb, 2),
        "bucket": "system",
        "category": "System & Residual",
        "command": "diskm cleanup-dirs-cleaner --clean",
        "explanation": "Unmeasured or system-staged space (/private/var/dirs_cleaner, deleted_helper); clean via diskm cleanup-dirs-cleaner --clean.",
        "checked": False,
        "never_delete": False,
        "carried": False,
    })
    items.append({
        "id": "apfs_local_snapshots",
        "name": f"APFS Local Snapshots ({local_snapshots_count} snapshots)",
        "path": "/System/Volumes/Data (APFS snapshots)",
        "size_gb": round(max(0.5, float(local_snapshots_count) * 1.2), 2) if local_snapshots_count > 0 else 0.0,
        "delta_gb": 0.0,
        "bucket": "system",
        "category": "System & Residual",
        "command": "diskm cleanup-apfs-snapshots --clean",
        "explanation": "Deletes local APFS (Time Machine) snapshots older than 1 day to release retained blocks.",
        "checked": False,
        "never_delete": False,
        "carried": False,
    })
    items.append({
        "id": "code_sign_clones",
        "name": "macOS Browser/App Code-Sign Clones",
        "path": "/private/var/folders/.../X/*.code_sign_clone",
        "size_gb": round(max(0.5, vm_volume_used_gb * 0.25), 2) if vm_volume_used_gb > 0 else 0.5,
        "delta_gb": 0.0,
        "bucket": "system",
        "category": "System & Residual",
        "command": "diskm cleanup-code-sign-clones --clean",
        "explanation": "Cleans stale macOS app code_sign_clone bundles under /private/var/folders.",
        "checked": False,
        "never_delete": False,
        "carried": False,
    })

    # Sort items by size descending
    items.sort(key=lambda x: (x["size_gb"], x["name"]), reverse=True)

    safe_gb = round(sum(i["size_gb"] for i in items if i["bucket"] == "safe"), 2)
    gated_gb = round(sum(i["size_gb"] for i in items if i["bucket"] == "gated"), 2)
    protected_gb = round(sum(i["size_gb"] for i in items if i["bucket"] == "protected"), 2)
    needs_review_total_gb = round(gated_gb + protected_gb, 2)
    system_total_gb = round(sum(i["size_gb"] for i in items if i["bucket"] == "system"), 2)

    return {
        "schema_version": 1,
        "generated_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "snapshot_path": str(snapshot_path),
        "frontier_path": str(frontier_path) if frontier_path else None,
        "hostname": str(snapshot.get("hostname") or "localhost"),
        "timestamp": timestamp,
        "disk_total_gb": round(disk_total_gb, 2),
        "disk_used_gb": round(disk_used_gb, 2),
        "disk_free_gb": round(disk_free_gb, 2),
        "disk_used_pct": round(disk_pct, 1),
        "snapshot_coverage_pct": round(coverage_pct, 1),
        "coverage_effective_pct": round(coverage_effective_pct, 1),
        "residual_gb": round(residual_gb, 2),
        "residual_delta_gb": round(residual_delta_gb, 2),
        "swap_used_gb": round(swap_used_gb, 2),
        "vm_volume_used_gb": round(vm_volume_used_gb, 2),
        "local_snapshots_count": local_snapshots_count,
        "local_snapshot_names": local_snapshot_names,
        "worktree_ledger": wt_ledger,
        "summary_buckets": {
            "free_right_now_gb": round(disk_free_gb, 2),
            "safe_to_remove_gb": safe_gb,
            "gated_review_gb": gated_gb,
            "protected_never_delete_gb": protected_gb,
            "needs_review_and_protected_gb": needs_review_total_gb,
            "system_and_residual_gb": system_total_gb,
        },
        "items": items,
    }


def render_html(model: Dict[str, Any]) -> str:
    """Render self-contained interactive HTML5 dashboard with Treemap & diskm Script Builder."""
    model_json = json.dumps(model, ensure_ascii=False, indent=None).replace("</", "<\\/")
    hostname = html.escape(str(model["hostname"]))
    ts = html.escape(str(model["timestamp"]))
    free_gb = model["disk_free_gb"]
    total_gb = model["disk_total_gb"]
    used_gb = model["disk_used_gb"]
    used_pct = model["disk_used_pct"]
    cov_pct = model["snapshot_coverage_pct"]
    eff_cov_pct = model["coverage_effective_pct"]
    safe_gb = model["summary_buckets"]["safe_to_remove_gb"]
    gated_gb = model["summary_buckets"]["gated_review_gb"]
    protected_gb = model["summary_buckets"]["protected_never_delete_gb"]
    review_prot_gb = model["summary_buckets"]["needs_review_and_protected_gb"]
    sys_res_gb = model["summary_buckets"]["system_and_residual_gb"]
    residual_gb = model["residual_gb"]
    snaps_cnt = model["local_snapshots_count"]
    snap_path = html.escape(str(model["snapshot_path"]))

    return f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8" />
<meta name="viewport" content="width=device-width, initial-scale=1.0" />
<title>Disk Magician (`diskm`) — Interactive Storage Treemap &amp; Safe Cleanup Report</title>
<style>
  :root {{
    --bg: #0b1020;
    --panel: #131b31;
    --panel-alt: #18223d;
    --border: #263459;
    --text: #e8eefc;
    --muted: #98a7c7;
    --safe: #10b981;
    --safe-bg: rgba(16, 185, 129, 0.14);
    --gated: #f59e0b;
    --gated-bg: rgba(245, 158, 11, 0.14);
    --protected: #6366f1;
    --protected-bg: rgba(99, 102, 241, 0.15);
    --system: #ec4899;
    --system-bg: rgba(236, 72, 153, 0.14);
    --free: #06b6d4;
    --free-bg: rgba(6, 182, 212, 0.14);
    --danger: #ef4444;
    --font: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Inter, sans-serif;
    --mono: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace;
  }}
  * {{
    box-sizing: border-box;
  }}
  html, body {{
    margin: 0;
    padding: 0;
    width: 100%;
    max-width: 100%;
    overflow-x: hidden;
    background: var(--bg);
    color: var(--text);
    font-family: var(--font);
    line-height: 1.45;
  }}
  .container {{
    max-width: 1400px;
    margin: 0 auto;
    padding: 16px 20px 40px;
    width: 100%;
  }}
  header.top-header {{
    display: flex;
    flex-wrap: wrap;
    justify-content: space-between;
    align-items: flex-start;
    gap: 12px;
    padding-bottom: 14px;
    border-bottom: 1px solid var(--border);
    margin-bottom: 16px;
  }}
  .brand-title {{
    margin: 0;
    font-size: 1.35rem;
    font-weight: 700;
    letter-spacing: -0.02em;
  }}
  .brand-sub {{
    margin: 4px 0 0;
    font-size: 0.84rem;
    color: var(--muted);
    word-break: break-all;
  }}
  .policy-pill {{
    display: inline-flex;
    align-items: center;
    gap: 6px;
    background: rgba(16, 185, 129, 0.12);
    border: 1px solid rgba(16, 185, 129, 0.4);
    color: #6ee7b7;
    padding: 6px 12px;
    border-radius: 999px;
    font-size: 0.78rem;
    font-weight: 600;
  }}
  /* 4 Top Summary Cards */
  .summary-grid {{
    display: grid;
    grid-template-columns: repeat(4, minmax(0, 1fr));
    gap: 12px;
    margin-bottom: 18px;
  }}
  .summary-card {{
    background: var(--panel);
    border: 1px solid var(--border);
    border-radius: 12px;
    padding: 14px 16px;
    display: flex;
    flex-direction: column;
    gap: 6px;
    min-width: 0;
  }}
  .summary-card.card-free {{ border-top: 3px solid var(--free); }}
  .summary-card.card-safe {{ border-top: 3px solid var(--safe); }}
  .summary-card.card-review {{ border-top: 3px solid var(--gated); }}
  .summary-card.card-system {{ border-top: 3px solid var(--system); }}
  .card-label {{
    font-size: 0.78rem;
    text-transform: uppercase;
    letter-spacing: 0.05em;
    color: var(--muted);
    font-weight: 600;
  }}
  .card-value {{
    font-size: 1.55rem;
    font-weight: 800;
    letter-spacing: -0.02em;
  }}
  .card-meta {{
    font-size: 0.8rem;
    color: var(--muted);
  }}
  /* Main 2-column workspace */
  .workspace-grid {{
    display: grid;
    grid-template-columns: minmax(0, 1.15fr) minmax(0, 0.85fr);
    gap: 16px;
    align-items: start;
  }}
  .panel {{
    background: var(--panel);
    border: 1px solid var(--border);
    border-radius: 12px;
    padding: 16px;
    min-width: 0;
  }}
  .panel-header {{
    display: flex;
    flex-wrap: wrap;
    justify-content: space-between;
    align-items: center;
    gap: 10px;
    margin-bottom: 12px;
  }}
  .panel-title {{
    margin: 0;
    font-size: 1.05rem;
    font-weight: 700;
  }}
  /* Filter pills */
  .filter-pills {{
    display: flex;
    flex-wrap: wrap;
    gap: 6px;
    margin-bottom: 12px;
  }}
  .filter-pill {{
    background: var(--panel-alt);
    color: var(--text);
    border: 1px solid var(--border);
    border-radius: 999px;
    padding: 5px 11px;
    font-size: 0.78rem;
    cursor: pointer;
    font-weight: 600;
    transition: all 0.15s ease;
  }}
  .filter-pill.active {{
    background: #2563eb;
    border-color: #60a5fa;
    color: #ffffff;
  }}
  /* Proportional Interactive Treemap */
  .treemap-viewport {{
    display: flex;
    flex-wrap: wrap;
    align-content: flex-start;
    gap: 6px;
    width: 100%;
    min-height: 360px;
    padding: 6px;
    background: #090e1c;
    border: 1px solid var(--border);
    border-radius: 10px;
  }}
  .treemap-tile {{
    position: relative;
    border-radius: 8px;
    padding: 8px 10px;
    cursor: pointer;
    overflow: hidden;
    display: flex;
    flex-direction: column;
    justify-content: space-between;
    min-height: 68px;
    transition: transform 0.12s ease, border-color 0.12s ease;
    border: 1px solid rgba(255, 255, 255, 0.14);
    min-width: 110px;
  }}
  .treemap-tile:hover, .treemap-tile.selected-tile {{
    transform: translateY(-1px);
    border-color: #ffffff;
    box-shadow: 0 4px 12px rgba(0, 0, 0, 0.45);
  }}
  .treemap-tile.bucket-safe {{
    background: linear-gradient(135deg, rgba(16, 185, 129, 0.28), rgba(5, 150, 105, 0.16));
    border-color: rgba(16, 185, 129, 0.5);
  }}
  .treemap-tile.bucket-gated {{
    background: linear-gradient(135deg, rgba(245, 158, 11, 0.28), rgba(217, 119, 6, 0.16));
    border-color: rgba(245, 158, 11, 0.5);
  }}
  .treemap-tile.bucket-protected {{
    background: linear-gradient(135deg, rgba(99, 102, 241, 0.28), rgba(79, 70, 229, 0.16));
    border-color: rgba(99, 102, 241, 0.5);
  }}
  .treemap-tile.bucket-system {{
    background: linear-gradient(135deg, rgba(236, 72, 153, 0.26), rgba(190, 24, 93, 0.15));
    border-color: rgba(236, 72, 153, 0.5);
  }}
  .tile-top {{
    display: flex;
    justify-content: space-between;
    align-items: flex-start;
    gap: 4px;
  }}
  .tile-name {{
    font-size: 0.78rem;
    font-weight: 700;
    line-height: 1.2;
    word-break: break-word;
  }}
  .tile-path {{
    font-family: var(--mono);
    font-size: 0.68rem;
    color: var(--muted);
    word-break: break-all;
    margin-top: 2px;
  }}
  .tile-bottom {{
    display: flex;
    flex-wrap: wrap;
    align-items: center;
    justify-content: space-between;
    gap: 4px;
    margin-top: 6px;
  }}
  .tile-size {{
    font-size: 0.86rem;
    font-weight: 800;
  }}
  .delta-badge {{
    display: inline-block;
    font-family: var(--mono);
    font-size: 0.68rem;
    font-weight: 700;
    padding: 1px 6px;
    border-radius: 4px;
  }}
  .delta-up {{
    background: rgba(239, 68, 68, 0.22);
    color: #fca5a5;
    border: 1px solid rgba(239, 68, 68, 0.4);
  }}
  .delta-down {{
    background: rgba(16, 185, 129, 0.22);
    color: #6ee7b7;
    border: 1px solid rgba(16, 185, 129, 0.4);
  }}
  /* Detail Inspector Box */
  .tile-inspector {{
    margin-top: 12px;
    padding: 12px;
    border-radius: 8px;
    background: var(--panel-alt);
    border: 1px solid var(--border);
    font-size: 0.84rem;
  }}
  .inspector-cmd {{
    display: block;
    margin-top: 6px;
    padding: 6px 8px;
    background: #090e1c;
    border-radius: 6px;
    font-family: var(--mono);
    font-size: 0.78rem;
    color: #93c5fd;
    word-break: break-all;
  }}
  /* Right-hand Recommendations & Script Builder */
  .builder-controls {{
    display: flex;
    flex-wrap: wrap;
    gap: 8px;
    margin-bottom: 12px;
  }}
  .btn {{
    background: #1e293b;
    color: var(--text);
    border: 1px solid #3b4f78;
    border-radius: 8px;
    padding: 7px 12px;
    font-size: 0.8rem;
    font-weight: 600;
    cursor: pointer;
    transition: background 0.15s ease;
  }}
  .btn:hover {{
    background: #2d3d5e;
  }}
  .btn-primary {{
    background: #059669;
    border-color: #10b981;
    color: #ffffff;
  }}
  .btn-primary:hover {{
    background: #047857;
  }}
  .script-preview-box {{
    background: #070b16;
    border: 1px solid var(--border);
    border-radius: 8px;
    padding: 10px 12px;
    margin-bottom: 14px;
  }}
  .script-preview-header {{
    display: flex;
    justify-content: space-between;
    align-items: center;
    font-size: 0.76rem;
    color: var(--muted);
    margin-bottom: 6px;
  }}
  pre#script-preview {{
    margin: 0;
    font-family: var(--mono);
    font-size: 0.76rem;
    color: #a7f3d0;
    white-space: pre-wrap;
    word-break: break-all;
    max-height: 210px;
    overflow-y: auto;
  }}
  .bucket-section {{
    margin-top: 14px;
  }}
  .bucket-section-title {{
    font-size: 0.85rem;
    font-weight: 700;
    margin: 0 0 8px;
    display: flex;
    justify-content: space-between;
    align-items: center;
  }}
  .rec-list {{
    display: flex;
    flex-direction: column;
    gap: 8px;
  }}
  .rec-row {{
    background: var(--panel-alt);
    border: 1px solid var(--border);
    border-radius: 8px;
    padding: 10px 12px;
    display: flex;
    align-items: flex-start;
    gap: 10px;
    min-width: 0;
  }}
  .rec-row input[type="checkbox"] {{
    margin-top: 3px;
    width: 16px;
    height: 16px;
    cursor: pointer;
    flex-shrink: 0;
  }}
  .rec-body {{
    flex: 1;
    min-width: 0;
  }}
  .rec-head {{
    display: flex;
    flex-wrap: wrap;
    justify-content: space-between;
    align-items: baseline;
    gap: 6px;
  }}
  .rec-name {{
    font-size: 0.85rem;
    font-weight: 700;
  }}
  .rec-size {{
    font-size: 0.84rem;
    font-weight: 800;
    font-family: var(--mono);
  }}
  .rec-path {{
    font-family: var(--mono);
    font-size: 0.73rem;
    color: var(--muted);
    word-break: break-all;
  }}
  .rec-cmd {{
    display: inline-block;
    margin-top: 4px;
    padding: 2px 6px;
    background: #090e1c;
    border: 1px solid #263459;
    border-radius: 4px;
    font-family: var(--mono);
    font-size: 0.72rem;
    color: #93c5fd;
    word-break: break-all;
  }}
  .rec-desc {{
    margin-top: 4px;
    font-size: 0.76rem;
    color: var(--muted);
  }}
  .lock-badge {{
    display: inline-flex;
    align-items: center;
    padding: 2px 7px;
    border-radius: 4px;
    font-size: 0.69rem;
    font-weight: 700;
    background: rgba(99, 102, 241, 0.2);
    color: #c7d2fe;
    border: 1px solid rgba(99, 102, 241, 0.45);
    flex-shrink: 0;
  }}
  @media (max-width: 1024px) {{
    .summary-grid {{
      grid-template-columns: repeat(2, minmax(0, 1fr));
    }}
    .workspace-grid {{
      grid-template-columns: minmax(0, 1fr);
    }}
  }}
  @media (max-width: 600px) {{
    .container {{
      padding: 12px 12px 28px;
    }}
    .summary-grid {{
      grid-template-columns: minmax(0, 1fr);
    }}
    .treemap-tile {{
      min-width: 100%;
      flex-basis: 100% !important;
    }}
  }}
</style>
</head>
<body>
<div class="container">
  <header class="top-header">
    <div>
      <h1 class="brand-title">Disk Magician (<code>diskm</code>) — Storage Treemap &amp; Cleanup Planner</h1>
      <p class="brand-sub">Host: <strong>{hostname}</strong> &bull; Snapshot: <code>{ts}</code> &bull; Source: <code>{snap_path}</code></p>
    </div>
    <div class="policy-pill">Canonical diskm Policy Enforced &bull; Never-Delete Protected</div>
  </header>

  <!-- 4 Top Summary Cards -->
  <section class="summary-grid" aria-label="Storage Summary Cards">
    <div class="summary-card card-free" id="card-free-right-now">
      <span class="card-label">1. Free right now</span>
      <span class="card-value">{free_gb:.1f} GiB <small style="font-size:0.85rem;font-weight:600;color:var(--muted);">/ {total_gb:.0f} GiB</small></span>
      <span class="card-meta">{used_gb:.1f} GiB used ({used_pct:.1f}%) &bull; Coverage: {cov_pct:.1f}% (effective {eff_cov_pct:.1f}%)</span>
    </div>
    <div class="summary-card card-safe" id="card-safe-to-remove">
      <span class="card-label">2. In safe-tier paths (upper bound)</span>
      <span class="card-value" style="color:var(--safe);">{safe_gb:.1f} GiB</span>
      <span class="card-meta">Rebuildable caches, temp scratch, Xcode, Colima sparse trim, rotated logs</span>
    </div>
    <div class="summary-card card-review" id="card-needs-review">
      <span class="card-label">3. Needs review &amp; Protected</span>
      <span class="card-value" style="color:var(--gated);">{review_prot_gb:.1f} GiB</span>
      <span class="card-meta">Gated worktrees/deps: {gated_gb:.1f} GiB &bull; Protected Never-Delete: {protected_gb:.1f} GiB</span>
    </div>
    <div class="summary-card card-system" id="card-system-residual">
      <span class="card-label">4. System &amp; Residual</span>
      <span class="card-value" style="color:var(--system);">{sys_res_gb:.1f} GiB</span>
      <span class="card-meta">Residual: {residual_gb:.1f} GiB &bull; APFS local snapshots: {snaps_cnt} &bull; dirs_cleaner &amp; clones</span>
    </div>
  </section>

  <!-- Main Workspace -->
  <div class="workspace-grid">
    <!-- Left Column: Proportional Interactive Treemap -->
    <section class="panel" aria-label="Proportional Interactive Treemap">
      <div class="panel-header">
        <h2 class="panel-title">Proportional Storage Treemap (GiB)</h2>
        <span style="font-size:0.78rem;color:var(--muted);">Click any tile to inspect its canonical <code>diskm</code> command</span>
      </div>
      <div class="filter-pills" id="category-filters" role="tablist" aria-label="Category Filters">
        <button type="button" class="filter-pill active" data-filter="all">All Categories</button>
        <button type="button" class="filter-pill" data-filter="safe">Safe via diskm</button>
        <button type="button" class="filter-pill" data-filter="gated">Gated Worktrees</button>
        <button type="button" class="filter-pill" data-filter="protected">Protected (Never-Delete)</button>
        <button type="button" class="filter-pill" data-filter="system">System &amp; Residual</button>
      </div>
      <div class="treemap-viewport" id="treemap-container"></div>
      <div class="tile-inspector" id="tile-inspector">
        <strong>Selected Bucket Details:</strong> <span id="inspector-title">Click a treemap tile above to inspect path, growth delta, and canonical <code>diskm</code> action.</span>
        <div id="inspector-meta" style="margin-top:4px;color:var(--muted);"></div>
        <code class="inspector-cmd" id="inspector-cmd">diskm status</code>
      </div>
    </section>

    <!-- Right Column: Recommendations & Canonical diskm Script Builder -->
    <section class="panel" aria-label="Recommendations and Canonical diskm Script Builder">
      <div class="panel-header">
        <h2 class="panel-title">Recommendations &amp; Canonical <code>diskm</code> Script Builder</h2>
      </div>
      <div class="builder-controls">
        <button type="button" class="btn" id="btn-select-safe">Select safe</button>
        <button type="button" class="btn" id="btn-toggle-mode" data-mode="clean">Toggle dry-run / --clean (Current: --clean)</button>
        <button type="button" class="btn btn-primary" id="btn-copy-script">Copy diskm script</button>
      </div>
      <div class="script-preview-box">
        <div class="script-preview-header">
          <span>Generated Canonical <code>diskm</code> Cleanup Script</span>
          <span id="selected-reclaim-summary">Selected reclaimable: 0.0 GiB</span>
        </div>
        <pre id="script-preview"></pre>
      </div>

      <div class="bucket-section">
        <h3 class="bucket-section-title" style="color:var(--safe);">
          <span>Safe tier (via diskm; commands prune selected contents, so this is an upper bound) — Checked by default</span>
          <span>{safe_gb:.1f} GiB</span>
        </h3>
        <div class="rec-list" id="list-safe"></div>
      </div>

      <div class="bucket-section">
        <h3 class="bucket-section-title" style="color:var(--gated);">
          <span>Gated / Review first (Worktrees &amp; System) — Unchecked by default</span>
          <span>{gated_gb:.1f} GiB</span>
        </h3>
        <div class="rec-list" id="list-gated"></div>
      </div>

      <div class="bucket-section">
        <h3 class="bucket-section-title" style="color:var(--protected);">
          <span>Protected (Never-Delete List &amp; Active User Data)</span>
          <span>{protected_gb:.1f} GiB</span>
        </h3>
        <div class="rec-list" id="list-protected"></div>
      </div>
    </section>
  </div>
</div>

<script id="disk-report-data" type="application/json">{model_json}</script>
<script>
(function() {{
  const dataEl = document.getElementById("disk-report-data");
  const REPORT = JSON.parse(dataEl.textContent);
  const items = REPORT.items || [];
  let currentFilter = "all";
  let currentMode = "clean"; // "clean" or "dry-run"
  const checkedState = {{}};

  items.forEach(function(item) {{
    checkedState[item.id] = Boolean(item.checked) && !item.never_delete && item.bucket === "safe";
  }});

  function formatDeltaBadge(delta) {{
    if (typeof delta !== "number" || Math.abs(delta) < 0.05) {{
      return "";
    }}
    const sign = delta > 0 ? "+" : "";
    const cls = delta > 0 ? "delta-badge delta-up" : "delta-badge delta-down";
    return '<span class="' + cls + '">' + sign + delta.toFixed(1) + ' GB</span>';
  }}

  function escapeHtml(str) {{
    return String(str || "")
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;");
  }}

  function formatCommandForMode(cmd, mode) {{
    if (!cmd || cmd.indexOf("diskm ") === -1) {{
      return cmd;
    }}
    if (mode === "dry-run") {{
      return cmd.replace(/--clean\\b/g, "--dry-run");
    }}
    return cmd.replace(/--dry-run\\b/g, "--clean");
  }}

  function inspectItem(item) {{
    const titleEl = document.getElementById("inspector-title");
    const metaEl = document.getElementById("inspector-meta");
    const cmdEl = document.getElementById("inspector-cmd");
    titleEl.textContent = item.name + " (" + item.size_gb.toFixed(2) + " GiB)";
    metaEl.textContent = "Path: " + item.path + " | Category: " + item.category + " | " + item.explanation;
    cmdEl.textContent = formatCommandForMode(item.command, currentMode);
    document.querySelectorAll(".treemap-tile").forEach(function(el) {{
      el.classList.toggle("selected-tile", el.getAttribute("data-id") === item.id);
    }});
  }}

  function renderTreemap() {{
    const container = document.getElementById("treemap-container");
    container.innerHTML = "";
    const filtered = items.filter(function(it) {{
      if (currentFilter !== "all" && it.bucket !== currentFilter) {{
        return false;
      }}
      return it.size_gb > 0 || it.bucket === currentFilter;
    }});
    const totalShownGb = filtered.reduce(function(acc, it) {{
      return acc + Math.max(0.25, it.size_gb);
    }}, 0) || 1;

    filtered.forEach(function(item) {{
      const weight = Math.max(0.25, item.size_gb) / totalShownGb;
      const pctBasis = Math.max(14, Math.min(100, Math.round(weight * 185)));
      const heightPx = Math.max(74, Math.min(180, Math.round(70 + Math.sqrt(Math.max(0, item.size_gb)) * 11)));
      const tile = document.createElement("div");
      tile.className = "treemap-tile bucket-" + item.bucket;
      tile.setAttribute("data-id", item.id);
      tile.setAttribute("data-bucket", item.bucket);
      tile.style.flex = Math.max(1, Math.round(weight * 100)) + " 1 " + pctBasis + "%";
      tile.style.minHeight = heightPx + "px";

      const lockTag = item.never_delete ? '<span class="lock-badge">PROTECTED</span>' : '';
      const deltaTag = formatDeltaBadge(item.delta_gb);

      tile.innerHTML =
        '<div class="tile-top">' +
          '<div>' +
            '<div class="tile-name">' + escapeHtml(item.name) + '</div>' +
            '<div class="tile-path">' + escapeHtml(item.path) + '</div>' +
          '</div>' +
          lockTag +
        '</div>' +
        '<div class="tile-bottom">' +
          '<span class="tile-size">' + item.size_gb.toFixed(1) + ' GiB</span>' +
          deltaTag +
        '</div>';

      tile.addEventListener("click", function() {{
        inspectItem(item);
      }});
      container.appendChild(tile);
    }});
  }}

  function updateScriptPreview() {{
    const previewEl = document.getElementById("script-preview");
    const summaryEl = document.getElementById("selected-reclaim-summary");
    const lines = [
      "#!/usr/bin/env bash",
      "# Canonical Disk Magician (diskm) cleanup script",
      "# Mode: --" + currentMode + " (Never-Delete paths are strictly protected)",
      "set -euo pipefail",
      ""
    ];
    const seenCommands = new Set();
    let totalSelectedGb = 0;

    items.forEach(function(item) {{
      if (checkedState[item.id] && !item.never_delete && item.command && item.command.indexOf("diskm ") !== -1) {{
        totalSelectedGb += item.size_gb;
        const formattedCmd = formatCommandForMode(item.command, currentMode);
        if (!seenCommands.has(formattedCmd)) {{
          seenCommands.add(formattedCmd);
          // Snapshot-supplied text: strip control characters so it cannot leave the comment.
          const safeText = (v) => String(v).replace(/[\\u0000-\\u001f\\u007f]/g, " ");
          lines.push("# " + safeText(item.name) + " (" + safeText(item.path) + " — " + item.size_gb.toFixed(1) + " GiB)");
          lines.push(formattedCmd);
        }}
      }}
    }});

    if (seenCommands.size === 0) {{
      lines.push("# No cleanup targets selected. Tick safe or gated items below.");
    }}
    previewEl.textContent = lines.join("\\n");
    summaryEl.textContent = "Selected reclaimable: " + totalSelectedGb.toFixed(1) + " GiB (" + seenCommands.size + " diskm commands)";
  }}

  function renderRecommendationLists() {{
    const listSafe = document.getElementById("list-safe");
    const listGated = document.getElementById("list-gated");
    const listProtected = document.getElementById("list-protected");
    listSafe.innerHTML = "";
    listGated.innerHTML = "";
    listProtected.innerHTML = "";

    items.forEach(function(item) {{
      const row = document.createElement("div");
      row.className = "rec-row";
      row.setAttribute("data-item-id", item.id);

      const deltaHtml = formatDeltaBadge(item.delta_gb);
      const isSelectable = !item.never_delete && item.command && item.command.indexOf("diskm ") !== -1 && (item.bucket === "safe" || item.bucket === "gated" || item.bucket === "system");

      if (isSelectable) {{
        const cb = document.createElement("input");
        cb.type = "checkbox";
        cb.checked = Boolean(checkedState[item.id]);
        cb.setAttribute("data-id", item.id);
        cb.setAttribute("aria-label", item.name);
        cb.addEventListener("change", function() {{
          checkedState[item.id] = cb.checked;
          updateScriptPreview();
        }});
        row.appendChild(cb);
      }} else {{
        const lockSpan = document.createElement("span");
        lockSpan.className = "lock-badge";
        lockSpan.textContent = "PROTECTED";
        row.appendChild(lockSpan);
      }}

      const body = document.createElement("div");
      body.className = "rec-body";
      body.innerHTML =
        '<div class="rec-head">' +
          '<span class="rec-name">' + escapeHtml(item.name) + '</span>' +
          '<span>' + deltaHtml + ' <span class="rec-size">' + item.size_gb.toFixed(1) + ' GiB</span></span>' +
        '</div>' +
        '<div class="rec-path">' + escapeHtml(item.path) + '</div>' +
        '<code class="rec-cmd">' + escapeHtml(formatCommandForMode(item.command, currentMode)) + '</code>' +
        '<div class="rec-desc">' + escapeHtml(item.explanation) + '</div>';

      row.appendChild(body);

      if (item.bucket === "safe") {{
        listSafe.appendChild(row);
      }} else if (item.bucket === "gated" || (item.bucket === "system" && isSelectable)) {{
        listGated.appendChild(row);
      }} else {{
        listProtected.appendChild(row);
      }}
    }});
  }}

  // Filter pill listeners
  document.querySelectorAll("#category-filters .filter-pill").forEach(function(btn) {{
    btn.addEventListener("click", function() {{
      document.querySelectorAll("#category-filters .filter-pill").forEach(function(b) {{
        b.classList.remove("active");
      }});
      btn.classList.add("active");
      currentFilter = btn.getAttribute("data-filter") || "all";
      renderTreemap();
    }});
  }});

  // Select safe button
  document.getElementById("btn-select-safe").addEventListener("click", function() {{
    items.forEach(function(item) {{
      checkedState[item.id] = (item.bucket === "safe" && !item.never_delete);
    }});
    renderRecommendationLists();
    updateScriptPreview();
  }});

  // Toggle dry-run / --clean button
  const toggleBtn = document.getElementById("btn-toggle-mode");
  toggleBtn.addEventListener("click", function() {{
    currentMode = currentMode === "clean" ? "dry-run" : "clean";
    toggleBtn.setAttribute("data-mode", currentMode);
    toggleBtn.textContent = "Toggle dry-run / --clean (Current: --" + currentMode + ")";
    renderRecommendationLists();
    updateScriptPreview();
  }});

  // Copy diskm script button
  const copyBtn = document.getElementById("btn-copy-script");
  copyBtn.addEventListener("click", function() {{
    const text = document.getElementById("script-preview").textContent;
    if (navigator.clipboard && navigator.clipboard.writeText) {{
      navigator.clipboard.writeText(text).catch(function() {{}});
    }}
    copyBtn.textContent = "Copied canonical diskm script!";
    setTimeout(function() {{
      copyBtn.textContent = "Copy diskm script";
    }}, 1600);
  }});

  renderTreemap();
  renderRecommendationLists();
  updateScriptPreview();
}})();
</script>
</body>
</html>
"""


def main(argv: Optional[List[str]] = None) -> int:
    if argv is None:
        argv = sys.argv[1:]

    parser = argparse.ArgumentParser(
        prog="diskm report",
        description="Generate an interactive self-contained HTML Treemap & canonical diskm cleanup report from disk_snapshot.json + frontier_last.json (<1s, zero du).",
    )
    parser.add_argument(
        "--html",
        action="store_true",
        default=True,
        help="Generate interactive HTML report (default: enabled)",
    )
    parser.add_argument(
        "--output",
        "-o",
        default=None,
        help="Output HTML file path (default: ~/.disk_magician_state/disk_report.html)",
    )
    parser.add_argument(
        "--snapshot",
        default=None,
        help="Explicit path to disk_snapshot.json",
    )
    parser.add_argument(
        "--frontier",
        default=None,
        help="Explicit path to frontier_last.json or topdown-5g.json",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        default=False,
        help="Emit JSON summary to stdout",
    )
    args = parser.parse_args(argv)

    snapshot_path = resolve_default_snapshot_path(args.snapshot)
    if not snapshot_path.is_file():
        print(f"diskm report: snapshot file not found at {snapshot_path}", file=sys.stderr)
        return 1

    try:
        snapshot_data = json.loads(snapshot_path.read_text(encoding="utf-8"))
    except Exception as exc:
        print(f"diskm report: failed to parse snapshot JSON {snapshot_path}: {exc}", file=sys.stderr)
        return 2

    frontier_path = resolve_default_frontier_path(args.frontier, snapshot_path=snapshot_path)
    frontier_data: Optional[Dict[str, Any]] = None
    if frontier_path and frontier_path.is_file():
        try:
            frontier_data = json.loads(frontier_path.read_text(encoding="utf-8"))
        except Exception:
            frontier_data = None

    if args.output:
        output_path = Path(os.path.abspath(os.path.expanduser(args.output)))
    else:
        default_state_dir = Path(os.environ.get("DISK_MAGICIAN_STATE_DIR", str(Path.home() / ".disk_magician_state")))
        output_path = Path(os.path.abspath(str(default_state_dir / "disk_report.html")))

    model = build_report_model(
        snapshot=snapshot_data,
        frontier=frontier_data,
        snapshot_path=snapshot_path,
        frontier_path=frontier_path,
    )

    output_path.parent.mkdir(parents=True, exist_ok=True)
    html_content = render_html(model)
    output_path.write_text(html_content, encoding="utf-8")

    if args.json:
        summary_payload = {
            "status": "ok",
            "output_path": str(output_path),
            "snapshot_path": str(snapshot_path),
            "frontier_path": str(frontier_path) if frontier_path else None,
            "hostname": model["hostname"],
            "timestamp": model["timestamp"],
            "disk_total_gb": model["disk_total_gb"],
            "disk_used_gb": model["disk_used_gb"],
            "disk_free_gb": model["disk_free_gb"],
            "disk_used_pct": model["disk_used_pct"],
            "snapshot_coverage_pct": model["snapshot_coverage_pct"],
            "summary_buckets": model["summary_buckets"],
            "item_count": len(model["items"]),
        }
        print(json.dumps(summary_payload, indent=2))
    else:
        sb = model["summary_buckets"]
        print(
            f"Disk Magician HTML Report generated: {output_path}\n"
            f"  Snapshot: {snapshot_path} ({model['timestamp']})\n"
            f"  Free right now: {model['disk_free_gb']:.1f} GiB / {model['disk_total_gb']:.0f} GiB "
            f"({model['disk_used_pct']:.1f}% used, coverage {model['snapshot_coverage_pct']:.1f}%)\n"
            f"  In safe-tier paths (upper bound): {sb['safe_to_remove_gb']:.1f} GiB\n"
            f"  Needs review & Protected:   {sb['needs_review_and_protected_gb']:.1f} GiB "
            f"(Gated: {sb['gated_review_gb']:.1f} GiB, Protected: {sb['protected_never_delete_gb']:.1f} GiB)\n"
            f"  System & Residual:          {sb['system_and_residual_gb']:.1f} GiB"
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
