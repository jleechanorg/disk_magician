# Disk reliability: 30-day investigation and code-standards review

Date: 2026-10-03. Requested scope: `/history`, `/ms`, `/cs`, and `/sq` for September 3–October 3. Planning and review only; no cleanup, service repair, deployment, commit, or push was performed by this session. Existing staged, unstaged, and untracked work was preserved.

## Conclusion

The recurring struggle is a broken chain between producers, cleanup eligibility, scheduled execution, usable measurements, and verification. The repository has substantial machinery and earlier designs. It lacks a dependable end-to-end answer to: what ran, using which code, what was measured, what was skipped, what changed, and which prevention obligation remains open.

The highest-value redesign is to finish and connect existing work: queryable partial evidence without weakening the canonical floor, typed job outcomes, one operational status, reconciled existing catalogs, and verified deployment. Adding another independent scanner or cleanup scheduler would increase the same coordination burden.

## Review basis and limits

The committed baseline is [the October 3 snapshot reliability change](https://github.com/jleechanorg/disk_magician/commit/5e75836d3380979fa0cb1e3fc650f20ea64925bd), prod +1375/-155 including package mirrors; non-prod +1144/-6. The review also examined pre-existing uncommitted routine-cleanup changes. The commit does not identify those changes. Source hashes and scope distinctions are in the independent [code review](/tmp/disk-redesign-20261003-cs.md).

At 22:46Z another session committed the existing cleanup work in [the routine-maintenance change](https://github.com/jleechanorg/disk_magician/commit/88b6bffb3da191834f68979abd932e936d29d2b6), prod +1427/-25 including mirrors; non-prod +1245/-27. A fresh head read and comparison confirmed the four hashes listed by the reviewer (renderer, fleet checker, sweeper health, Codex maintenance) remained identical. Findings against those bytes therefore remain applicable; previously proposed cleanup code is now committed. This session did not create that commit. No extra tests are credited to that commit merely because the head moved.

No fresh whole-disk sweep was launched. This was a recurrence/design audit; repository policy gives historical ledger evidence priority over another loaded-disk scan. The bounded residual helper did not finish within 25 seconds; its result remains unknown. No residual or reclaimable-byte explanation is inferred from that timeout.

## Live observations, with their actual scope

| Observation | Evidence | Meaning |
|---|---|---|
| 18/18 launchd jobs loaded and valid at the initial check | `./disk_magician.sh check-launchd-fleet` | Point-in-time registration and plist validity; not successful execution or cleanup proof. The same command warned that the ledger was stale. |
| Latest published canonical ledger was captured August 31 06:53Z; its last commit was August 30 23:56 PDT | State-repo Git history and `ledger/topdown-5g.json` | Roughly 34 days old. It cannot supply current bucket deltas. |
| No canonical ledger commits in the requested window | `git log --since=2026-09-03T00:00:00-07:00 -- ledger/topdown-5g.json` | The strict attribution history did not advance even though routine snapshots did. |
| Strict 14-day floor unavailable | `python3 scripts/history_diff.py --days 14` returned `no valid ledger snapshots in the last 14 days` | No trustworthy canonical floor, gap-to-floor, or per-bucket before/after table can be manufactured for this audit. |
| 984 routine snapshot commits; 23 of 29 latest-per-day samples below 70% coverage | [Daily sample](/tmp/disk-redesign-20261003-daily-coverage.json) | A declared daily sample, not an exhaustive rate across all 984 runs. The samples span September 5–October 3; September 3–4 had no selected committed day. |
| October 3 22:19Z routine snapshot had 3.4% coverage and 34 timeout keys | [Captured baseline](/tmp/disk-redesign-20261003-baseline.json) | Ineligible as the required floor. Low coverage is an attribution failure, not proof those bytes are reclaimable. |
| October 3 frontier was partial despite user FDA being granted | Same baseline, `frontier.coverage_envelope` and `frontier_unfinished` | Specific system/fixture permission failures remain. This is not evidence for a giant unreadable user-TCC bucket. |
| Installed pressure-sweep plist had no scratch-budget setting; script defaults to 0 | Read-only `plutil -convert json -o -` and `scripts/pressure_sweep.sh:44` | Scratch-budget eviction is disabled in the inspected installed configuration. This review did not enable it. |
| Installed uv package was 0.2.124; three sampled snapshot/alert files matched the repo byte-for-byte | Installed metadata and direct comparison of `disk_snapshot.sh`, `snapshot_measure.py`, `disk_usage_alert.sh` | Installation file mtime 22:37Z was later than the 22:19Z snapshot. That snapshot does not prove the new reliability change failed. Full deployed-package identity and subsequent scheduled success were not established by this sample. |

## What the history says

The [history lane](/tmp/disk-redesign-20261003-history.md) contains timestamped source pointers and separates recorded assistant claims from verified outcomes.

| Period | Recurring failure pattern | Status of the evidence |
|---|---|---|
| September 6–7 | Fleet repairs were followed by apparent flapping. A September 7 plan prioritized concurrent installer calls. | Historical hypothesis in `/Users/jleechan/roadmap/2026-09-07-disk-magician-launchd-fleet-flapping-plan-micro.md`; not adopted as the final cause. |
| September 11 | An investigating agent itself overwrote live plists by extracting fields without `-o -`. Repair could be undone by the next inspection. | Reproduced historical incident recorded in `findings_wiki/2026-09-11-plutil-extract-in-place-rewrite-corrupts-plists.md` and the dated Claude memory. It explains that specific corruption mechanism; it does not prove every earlier outage had the same cause. |
| September 11–13 | Five design lanes discovered overlapping file ownership and work already implemented elsewhere. | Selected Claude transcript events; implementation and review coordination consumed work without proving operational closure. |
| September 23–25 | Repeated prevention-plan reviews found authorization, dependency order, Darwin temporary-root coverage, and deployment/evidence gaps. | Selected Codex reviews. Review rounds are not measurements of reclaimed capacity. |
| October 3 | The same recurrence question returns; canonical accounting remains stale while prior implementation and verification tasks remain open. | Current read-only measurements plus fresh `br` queries. |

The September 23 design already identified growing young scratch, agent-created clones, code-sign clones, and other producer classes. Its historical size estimates are not repeated as current reclaimable amounts. The current prevention epic has 3 closed and 23 open children in the inspected tracker state. Open implementation/activation/verification work is evidence of unfinished closure, not proof that all previously merged code was ineffective.

### Retrieval coverage

| Source | Search result and limitation |
|---|---|
| Claude history | 11 project transcript files inspected with bounded excerpts. Selected real user/assistant events, excluding policy injections. |
| Codex history | Default index yielded 13 direct project threads; 120 active alternate-profile index rows yielded no disk title/first-message hit. Index results are not a request-frequency denominator. |
| AGY | Five project summaries; useful for requests/activity, insufficient for final cleanup outcomes. |
| Cursor | No dated disk result in the helper sample; not proof of non-use. |
| Hermes database | Read-only bounded query did not finish within 30 seconds; no usable incident evidence. |
| Roadmaps and Beads | Local September designs, home-roadmap September 7 plan, and current `br` records used. No raw Beads interchange was inspected. |
| Claude project memories | Bounded Markdown search; September 11 plist incident corroborated. Older notes were treated as dated evidence. |
| Hermes briefings/index and OpenClaw | No relevant operational-memory hit in the bounded searches; policy copies were not treated as incidents. |
| Wiki | Prior taxonomy and source records found, but implementation claims require current verification. See [memory lane](/tmp/disk-redesign-20261003-memory.md). |
| Slack | Search capability unavailable; channel-list/history fallback sampled up to 20 messages in five relevant channels. No disk-related in-window hit. This does not establish that alerts were disabled or that workspace-wide search found nothing. |
| Memory-search cache | Matching cache files were older than the one-hour TTL; live source retrieval used. |

### A concrete knowledge-quality error

`findings_wiki/2026-08-25-snapshot-pipeline-debug-audit.md` claims uppercase `H` from `git ls-files -v` proves `assume-unchanged`. Git documents **lowercase** letters for that flag. The current ledger's uppercase `H` does not support the historical diagnosis. Preserve the original record and add a dated correction through its owner; do not silently rewrite history. [Git documentation](https://git-scm.com/docs/git-ls-files).

## `/cs` result

| Lane | Verdict | Evidence and required action |
|---|---|---|
| Ponytail | FAIL | New cleanup paths bypass existing candidate-safety patterns; reuse those guards and shared operational primitives before adding more scripts. `cleanup_agent_artifacts.sh:139-142,224-231`. |
| ZFC | PASS for reviewed scope | Operations are deterministic filesystem/accounting/service checks. No model-owned intent routing was found. Typed status is the appropriate replacement for operational prose parsing. |
| ZFC leveling | N-A | No leveling, rewards, or XP contract. |
| Root-cause-first | FAIL | `render_topdown_ledger.py:429-441` intentionally preserves the old canonical table on partial scans, while `snapshot_commit.sh:57-85` continues committing routine snapshots. Existing September 11 partial-publication work remains unfinished. |

`ROOT CAUSE ROUTE: BACKEND`. This labels the accounting/publication failure, not a universal cause for every storage producer.

### Highest-priority findings

1. **Partial results have no current queryable ledger.** Keep the canonical completeness gate and publish a separately named partial artifact. The existing `compute_deltas()` defaults missing paths to zero: it must not be reused unchanged for incomplete scans or changing parent/child partitions.
2. **Log activity substitutes for job outcome.** `sweeper_health_check.sh:125-131,182-228` checks log mtime and four English tokens. A lock skip can exit 0 and look healthy. Require typed terminal outcomes and artifact identity, while preserving lock safety.
3. **Codex checkpoint results are ignored.** The now-committed `cleanup_codex_db.sh:303-333` checks CLI exit status but not the returned checkpoint row. A fresh isolated SQLite fixture with an open reader returned exit 0 and `1|4|3`, indicating an incomplete/busy checkpoint. This demonstrates false completion reporting, not database corruption. Add explicit result handling and concurrent-client tests before claiming safe scheduled maintenance. [SQLite contract](https://www.sqlite.org/pragma.html#pragma_wal_checkpoint); [raw fixture result](/tmp/disk-redesign-20261003-checkpoint-proof.json).
4. **Dark Factory cleanup checks the parent, then deletes children directly.** `cleanup_agent_artifacts.sh:139-142,224-231` lacks per-run safety/ownership and deletion-outcome checks. A directory mtime alone also does not establish deep-content inactivity. Review each candidate through canonical guards.
5. **Wiki-publish deletion lacks a measured lifecycle.** `cleanup_dev_caches.sh:293-325` has a per-entry safety check but no age, terminal-state, or open-handle criterion; checking one process name cannot establish all consumers are absent. Preserve active/recent entries and verify with isolated fixtures.
6. **Deployment safeguards are bypassable through documented procedure.** `tools/deploy_uv_tool.sh` already checks clean source, origin/main, package parity, and the installed entrypoint. Repository instructions still describe direct `uv tool install`. Complete the existing deployment design and record the deployed artifact and later scheduled outcome.

The independent [full code review](/tmp/disk-redesign-20261003-cs.md) details proposed versus committed file scope and test gaps. These findings are not permission to delete, activate, or repair anything during this planning invocation.

## Validation

- Root: renderer contract suite, 18 tests passed; live strict-floor query correctly refused missing history; installed pressure budget independently read; SQLite checkpoint behavior reproduced in a disposable fixture.
- Independent review: Codex cleanup fixture 23 assertions; temporary-scratch wrapper 11 assertions; carry-forward and fleet fixtures; shell/Python syntax checks; package-tree check and diff whitespace check passed.
- Snapshot parallel/coverage runs were reported inconclusive by the reviewer, not counted as passes. No live cleanup result or seven-day prevention result is claimed.

## Design handoff

User clarification on October 3 adds a hard architectural requirement: all
operational capabilities must be driven through one `diskm` CLI, reusing
existing internals. It is now recorded in `CLAUDE.md`, which the repository's
`AGENTS.md` symlink exposes. The current package registers `disk-magician`
only, and its installed `--help` invocation succeeded; `diskm` registration
and scheduler convergence are implementation work in the updated plan, not
completed runtime changes. New status/growth helpers must have CLI dispatch
and integration coverage rather than become separate operator scripts. This
clarification received local review only; the advice failure below is unchanged.

- [Design specification](../specs/2026-10-03-disk-reliability-redesign-design.md).
- [Implementation plan](../plans/2026-10-03-disk-reliability-redesign.md).

Existing tracker owners remain `disk_magician-zyn`, `disk_magician-4y6`, `disk_magician-sweeper-health-ledger-warn-impl-s62`, `disk_magician-6aa`, and `disk_magician-disk-fill-prevention-scheduled-cleanup-q6l`. This audit adds sourced findings to those records and creates separate defects only where duplicate searches found no owner. Planning does not reopen historical activation approvals.

Created and read back: `disk_magician-7yv` (busy checkpoint reporting/concurrency proof), `disk_magician-mda` (wiki-publish lifecycle protection), and `disk_magician-cjc` (incorrect uppercase-H diagnosis). Added comments to `6aa`, `zyn`, `s62`, and `q6l`; no existing issue was closed or declared fixed.

## Required advice attempt

`/advice`: **FAILED**, pre-launch, exit 2. The canonical `run_primary_pair.py --reviewers codex,opus` runner returned `input checkout must be clean; dirty state is not represented by an exact SHA`. No reviewer launched and no verdict was obtained. The planning documents are intentionally uncommitted; this is a non-transient workflow precondition, so no retry or substitute approval was manufactured. [Captured attempt](/tmp/disk-redesign-20261003-advice-attempt.json).

| Reviewer | Status | Coverage |
|---|---|---|
| A1 Codex | unavailable (runner clean-checkout precondition) | None; not launched |
| A2 Opus | unavailable (runner clean-checkout precondition) | None; not launched |
| B Research | not selected by the documentation-only size/risk rule | Primary vendor documentation was used in the audit, but it is not an approval vote |
| C Secondo | not selected by the documentation-only size/risk rule | None |
| D Web advice | unavailable (disabled by parent authorization boundary) | None; no external browser transport attempted |

`/web-advice`: **SKIPPED**, because the user did not separately authorize external browser review; neither Reviewer D nor a standalone review was attempted.

The [advice skill](/Users/jleechan/.claude/skills/advice/SKILL.md) requires: “The input checkout must be clean, including untracked files.” The [superpowers-quick skill](/Users/jleechan/.claude/skills/superpowers-quick/SKILL.md) instructs: “Do not commit or push.” Both requirements were preserved. These documents have local self-review and a repository standards audit; they do **not** have independent `/advice` approval.
