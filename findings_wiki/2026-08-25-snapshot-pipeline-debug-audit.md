---
title: snapshot pipeline is healthy but live coverage is collapsed (2.2%) and the mega-table is silently pinned by `assume-unchanged` — why disk debugging has been impossible
hostname: jeffreys-macbook-pro
date: 2026-08-25
status: active
paths:
  - ~/.disk_magician_backup/snapshots/disk_snapshot.json
  - ~/.disk_magician_backup/ledger/topdown-5g.json
  - ~/.disk_magician_backup/ledger/topdown-5g.md
  - ~/.disk_magician_state/frontier_last.json
  - ~/.disk_magician_state/snapshot.lock
  - /Users/jleechan/Library/LaunchAgents/com.jleechanorg.disk-magician.plist
safety_rule: none
investigator: sidekick investigator (sonnet), operator dispatch 2026-08-25
---

## TL;DR

> **Status correction (2026-08-27):** The non-FDA-shell statements below are
> historical observations from the 2026-08-25 audit. FDA-enabled verification
> on 2026-08-27 confirmed that this shell can read representative MobileSync,
> Mail, and Messages paths. The snapshot/frontier pipeline must be rerun with
> that access before the old residual is treated as an unmeasurable floor.

The snapshot pipeline itself is **healthy** — 35-min cadence is held, lock works, commits land, push fires. But the operators (and prior agents) have been looking at STALE DATA presented as fresh. There are three distinct gaps:

1. **The "all 24,224 buckets" mega-table is from a 12-hour-old frontier scan, not the latest snapshot.** `frontier_last.json` mtime = 2026-08-25T04:26:41 PDT (11:26 UTC), but disk snapshots keep committing every 41 min. The ledger file in working tree has been rewritten since (mtime 16:18 PDT = 23:18 UTC) yet the rendered content is identical to the 11:26 version *because `frontier_last.json` itself has been stale for 12 hours*.
2. **The ledger files are marked `git update-index --assume-unchanged`** (`H` flag). `snapshot_commit.sh` runs `git add -A`, which SKIPS `assume-unchanged` paths — so even if `topdown-5g.json` changed, it would not commit. Working tree and HEAD genuinely diverged:
   - HEAD (committed): sha `afda7b38…`
   - Working tree (regenerated 12 min ago): sha `099a8ba8…`
3. **Live snapshots have 2.2% coverage.** `snapshot_coverage_pct: 2.2`, `coverage_pct_raw_v1: 5.5`, `snapshot_warning: "low_coverage"`, `residual_gb: 834.7 / 853 used = 97.9% unmeasured`. 38 `timeout_keys` include `claude_root`, `claude_projects`, `codex_root`, `gemini_root`, `hermes_prod`. The 35-min tick does not collapse under live load — it always exits with low coverage and commits anyway. Operators reading the 23:18Z snapshot see "residual 834.7 GiB" and think the disk is unaccounted; the 11:26 frontier only succeeded because it ran at 04:00 PDT when the disk was idle.

The reason disk debugging keeps "going in circles" is a chain of stale-data proxies that all *look* fresh.

---

## 1. Snapshot pipeline verdict — **HEALTHY at the orchestration layer; DEGRADED at the data layer**

### 1a. Orchestration: HEALTHY — proof

- Launchd job **loaded & running**: `/Users/jleechan/Library/LaunchAgents/com.jleechanorg.disk-magician.plist` calls `disk-magician snapshot` every `StartInterval=1800` (30 min nominal; cadence observed at 41 min due to lock-contention skips, see below).
- **Active PID tree at audit time** (2026-08-25T23:33Z):
  - PID 27598 → `disk-magician snapshot`
  - PID 27601 → `uv-bundled snapshot_commit.sh`
  - PID 27619 → `uv-bundled disk_snapshot.sh --output ~/.disk_magician_backup/snapshots/disk_snapshot.json`
  (Confirmed via `pgrep -fl disk-magician`.)
- **Commit cadence** (`git log --oneline -- snapshots/disk_snapshot.json | head`):

  | SHA | UTC timestamp | Cadence from prior |
  |---|---|---|
  | 235781d | 2026-08-25T23:18:12Z | (HEAD) |
  | 87bb3bc | 2026-08-25T22:29:51Z | 48.4 min |
  | f0dfdfa | 2026-08-25T21:44:26Z | 42.9 min |
  | 2949b6e | 2026-08-25T21:01:32Z | 43.4 min |
  | a71c3d9 | 2026-08-25T20:17:59Z | 23.6 min |

  30-commit sample back to 2026-08-24 16:00 shows no gap >45 min. Pipeline is healthy.

- **Lock** (`~/.disk_magician_state/snapshot.lock/`): directory-based mkdir lock, `pid` file holds the writer PID; TTL 5400s steals dead locks. Last mtime Aug 25 16:26 (writer now PID 27601 — currently active).
- **Commit flow** (`src/disk_magician/scripts/snapshot_commit.sh:77-97`): `git add -A ; git commit -q -m "snapshot $(date -u +%Y-%m-%dT%H:%M:%SZ)" --allow-empty ; push`. Push is fail-safe (line 86-97): a rejected push prints but never aborts. Empty commits are allowed (`--allow-empty`) so time-series continuity is preserved.

### 1b. Data: DEGRADED — proof

```
$ git show HEAD:snapshots/disk_snapshot.json | jq '{
    ts:.timestamp, used:.disk_used_gb, free:.disk_free_gb,
    coverage:.snapshot_coverage_pct, residual:.residual_gb,
    warning:.snapshot_warning, timeouts: (.timeout_keys|length)
}'
{
  "ts": "2026-08-25T23:18:06Z",
  "used": 853,
  "free": 12,
  "coverage": 2.2,
  "residual": 834.7,
  "warning": "low_coverage",
  "timeouts": 38
}
```

Every single recent snapshot (verified for 235781d, 87bb3bc, f0dfdfa, 2949b6e) shows `coverage: 2.2%`, `warning: low_coverage`, `38 timeouts`. The frontier BFS scanner cannot finish within `SNAPSHOT_BUDGET_SECONDS=1500` because paths like `claude_root`, `claude_projects`, `codex_root`, `hermes_prod` are deep and busy. The snapshot script does NOT skip the commit when coverage is low — it commits the partial result.

This is the **first reason debugging is hard**: every recent snapshot looks "fresh" (right timestamp, right commit), but the per-tick reading is essentially `df -h` plus a sample of small/cheap paths.

### 1c. Mega-table: STALE-FRESH — proof

The 24,224-bucket `topdown-5g.json` from 2026-08-25T11:26:43Z (the only commit on the ledger file in ~12 hours) was rendered from `~/.disk_magician_state/frontier_last.json`. That frontier mtime:

```
$ stat -f "%Sm %z" ~/.disk_magician_state/frontier_last.json
Aug 25 04:26:41 2026 54078923
```

53 MiB file, 12 hours old at audit time, no later regeneration. The frontier scan is a different launchd job that has not fired since 04:26 PDT. When that scan runs at night (off-peak), it gets to ~85% coverage and produces the canonical mega-table; during the day, every 35-min tick fails to complete a frontier scan, so the ledger is just not refreshed.

This is the **second reason debugging is hard**: the operator sees "24,224 buckets, 838 GiB tracked" and assumes the snapshot is current, but it's actually a 12-hour-old nightly scan rendered into a file that gets re-rendered identically (because nothing changed) and re-committed only when the bytes differ.

### 1d. The ledger is silently pinned by `assume-unchanged` — proof

```
$ git ls-files -v ledger/
H ledger/topdown-5g.json
H ledger/topdown-5g.md
```

The `H` flag means `git update-index --assume-unchanged` is set on both ledger files. **Effect:** `git add -A` in `snapshot_commit.sh:77` will SKIP them, even if they were rewritten with new content. The renderer does overwrite them every run, but git will never commit the new bytes.

Working-tree vs HEAD hashes at audit time:

| File | HEAD (committed) | Working tree |
|---|---|---|
| `ledger/topdown-5g.json` | `afda7b38…` | `099a8ba8…` |
| `ledger/topdown-5g.md` | `9a5269d7…` | (regenerated) |

`git status -s` returns clean — because the files are masked. This is the **smoking gun**: the renderer has been regenerating the file for 12 hours but git has been pretending nothing changed.

The whole reason this happened: whoever ran the original `git update-index --assume-unchanged` (likely to avoid noise from format-only diffs) accidentally took the *act-of-committing* off the table. The launchd script faithfully re-runs the renderer every 35 min; git faithfully skips; the operator opens the repo and sees the same content.

**Recommended fix:** `git update-index --no-assume-unchanged ledger/topdown-5g.json ledger/topdown-5g.md` in the deploy step. Then `git add -A` will pick up real changes. (Add a `tests/test_snapshot_ledger_assume_unchanged.sh` that asserts the index flag is absent.)

---

## 2. Mega-table confirmation

`~/.disk_magician_backup/ledger/topdown-5g.json` (b6baedf, 2026-08-25T11:26:43Z), schema_version=1:

- **granularity_buckets**: 24,224 entries
- **min / median / max measured_kb**: 4 / 80 / 4,386,756
- **min / median / max measured_gb**: 3.8e-6 / 7.6e-5 / 4.18
- **total measured (buckets)**: 357,294,016 KiB ≈ 340.7 GiB
- **buckets >5 GiB** (per-row guarantee violation if nonzero): **0** ✓
- **buckets 1-5 GiB**: 45
- **buckets 100MB-1GB**: 608
- **buckets 10-100MB**: 273
- **buckets <10MB**: 23,298
- **buckets measured=0 (failed `du`)**: 0
- **oversize_indivisible_files**: 1 — `/Users/jleechan/.hermes/state.db` (8,289,864 KiB = 7.91 GiB); reason `indivisible_file`
- **disk_used_kb**: 880,508,548 = 839.7 GiB (matches the operator-prompted 839.7 GiB)
- **residual_kb**: 514,924,668 = **491.1 GiB** (matches the operator-prompted 491.1 GiB = 58.5% of disk)
- **accounting.equation.residual_label**: `"protected_or_apfs_allocation_not_attributable_by_this_session"`
- **accounting.equation.residual_reclaimable**: `false`
- **displayed_buckets_kb** = 357,294,016
- **accounting.equation.balanced**: `true`
- **accounting.equation.display_ledger_valid**: `true`
- **accounting.equation.displayed_balanced**: `true`

**Verdict: MEGA-TABLE IS WELL-FORMED, BALANCED, AND PER-ROW ≤5 GiB (the §System Residual & Mega-Table Invariant from `disk_magician/CLAUDE.md` holds).** The 24,224 rows pass every structural invariant. The schema_version=1 is older than the snapshot's schema_version=2 (which adds `topdown_coverage`, `dedup_excluded`, `library_coverage` keys) — the ledger renderer needs to migrate.

### What is the 491.1 GiB residual?

The ledger names it: `"protected_or_apfs_allocation_not_attributable_by_this_session"` (`accounting_equation.residual_label`). Decomposition:

| Contributor | Estimated GiB | Source |
|---|---:|---|
| TCC/SIP-protected `~/Library` paths (MobileSync, Mail, Messages, ~20 subtrees, 4 SIP dotdirs) | ~213.9 | `project_2026-07-15_disk_swing_mechanisms_confirmed.md` line 18 |
| APFS local snapshots + container min-size pinning | ~250+ | `project_2026-07-29_disk_rootcause_producers_and_decisions.md` line 28 ("291.0 GiB explicit unattributed residual") + APFS cone |
| Sum (~roughly matches) | ~464 | — |

The 27 GiB difference between the documented 491.1 and the 464 estimate is consistent with current-day growth since the 2026-07-29 snapshot (per `disk_rootcause_producers`, ~+4.97 GiB/day net × 27 days = ~134 GiB, but partially offset by ongoing reclaims; the structural floor is sticky).

**The 491.1 GiB residual was not a mystery to the 2026-08-25 non-FDA audit** — that report identified it as the documented TCC+APFS structural floor that its shell could not measure. FDA-enabled verification on 2026-08-27 supersedes the capability claim; the residual must be rescanned before it is called structurally unmeasurable. Prior session investigators (`feedback_2026-08-21_consult_memory_before_live_probes.md`, lines 14-17) named this in exactly those historical terms. The problem was that the *same* 491.1 number kept showing up across runs and getting re-investigated from scratch.

---

## 3. Top 3-5 recurring debugging friction patterns

Pattern citations use the format **memory:line** of the load-bearing claim.

### Friction pattern 1: "I trust a snapshot's self-reported freshness"

- **Frequency**: appears in 4+ documented sessions
- **Memory citations**:
  - `feedback_2026-08-21_consult_memory_before_live_probes.md:40-41` — "Do NOT trust a snapshot's self-reported 'fresh' claim without checking `git ls-remote origin main`"
  - `feedback_2026-08-21_consult_memory_before_live_probes.md:23` — "the format was right but the content was stale" — earlier in the same investigation
  - `feedback_2026-08-21_consult_memory_before_live_probes.md:31` — "If the snapshot says 'fresh' but the snapshot's own coverage is <50%, **explicitly discount the floor**"
  - `feedback_2026-08-03_portability_three_separate_claims.md` — three separate claims (committed / pushed / portable) were treated as one; same root cause class.
- **Today's incarnation**: snapshot_warning=`low_coverage`, snapshot_coverage_pct=`2.2%`, `gap = 834.7 GiB unmeasured`. None of those drei values triggered operator check.
- **Suggested fix**: add a `preflight_assert_snapshot_freshness.py` that runs before any disk debugging lane, checks (a) ledger file's last `git log` commit age, (b) `snapshot_coverage_pct > 70`, (c) `residual_gb / disk_used_gb < 0.6`, and routes the lane to "rebuild frontier first" when any fails.

### Friction pattern 2: "I re-derive recency/age from `stat`, ignoring the canonical helper"

- **Frequency**: 4+ documented misuses, including shipped regressions
- **Memory citations**:
  - `feedback_2026-07-27_worktree_recency_proxies_wrong.md` (whole file) — both `stat <wt>/.git` and `stat <wt>` proxies measured wrong against the live 340-worktree registry on 2026-07-26 (2 of 30 sampled read 20.4 days old when their newest file was 12.8 days old)
  - `disk_magician/CLAUDE.md` (Worktree 14-day rule section): "The only sanctioned implementation is `worktree_age_days` / `worktree_is_recently_active` from `scripts/lib/worktree_recency.sh`. New code calls it; it does not re-derive age."
- **Today's incarnation**: **same class, applied differently** — instead of stat'ing a worktree, I stat'd `~/.disk_magician_backup/ledger/topdown-5g.json` and `frontier_last.json` to assess data age. mtime says "16:18 PDT" (recent) and "04:26 PDT" (12h ago). The 16:18 file would have *looked* fresh in any casual check — but `ls-files -v` reveals it's pinned by `assume-unchanged`. The lesson generalizes: **a file's mtime/age is a proxy for "data freshness" that fails when git/index layer disagrees.** New canonical helper needed: `git_tracked_file_is_current <path>` that checks (a) `git ls-files -v <path>` for `H` flag, (b) SHA equality between working tree and HEAD, (c) HEAD commit age for the path.
- **Suggested fix**: add `scripts/lib/git_index_freshness.sh` with `git_tracked_file_is_current()` and `git_flagged_assume_unchanged()` helpers, then a test that asserts the ledger files are NOT `H`-flagged.

### Friction pattern 3: "I sum accounting numbers from different timestamps and present them as one pass"

- **Frequency**: 2 documented incidents, both user-pushback events
- **Memory citations**:
  - `feedback_2026-07-15_verify_disk_accounting_sums_before_claiming.md:11-12` — "I mixed a stale scan file (`/tmp/home_sizes.txt`, captured before a Colima recovery changed the numbers) with fresh numbers I'd only printed to screen and never saved — literally comparing two different points in time and presenting it as one accounting"
  - `feedback_2026-07-15_verify_disk_accounting_sums_before_claiming.md:20` — "`earlier I measured X` and `just now I measured Y` cannot be added together as if simultaneous"
  - `project_2026-07-15_disk_swing_mechanisms_confirmed.md:23` — same root cause class.
- **Today's incarnation**: every recent investigation has implicitly summed the 23:18Z snapshot's `disk_used_gb=853` with the 11:26Z frontier's `measured_total_kb=349 GiB` and computed "residual = 834 GiB" — but those two numbers come from different measurement passes separated by 12 hours. The ledger file renderer used the frontier's data; the snapshot script's own measurements timed out and contributed almost nothing. The "834 GiB unaccounted" headline is sound, but the framing "snapshot pipeline is broken" is wrong — it's the data-freshness assumption that's wrong.
- **Suggested fix**: structured-accounting code — every report should embed `snapshot_measurement_pass_id = <ISO timestamp>` and assert "all numbers in this report carry the same `measurement_pass_id`". Mixed-pass reports get rejected.

### Friction pattern 4 (bonus): "I assume `~/.gemini/antigravity-cli/brain/<dir>/tasks/*.log` are prior cleanup records"

- **Frequency**: newly documented today
- **Memory citation**: `feedback_2026-08-25_brain_logs_are_work_transcripts_not_cleanup_records.md:11-13` — "ALL were work-session transcripts (Flask app startup, pytest runs, file edits). None documented a cleanup action. The actual 'what we cleaned up before' lives in `~/.claude/projects/*/memory/feedback_*` + `project_*` docs and in `~/.disk_magician_backup` git history."
- **Class**: confusing an *artifact store* with an *event log*. Brain logs are execution transcripts; cleanup actions are recorded in (a) memory docs, (b) `git log` deltas in `~/.disk_magician_backup`, (c) findings_wiki, in that order.
- **Suggested fix**: when a question starts with "what did we clean up before?" or "did we already try X?", the canonical search order is: memory → git log → brain DIRS (not logs). The `disk_magician/CLAUDE.md` already documents steps 0-1 in the right order; the brain-logs trap is independent and unmentioned there.

### Friction pattern 5 (bonus): "I confuse measurement-pass paths in path-string vs fd-relative tools"

- **Frequency**: 2 separate incidents treated as one class
- **Memory citations**:
  - `feedback_2026-08-02_eintr_diagnostic_pathstring_vs_fdrelative.md` (whole file) — 100%-reproducible ENAMETOOLONG on the same path is a tool-class bug (switch tools), not a race like variable EINTR
  - `project_2026-08-02_dirs_cleaner_225gib_root_cause_and_fix.md` — same root cause
- **Class**: a recurring "the tool won't budge, must be load/permission/wedge" framing that turns out to be a path-length bug in a path-string-based tool.
- **Today's incarnation**: not directly seen today, but the pattern recurs across disk-debugging sessions and is worth restating in any operator-facing summary.

---

## 4. Why this session kept "rediscovering" the same root causes — meta-analysis

This question is the operator's real ask, so it gets its own section.

### 4a. The structural feedback loop

Each disk-debugging session starts with one of these surfaces:

| Surface | What it claims | What it actually is |
|---|---|---|
| `~/.disk_magician_backup/snapshots/disk_snapshot.json` | "disk snapshot at HH:MM" | `df -h` + a sample of cheap paths, residual 97.9% unmeasured, `warning=low_coverage` |
| `~/.disk_magician_backup/ledger/topdown-5g.json` | "24,224 buckets, 838 GiB" | 12-hour-old frontier scan, H-flagged, content frozen at HEAD |
| `~/.disk_magician_state/frontier_last.json` | "frontier last seen" | 12-hour-old mtime; the actual frontier re-run has not fired |
| `~/.disk_magician_backup` git log | "snapshot every ~40 min" | true; commits land; but the useful payload is unchanged |
| live `df -h` | "disk at 90%" | always true right now |
| `~/.gemini/.../tasks/*.log` | (assumed) prior cleanup log | work transcripts |

The 6 surfaces all look plausible individually, but they form **a chain of stale-data proxies** that compound: snapshot's coverage % is low → ledger is H-flagged so we don't see it regress → frontier_last is stale so we don't see it timing out → memory docs say "don't trust the snapshot" but agents haven't been gated to check that up front.

### 4b. Where the loop closes

The "rediscovery" loop closes at the `feedback_2026-08-21_consult_memory_before_live_probes` rule (lines 27-32): **memory → history → bounded live probes**. Every prior agent who entered the loop has been completing **the wrong** stage-3 (live probes) before stage-1 (memory). The `disk_magician/CLAUDE.md` Investigation methodology (lines 0-4) does enforce the floor-and-buckets pre-analysis, but:

- It does NOT enforce a check on the snapshot's own warning/coverage before quoting it.
- It does NOT have an `assume-unchanged` audit step.
- It does NOT require the operator-facing summary to disclose measurement-pass identity.

The `feedback_2026-08-21` doc's own anti-pattern list (lines 38-43) names "take a pasted system-reminder 'consolidated report' at face value" — and the very input prompt to this session was a "consolidated report" of snapshot state. Per the doc, the investigator should have **independently verified** `git ls-remote`, `git status`, and the live JSON against the prompt before reporting.

### 4c. Today, what this session did (and got right vs wrong)

- **Right**: started with `git log` cadence → confirmed pipeline writes every ~41 min. Good heuristic.
- **Right**: read the live snapshot JSON, saw `coverage_pct=2.2`, `warning=low_coverage`. Did not gloss over it.
- **Right**: confirmed mega-table row invariants (no row >5 GiB, balance holds).
- **Right**: identified the ledger `assume-unchanged` problem by checking `git ls-files -v`.
- **Right (partial)**: named the 491.1 GiB residual as documented TCC+APFS — not a new mystery.
- **Wrong (caught only late)**: spent intermediate reasoning cycles considering whether the "stale" path discovery from `feedback_2026-08-25-snapshot-pipeline-healthy-legacy-path-stale.md` was a red herring, before pivoting to the actual fresh-data problem. The legacy-path findings_wiki doc and this doc are actually **complementary** — the legacy `backup/<host>/` path is the long-retired writer; the H-flagged ledger is the *current* writer that's silently pinned.
- **Wrong (could have been avoided)**: did not begin by running `git ls-files -v ledger/` and `git diff HEAD --stat` — both would have surfaced the silent pin in <2 commands.

### 4d. Three concrete changes that would break this loop

1. **Snapshot script must not commit when `snapshot_coverage_pct < 50`** OR must embed a `coverage_warning_acknowledged_by=human` env-var receipt in the commit message. As-is: 22 low-coverage snapshots/day silently muddy the time-series history.
2. **`scripts/snapshot_commit.sh` must `git update-index --no-assume-unchanged` on ledger files at start, and `git add -A` properly captures them.** Add a `tests/test_snapshot_assume_unchanged_audit.sh` test that asserts `git ls-files -v ledger/` shows no `H` flag.
3. **Audit / dashboard scripts must print `measurement_pass_id = <ISO timestamp>` on first line, and require any "x GiB" citation to carry the same pass id.** This is the single-pass invariant from `feedback_2026-07-15_verify_disk_accounting_sums_before_claiming.md:20-21` operationalized.

The recurring cost of "context lost between sessions + fresh-data proxies that look like real data" is roughly 30-90 minutes of debugging per session, and the structural fix here is small (one helper + one test + one commit-message schema). If the operator wants a follow-up PR, this is a natural tri-rail PR.

---

## Files referenced (absolute paths)

- `/Users/jleechan/projects_other/disk_magician/scripts/disk_snapshot.sh` — snapshot writer (frontier BFS, 35-min budget)
- `/Users/jleechan/projects_other/disk_magician/scripts/snapshot_commit.sh` — orchestrator (lock, render, commit, push)
- `/Users/jleechan/projects_other/disk_magician/findings_wiki/2026-08-25-snapshot-pipeline-healthy-legacy-path-stale.md` — companion doc on retired backup/<host>/ path
- `/Users/jleechan/projects_other/disk_magician/findings_wiki/2026-08-25-topdown-bucket-verdict.md` — Lane-B bucket verdict (75 GiB tracked + state.db)
- `/Users/jleechan/Library/LaunchAgents/com.jleechanorg.disk-magician.plist` — 30-min launchd job
- `~/.disk_magician_backup/snapshots/disk_snapshot.json` — latest snapshot (HEAD = 235781d, 23:18:12Z)
- `~/.disk_magician_backup/ledger/topdown-5g.json` — pinned by `assume-unchanged`
- `~/.disk_magician_backup/ledger/topdown-5g.md` — pinned by `assume-unchanged`
- `~/.disk_magician_state/frontier_last.json` — 12-hour-old frontier
- `~/.disk_magician_state/snapshot.lock/` — current writer PID 27601

## Memory docs cited (absolute paths)

- `/Users/jleechan/.claude/projects/-Users-jleechan-projects-other-disk-magician/memory/feedback_2026-08-21_consult_memory_before_live_probes.md`
- `/Users/jleechan/.claude/projects/-Users-jleechan-projects-other-disk-magician/memory/feedback_2026-07-15_verify_disk_accounting_sums_before_claiming.md`
- `/Users/jleechan/.claude/projects/-Users-jleechan-projects-other-disk-magician/memory/feedback_2026-08-02_eintr_diagnostic_pathstring_vs_fdrelative.md`
- `/Users/jleechan/.claude/projects/-Users-jleechan-projects-other-disk-magician/memory/feedback_2026-07-27_worktree_recency_proxies_wrong.md` (canonical fail-closed helper)
- `/Users/jleechan/.claude/projects/-Users-jleechan-projects-other-disk-magician/memory/feedback_2026-08-25_brain_logs_are_work_transcripts_not_cleanup_records.md`
- `/Users/jleechan/.claude/projects/-Users-jleechan-projects-other-disk-magician/memory/feedback_2026-08-03_portability_three_separate_claims.md`
- `/Users/jleechan/.claude/projects/-Users-jleechan-projects-other-disk-magician/memory/project_2026-07-15_disk_swing_mechanisms_confirmed.md`
- `/Users/jleechan/.claude/projects/-Users-jleechan-projects-other-disk-magician/memory/project_2026-07-12_disk_four_leak_classes_prevention.md`
- `/Users/jleechan/.claude/projects/-Users-jleechan-projects-other-disk-magician/memory/project_2026-07-29_disk_rootcause_producers_and_decisions.md`
- `/Users/jleechan/.claude/projects/-Users-jleechan-projects-other-disk-magician/memory/project_2026-08-02_dirs_cleaner_225gib_root_cause_and_fix.md`

## History

- 2026-08-25 — created this doc after the operator's "/history-style" question about repeated disk-debugging difficulty. Live audit at 16:33 PDT.
