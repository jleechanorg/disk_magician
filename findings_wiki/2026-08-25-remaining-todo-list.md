---
title: Remaining TODO list — disk cleanup + snapshot health (post-30d-floor sweep)
hostname: jeffreys-macbook-pro
date: 2026-08-25
status: active
paths:
  - ~/.aside
  - ~/.gemini
  - ~/.hermes
  - ~/.codex
  - /private/tmp
  - /private/var/folders
companion: 2026-08-25-reclaim-catalog.md, 2026-08-25-topdown-bucket-verdict.md, /tmp/cross-ref-verdict.md
live_state:
  used: 775 GiB
  free: 96 GiB (89% full)
  floor_30d: 627 GiB @ 2026-08-02
  head: 838 GiB @ 2026-08-25
  delta_30d: +211 GiB
  residual: 491 GiB (58.5%, frontier_unfinished=112,267)
  session_reclaim: ~99 GiB
safety_rule: workspace-level; never override CLAUDE.md hard list
---

> **Status correction (2026-08-27):** The FDA limitation statements below
> describe the 2026-08-25 audit and are historical. FDA-enabled verification
> on 2026-08-27 confirmed that this shell can read representative MobileSync,
> Mail, and Messages paths. Replace the old FDA gate with a fresh scan and
> coverage check; do not treat the old residual as permanently opaque until
> that run completes.

# Remaining TODO — 2026-08-25 disk cleanup + snapshot health

## 1. Priority-ranked TODO table

| # | Action | Reclaim (GiB) | Gate / dependency | Source | Priority |
|---|---|---:|---|---|---|
| 1 | Refresh frontier scan with 0.2.58 (post-rebuild) | up to 491 mapped | Auto (next 35-min cycle) | `frontier_unfinished=112,267`; CLAUDE.md "Frontier scan"; `project_2026-08-25_snapshot_pipeline_healthy_legacy_path_stale` | **HIGH** |
| 2 | Add `safety.local.json` rule wired to catalog findings | 0 (safety) | Manual edit (5 min) | `findings_wiki/2026-08-25-reclaim-catalog.md` (catalog committed but not wired into `safety.local.json`) | **HIGH** |
| 3 | ms-playwright cache cleanup (`Library/Caches/ms-playwright`) | ~1.8 | None (regenerable; `npx playwright install`) | `/tmp/cross-ref-verdict.md` SAFE-CLEAN row; `feedback_2026-07-17_exclude_global_npm_dirs_from_bulk_cleanup` (still applies — global caches excluded) | **HIGH** |
| 4 | `cleanup_antigravity_brain.sh --clean --days 14` | ~0.065 | None | `.gemini` brain dirs >7d; `cleanup_antigravity_brain.sh` exists; default DRY-RUN, just needs `--clean` | **HIGH** |
| 5 | Close Aside → run Aside cache cleanup (`Library/Application Support/Aside` + `.aside`) | ~4.3 | App-closed (Aside running, last mod 13:47) | `/tmp/cross-ref-verdict.md` GATED-APP row; `cleanup_code_sign_clones.sh` covers Aside clones; Aside-side code_sign_clone not killable via LSEnvironment (`findings_wiki/2026-08-25-codesign-clone-killswitch-side-effects.md`) | **HIGH** |
| 6 | Close Chrome → Chrome cache cleanup (`Library/Application Support/Google`) | ~3.5 | App-closed (Chrome `LSEnvironment` kill switch already applied this session) | `/tmp/cross-ref-verdict.md` GATED-APP row; LSEnvironment killswitch active; clones drop on next launch | **HIGH** |
| 7 | Close Cursor → run `cleanup_code_sign_clones.sh` for ShipIt cache | ~1.2-2.4 | App-closed | `Library/Caches/com.todesktop.230313mzl4w4u92.ShipIt` (1.2 GiB measured; 2.4 GiB ledger — unit skew); code_sign_clone class | **MED** |
| 8 | Add bead + runbook for next swarm mission (sidekick protocol) | 0 (process) | None — open bead via `br create` | `feedback_2026-08-21_consult_memory_before_live_probes`, `feedback_2026-07-29_busy_teammates_dont_see_inbox_enforce_at_process_level` | **MED** |
| 9 | Fix `disk_snapshot.sh` unit-skew bug (historical ledger floor values) | 0 (correctness) | Code change + test; needs pyproject bump + `uv tool install --force --reinstall` | Ledger 2.4 GiB vs measured 1.2 GiB (ShipIt) and 4.2 GiB project_reference vs 8.0 GiB measured; CLAUDE.md "Snapshot JSON is schema_version 2" + "Deployment — commit is NOT deploy" | **MED** |
| 10 | `WORKTREE_APPROVED=1 ./scripts/cleanup_worktree_venvs.sh --clean` | ~25 | Operator literal approval | `feedback_2026-07-29_root_cause_disk_full.md` #1 (agent venvs); uses `worktree_recency.sh` (PR #50) | **MED** |
| 11 | `WORKTREE_APPROVED=1 ./scripts/cleanup_worktrees.sh --clean` | ~30 | Operator literal approval | `feedback_2026-07-29_root_cause_disk_full.md` #2 (abandoned `~/.worktrees/*`); 14-day rule + `worktree_recency.sh` | **MED** |
| 12 | `AGENT_ARTIFACTS_APPROVED=1 ./scripts/cleanup_agent_artifacts.sh --clean` | varies (unowned `/private/tmp` scratch ~8.4 GiB) | Operator literal approval | `feedback_2026-07-29_root_cause_disk_full.md` #3 (unowned `/private/tmp`) | **MED** |
| 13 | Investigate `worldarchitect.ai.worktrees` (1.0 GiB ledger; not covered by `cleanup_worktrees.sh`) | ~1.0 (if cleanable) | Bucket-level inspection before verdict | `/tmp/cross-ref-verdict.md` INVESTIGATE row; `cleanup_worktrees.sh` only walks `<repo>/.claude/worktrees` | **LOW** |
| 14 | Investigate `.local/share` (2.5 GiB; mixed uv tools etc.) | unknown | Exclude `~/.local/share/uv/tools/*` from any bulk enumeration | `feedback_2026-07-17_exclude_global_npm_dirs_from_bulk_cleanup.md`; INVESTIGATE row | **LOW** |
| 15 | APFS local snapshots purge (`./scripts/cleanup_apfs_snapshots.sh`) | up to 291 GiB (residual unmapped) | **Interactive sudo password** — operator must enter manually | `project_2026-07-29_disk_rootcause_producers_and_decisions.md`; `diskm` has no `sudo` path under FDA shell | **LOW (blocked)** |
| 16 | TCC/SIP `~/Library` gap (MobileSync, Mail, Messages, ~20 protected subtrees, 4 SIP dotdirs) | ~213.9 (historical estimate) | FDA verified 2026-08-27; run a fresh scan and coverage check | `project_2026-07-15_disk_swing_mechanisms_confirmed.md`; historical non-FDA audit | **HIGH — RESCAN** |
| 17 | Aside / Codex code_sign_clone disable upstream | 0 (workaround, not direct reclaim) | Upstream Electron/Chromium cooperation | `findings_wiki/2026-08-25-codesign-clone-killswitch-side-effects.md`; no documented mechanism for non-Chrome | **OUT OF SCOPE** |

## 2. Quick wins (gated only by env var or ~5 min manual; can run immediately)

| Cmd | Reclaim | Gate |
|---|---|---|
| `./scripts/cleanup_antigravity_brain.sh --clean --days 14` | ~65 MiB | None (DRY-RUN → `--clean`) |
| `./scripts/cleanup_ms_playwright.sh` (or manual `rm -rf ~/Library/Caches/ms-playwright/*`) | ~1.8 GiB | None (regenerable via `npx playwright install`) |
| Add `safety.local.json` rules wired to catalog | 0 (safety) | None |
| Open bead for next sidekick swarm protocol | 0 (process) | None |
| Fix `disk_snapshot.sh` unit-skew + add regression test | 0 (correctness) | Code change + test |

## 3. Long-horizon (FDA, sudo, or upstream)

- **FDA-enabled rescan** (~213.9 GiB historical estimate): MobileSync backups, Mail, Messages, ~20 protected `~/Library` subtrees, 4 SIP dotdirs. FDA verification on 2026-08-27 confirms representative reads from this shell; run the frontier scan and verify coverage before updating the ledger or making cleanup decisions.
- **Interactive-sudo APFS snapshots**: `disk_magician.sh cleanup-apfs-snapshots` requires TTY sudo password entry. The 2h pressure-sweep job already gates on `free<40G`; this reclaim is reserved for emergency.
- **Aside / Codex code_sign_clone** kill switch: requires upstream cooperation in Electron / Chromium embedding. The Chrome flag (`--disable-features=MacAppCodeSignClone`) works; `LSEnvironment` is applied. For Aside/Codex, only `rm -rf` of clones works, gated by `cleanup_code_sign_clones.sh` after each app quit.
- **Worktree venvs + abandoned worktrees** (~55 GiB combined): env-var gated (`WORKTREE_APPROVED=1`) — operator's choice. The 14-day rule + `worktree_recency.sh` (PR #50 commit 9d702c6) is the canonical gate; proxies (`stat <wt>/.git`) were banned 2026-07-26.

## 4. Should NOT be done (tempting but wrong)

- **Hand-`rm` `~/.codex/sessions*`, `~/.codex/state*.sqlite`, `~/.codex/log`, `~/.claude/projects`**: hard-list in CLAUDE.md; route through scripts only. Codex corpus is the user's permanent record-of-work per `feedback_2026-06-13_leave_codex_sessions_alone.md`.
- **Touch `.local/share/uv/tools/*` or any tool-manager install dir** (`~/.nvm`, `~/.cargo/bin`, `~/.pyenv`): `feedback_2026-07-17_exclude_global_npm_dirs_from_bulk_cleanup.md` documents 24 broken symlinks from a similar bulk pass.
- **Ad-hoc `rm -rf` of worktrees** to bypass `WORKTREE_APPROVED`: CLAUDE.md "Strict ban on ad-hoc cleanup scripts" mandates `cleanup_worktrees.sh` or `worktree_hygiene.sh`, which enforce the 14-day recency gate. Writing a fresh script to skip the gate is forbidden.
- **Force `git worktree remove` on a `gitdir:`-pointer linked worktree without recency check**: same ban — proxies (`stat <wt>/.git` measures creation age, `stat <wt>` measures only top-level mtime) mis-flagged 2/30 worktrees by 7.6 days in the 2026-07-26 audit.
- **Run `cleanup_apfs_snapshots.sh` without TTY sudo**: it fails closed; do not bypass. APFS container is structural — purge requires deliberate operator decision, not an autonomous sweep.
- **Edit `safety.local.json` to whitelist codex/corral/protected paths to "free up space"**: that path is exactly what `feedback_2026-07-18_manifest_claim_without_durable_path` warns against — deletions become unverifiable and non-recoverable.
- **Treat 491 GiB residual as "missing" or "leaked"**: the 2026-08-25 cross-ref verdict attributed it to the **213.9 GiB TCC/SIP gap** + **APFS container min-size pinning** + **<14d worktrees PROTECTED** — not by an unnamed leak. That attribution was based on a non-FDA audit; rerun the frontier scan with verified FDA before retaining the residual as opaque.

## Notes

- The session already shipped: 0.2.57→0.2.58 rebuild, LSEnvironment kill switch for Chrome, all safe cleanup scripts run, `findings_wiki/2026-08-25-{reclaim-catalog,topdown-bucket-verdict,code-sign-clone-attribution,codesign-clone-killswitch-side-effects,snapshot-pipeline-healthy-legacy-path-stale}.md` all committed.
- The 30d delta story is still: floor 627 → head 838 = +211 GiB, of which ~99 GiB was reclaimed this session. Structural floor (post-cleanup) is now in the 700-740 GiB range, consistent with the 213.9 GiB TCC/SIP + APFS container pinning baseline.
- The frontier scan is the highest-value single follow-up because it maps the 491 GiB unmapped residual into buckets — without it, "what's left" is structurally incomplete.
