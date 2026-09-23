# Design spec: PR2 "the ledger is fresh and queryable" (F, G, H)

Bead: `disk_magician-zyn`. Source: `roadmap/2026-09-11-disk-recurrence-rootcause-and-automation.md`
§5 components F/G/H (sequenced after PR1: A–E, fleet-forensics/repair, already
landed separately). Evidence: `roadmap/2026-09-11-disk-recurrence-evidence.md`
§C ("measurement layer is blind"), §D (bucket source of truth), §F (open beads).

Related, explicitly NOT duplicated by this bead:
- `disk_magician-x78` — replacing `disk_observer.py`'s `collect_hot_dir_sizes`
  with a ledger-cache-first lookup. Out of scope here; H only widens the
  existing `du -sk`-per-hot-dir mechanism (adds 2 keys + per-key timeout).
- `disk_magician-4y6` — the root-privileged full-attribution scanner install
  that is required before ANY snapshot can reach `mode: complete` again.
  G's floor selection depends on at least one historical complete snapshot
  existing; it does not fix why new ones stop landing. Both F and G fail
  closed and cite this bead by name when that dependency isn't met (see
  Component G, "No floor found").

## 0. Ground truth established by reading the code (not asserted, verified)

1. `scripts/render_topdown_ledger.py:main()` already gates the **canonical**
   `ledger/topdown-5g.json`/`.md` on `complete_coverage_envelope(report)` —
   on an incomplete report it writes only `ledger/topdown-5g.status.json`
   (`status: partial, reason: coverage_incomplete`) and leaves the mega-table
   byte-for-byte untouched. Confirmed live: `topdown-5g.json` mtime Aug 31,
   `topdown-5g.status.json` mtime Sep 11 (today) — status updates every run,
   the table hasn't moved in 11+ days.
2. `scripts/history_diff.py` has two independent validators:
   `validate_ledger()` (schema_version==2, buckets/oversize/purgeable/
   sub_granularity_tail/clone_adjustment + `residual_kb` must sum to exactly
   `disk_used_kb` — a **structural**, completeness-agnostic check) and
   `validate_full_attribution_ledger()` (additionally requires `mode ==
   "complete"`, `measured == reachable`, `frontier_unfinished == []`, FDA
   attestation, balanced accounting — the **strict** gate). `select_floor_ref()`
   walks `git log --since=Nd -- ledger/topdown-5g.json`, keeps only commits
   that pass BOTH validators, and returns the lowest `disk_used_kb`. This
   already IS "find the last-N-day floor" (CLAUDE.md Step 1), fully
   implemented, just not wired to a one-shot CLI subcommand or a fresh
   "current" side to diff against.
3. `compute_deltas(base, target)` is generic: it only reads
   `granularity_buckets`/`buckets`, `oversize_indivisible_files`, and
   `residual_kb` from two dicts — it never touches `mode`/FDA/completeness.
   It works unmodified on a structural (non-full-attribution) ledger as
   `target`, provided the caller validated `target` with `validate_ledger()`
   only (not the strict gate).
4. `collect_hot_dir_sizes()` (disk_observer.py) is called in exactly one
   place: `build_step_event_record()`, which itself only runs inside
   `if step_event:` — i.e. only when `check_step_event()` fires a
   >=10 GiB / 30-minute swing. It is **not** called on every 30–60s poll
   tick. A slower per-key timeout for 1–2 keys is therefore bounded to a
   rare trigger, not a steady-state cost.
5. `config.json.template` **already has** a `projects` entry
   (`timeout: 300, retry_timeout: 90`). The roadmap doc's "zero `roadmap`
   matches" claim is correct; it did not claim `projects` was also absent
   from this file (only from `disk_observer.py`'s separate `DEFAULT_HOT_DIRS`
   list, which is a different, second catalog). H therefore only adds a new
   `roadmap` entry to `config.json.template`, not a `projects` entry.
6. `scripts/sync_package_tree.sh` mirrors `scripts/*.sh` / `scripts/*.py` by
   glob into `src/disk_magician/scripts/` — new files need no addition to
   that script, just a sync run.
7. `render_topdown_ledger.py` is invoked every ~35 min by
   `snapshot_commit.sh`, but is itself freshness- and content-gated against
   `frontier_last.json` (refreshed ~once/24h by `frontier-nightly`) — so in
   steady state it reprocesses the same source report ~40x/day and (per
   existing precedent: `topdown-5g.json` has sat unchanged 11+ days without
   runaway commits) the state-repo commit step is diff-aware. A new
   `topdown-5g.partial.json` written on the same cadence inherits this
   property; no new dedup logic is needed.

## 1. Approaches considered

**A. Make the canonical ledger's completeness gate looser (e.g. accept
"mostly complete").** Rejected: the roadmap doc's §5 explicitly cuts this
("The strict ledger gate is not loosened in place — a partial artifact gets
its own filename, so a degraded floor can never silently masquerade as the
canonical one"). Any threshold is arbitrary and reopens the exact bug class
`disk_magician-4y6` exists to prevent (treating an EACCES-crippled scan as
trustworthy).

**B. New parallel partial-ledger pipeline, fully independent code path.**
Rejected: would duplicate `render_topdown_ledger.py`'s bucket-shape/
reconciliation checks a third time (two copies already exist, in
`render_topdown_ledger.py` and `history_diff.py`) instead of reusing
`history_diff.validate_ledger()`, and would duplicate `history_diff.py`'s
floor/diff logic a second time inside `growth_top10.py` instead of importing
it.

**C. (chosen) Additive partial artifact + thin import-based wrapper.**
`render_topdown_ledger.py` always attempts to write
`ledger/topdown-5g.partial.json` — "freshest scan of any completeness
level" — self-validated via an imported `history_diff.validate_ledger()`
call (fail-closed: skip write, keep prior partial.json, log to stderr, never
crash). Canonical `topdown-5g.json`/`.md` keep their existing strict gate
byte-for-byte. `disk_magician.sh growth-top10` is a new thin script,
`scripts/growth_top10.py`, that **imports** `history_diff` and
`resolve_state_repo_path` as libraries — zero duplicated validation/diff
logic — and reads `topdown-5g.partial.json` (fallback: canonical) as
"current" against `history_diff.select_floor_ref()`'s unmodified 14-day
floor. `check_ledger_freshness.sh` is a new small read-only script (own exit
code, does not affect `check_launchd_fleet.sh`'s exit code) invoked from the
tail of `check_launchd_fleet.sh` so CLAUDE.md's mandatory Step -1 output
surfaces ledger freshness without conflating two different failure classes
(launchd job liveness vs. ledger content freshness) into one exit code.

Chosen because it is the only option that reuses 100% of the already-correct
floor/diff/validate logic in `history_diff.py`, keeps the strict gate
provably untouched (component F's own roadmap-mandated cut), and keeps every
new file small and independently testable.

## 2. Assumptions and Recommended Defaults (autonomous mode — one answer per fork)

**Q1: Does `topdown-5g.partial.json` get (re)written on a *complete* run
too, or only on incomplete ones?**
Recommended: **on every fresh (<=36h), reconciling, non-empty run,
regardless of completeness.** Rationale: gives `growth_top10.py` one single
read path ("read `topdown-5g.partial.json`; if absent, fall back to
canonical") instead of two branches depending on whether the last run
happened to complete. Contract: `topdown-5g.partial.json` = freshest scan of
**any** quality; `topdown-5g.json` = freshest scan that was **complete**.
Consumers who need the strict guarantee keep reading the canonical file
exactly as before (e.g. `history diff` without `--allow-partial`, not added
here — out of scope, no caller needs it).

**Q2: Should `render_topdown_ledger.py` self-validate before writing
`topdown-5g.partial.json`?**
Recommended: **yes**, reuse `history_diff.validate_ledger()` via import
(same `sys.path`-relative pattern `history_diff.py` already uses for
`resolve_state_repo_path`). On `LedgerError`: skip the write, leave any
prior `topdown-5g.partial.json` in place, print one line to stderr, return 0
(matches existing fail-open posture for sibling-tool files — CLAUDE.md
"this must never crash a snapshot over a sibling tool's file").

**Q3: How does `growth_top10.py` pick "current"?**
Recommended: read `<state_dir>/ledger/topdown-5g.partial.json` from the
**working tree** (not git history — it is the freshest local write, no
commit-lag). If absent, fall back to `<state_dir>/ledger/topdown-5g.json`
(canonical, also working tree, not git history). If neither exists or
neither passes `validate_ledger()`, exit 1 with
`"growth-top10: no valid ledger snapshot found — run: ./disk_magician.sh frontier"`.

**Q4: How does `growth_top10.py` pick the floor, and what happens when no
complete snapshot exists in the window (the live `disk_magician-4y6`
scenario)?**
Recommended: reuse `history_diff.select_floor_ref(state_dir, days=14)`
**unmodified** — it already requires full-attribution, which is exactly
CLAUDE.md's floor-integrity bar ("The gap-to-floor grounds every proposal").
On `LedgerError` ("no valid ledger snapshots in the last N days"): **do not
fall back to a non-full-attribution floor.** Exit 2 with
`"growth-top10: no full-attribution ledger in the last 14 days (see bead disk_magician-4y6); cannot compute a trustworthy floor"`.
A wrong floor silently corrupts every downstream number in the tool's own
output; a loud, named failure is strictly better than a plausible-looking
wrong answer.

**Q5: Where does the ledger-freshness check live, and does it change
`check_launchd_fleet.sh`'s exit code?**
Recommended: new standalone `scripts/check_ledger_freshness.sh` (own exit
code: 0 fresh, 1 stale/missing), reusable directly as
`./disk_magician.sh ledger-freshness`, **and** called from the tail of
`check_launchd_fleet.sh` (output appended, `|| true` — informational only).
Fleet liveness and ledger content freshness are different failure classes
(a perfectly-loaded fleet can still be stuck on an EACCES'd scanner per
`disk_magician-4y6`); conflating them into one exit code would make
`check_launchd_fleet.sh`'s callers (which key off its exit code to decide
"is my automation alive") newly fail for a reason the fleet itself can't fix
by reloading a plist.

**Q6: "Fresh" threshold for the freshness check?**
Recommended: reuse `render_topdown_ledger.py`'s existing `STALE_HOURS = 36`
constant value (cannot literally share the Python constant with a bash
script; hardcode `36` in `check_ledger_freshness.sh` with a comment
cross-referencing the Python source of truth — same pattern already used
elsewhere in this repo for cross-language constants, e.g. per-script
timeout constants are independently defined, not centrally shared).

**Q7: DEFAULT_HOT_DIRS entries — bare name or `~/`-prefixed?**
Recommended: **bare relative names** (`"roadmap"`, `"projects"`), matching
every existing entry's convention (`.codex`, `Library/Caches` — none use a
`~/` prefix today even though `collect_hot_dir_sizes()` supports it).
`home / "roadmap"` and `~/roadmap` are the same path; no functional
difference, only consistency.

**Q8: Per-key `du` timeout mechanism?**
Recommended: new module constant
`DEFAULT_HOT_DIR_TIMEOUTS_SEC = {"roadmap": 90, "projects": 90}`;
`_du_kb(path, run, timeout: int = 8)` gains a `timeout` parameter (default
`8` preserves every existing call site — including `collect_colima()`'s two
untimed call sites — byte-for-byte); `collect_hot_dir_sizes()` looks up
`timeouts.get(name, 8)` per entry. 90s is chosen because the evidence
bundle's live, unloaded `du -sk ~/roadmap` and `du -sk ~/projects` each
finished in well under 90s in the reported measurement (`~/projects` was the
slowest at ~200s **under the specific 09-11 disk-pressure conditions**, but
this call only fires on a rare >=10 GiB step-event trigger, not the steady
poll loop — an occasional 90s (or even a timeout at 90s, which just yields
`None` for that key on that one event, same degraded-but-safe behavor every
other hot dir already has under load) is an acceptable, bounded cost for a
rare event). This is explicitly a **judgment call, not a proof** — if
`~/projects` continues to exceed 90s under real load after this ships, raise
the constant; do not add complexity (background thread, async subprocess)
for a rare-event, fail-soft path per ponytail/root-cause-first ("don't build
for a case you haven't observed recur").

**Q9: Merge-safety with lane 6wd's disk_observer.py hook.**
Recommended: touch only (a) `DEFAULT_HOT_DIRS` list — append two items to
the end, don't reorder; (b) add the new `DEFAULT_HOT_DIR_TIMEOUTS_SEC`
constant immediately after it; (c) `_du_kb`'s signature (add one optional
kwarg, no body reordering beyond passing it through); (d)
`collect_hot_dir_sizes()`'s signature and the one line inside its loop that
computes `timeout`. All four are additive/localized. If lane 6wd's hook
also touches `collect_hot_dir_sizes()`'s loop body, the two diffs will
conflict at the line level (not silently double-apply) — whichever lands
second must rebase; do not attempt to pre-merge blind.

## 3. Component F — partial ledger artifact

**File touched:** `scripts/render_topdown_ledger.py` only.

**Behavior change:** Extract the existing ledger-dict-building block
(current lines ~447–467, building `ledger = {...}` for the canonical write)
into a helper `build_ledger_dict(report, captured_at) -> dict` — same field
set, no behavior change, pure refactor to avoid a second copy for the new
partial path. In `main()`:

1. Keep the existing stale check (`age_hours > STALE_HOURS` -> write status,
   return 0) unchanged.
2. After the stale check, unconditionally call `ledger = build_ledger_dict(report, captured_at)`.
3. Import `history_diff` (same directory, same import pattern
   `history_diff.py` already uses for `resolve_state_repo_path`) and attempt
   `history_diff.validate_ledger(ledger, label="partial-candidate")`. If it
   raises `LedgerError`, or `ledger["granularity_buckets"]` is empty, print
   one line to stderr (`f"render_topdown_ledger: skipping partial artifact — {exc}"`)
   and skip step 4 (existing prior `topdown-5g.partial.json`, if any, is left
   untouched — no partial regression on a bad run).
4. Otherwise write `ledger` to `<out_dir>/topdown-5g.partial.json` (new
   constant `PARTIAL_LEDGER_JSON = "topdown-5g.partial.json"`), plus a
   `"unfinished_top_level_roots"` key set to
   `[item.get("path") for item in (report.get("frontier_unfinished") or []) if isinstance(item, dict) and item.get("path")]`
   — the "unmeasured roots listed inline" the bead asks for, sourced
   directly from the scanner's own `frontier_unfinished` list (schema owned
   by `disk_frontier_scan.py`, passed through verbatim — this ticket does
   not touch the scanner).
5. Continue exactly as today: if `complete_coverage_envelope(report)`,
   ALSO write the canonical `topdown-5g.json`/`.md` (reusing the same
   `ledger` dict from step 2 instead of rebuilding it — the only other
   change to this branch is removing the now-duplicate dict literal and
   calling `build_ledger_dict()` once).
6. `write_status()` call at the end is unchanged in shape; it already
   reports `status`/`reason`/`coverage_envelope` and needs no new fields —
   `check_ledger_freshness.sh` (Component F/H's wiring) reads
   `topdown-5g.partial.json`'s own `captured_at` directly, not the status
   sidecar, for the "is there fresh partial data" signal.

**Invariant proven by test:** canonical `topdown-5g.json`/`.md` are
byte-identical before/after a partial (incomplete) run — i.e. this change
cannot regress the existing strict-gate behavior other people's tooling
already depends on.

## 4. Component G — `disk_magician.sh growth-top10`

**New file:** `scripts/growth_top10.py`. **Touched:** `disk_magician.sh`
(new dispatch case + usage line). No changes to `history_diff.py`,
`resolve_state_repo_path.py`, or `render_topdown_ledger.py` beyond F above.

```
usage: growth_top10.py [--days N] [--limit N] [--state-dir DIR]

Exit 0: printed floor/current/gap + top-N table.
Exit 1: no valid current ledger (neither partial nor canonical readable/valid).
Exit 2: no full-attribution floor in --days window (cites disk_magician-4y6).
```

Algorithm (all local reads — zero `du`, zero fresh filesystem walk):

1. `state_dir = resolve_state_repo_path.resolve()` if `--state-dir` absent.
2. `floor_ref, floor = history_diff.select_floor_ref(state_dir, days)` inside
   a `try/except LedgerError` -> exit 2 as specified in Q4.
3. Read current: try
   `<state_dir>/ledger/topdown-5g.partial.json` from disk (plain
   `json.load`, not `git show`), `history_diff.validate_ledger(current, label="current")`.
   On any failure (missing file, bad JSON, `LedgerError`), retry the same
   two steps against `<state_dir>/ledger/topdown-5g.json`. If both fail,
   exit 1 as specified in Q3. Track which file supplied `current` for the
   printed provenance line.
4. `deltas, residual_delta = history_diff.compute_deltas(floor, current)`
   (imported, unmodified).
5. Filter `deltas` to `delta_kb > 0` (they arrive pre-sorted descending by
   `compute_deltas`, so this is a prefix filter, not a re-sort), take the
   first `--limit` (default 10).
6. Print, in this exact order (CLAUDE.md Step 1's "state the floor date +
   value and the gap ... before any other measurement"):
   ```
   floor (14d): 749.32 GiB used at 2026-09-06T08:02:11Z (a1b2c3d)
   current: 823.14 GiB used at 2026-09-12T00:37:02Z (partial: 11/17 roots measured)
   gap: +73.82 GiB

   Top 10 growing paths since floor:
   +52.30 GiB  /Users/jleechan/roadmap/worldarchitect.ai/evidence/gemini-memory
   ...
   residual delta: +12.44 GiB
   ```
   The `(partial: X/Y roots measured)` suffix reads
   `current["coverage_envelope"]["measured_top_level_roots"]` /
   `["reachable_top_level_roots"]` when `current["mode"] != "complete"`;
   omitted entirely when current is the canonical complete ledger.
7. Reuse `history_diff.format_kb()` for every size, `history_diff.GIB_KB`
   for the floor/current headline conversion — zero duplicated formatting
   code.

**Why this meets "<10s, no du":** every step is either one `git log`/`git
show` (already proven fast — `history_diff.py`'s existing `--days` path
does the identical git work today) or a local `json.load` of an
already-on-disk file. No `subprocess` call to `du` appears anywhere in this
file.

**CLAUDE.md update (documentation only, not code):** add one line under
Step 1/2 pointing at this command as the fast path, keeping the manual
git-log/git-show ritual as the documented fallback and the specification
`growth-top10` must reproduce (not deleting it — if `growth-top10` itself
needs debugging, or bead `disk_magician-4y6` blocks it from finding a floor,
the manual method is still the operator's escape hatch).

## 5. Component H — close the `~/roadmap`/`~/projects` visibility gap

**Files touched:** `config.json.template`, `scripts/disk_observer.py`.

`config.json.template`: append one `monitored_dirs` entry, placed
alphabetically-near `projects` for readability (not load-bearing —
`monitored_dirs` is consumed as an unordered list by the frontier scanner):

```json
{
  "key": "roadmap",
  "path": "~/roadmap",
  "timeout": 300,
  "retry_timeout": 90
}
```

(Mirrors the existing `projects` entry's shape exactly — same timeout
tier, since both are large, actively-written, non-cache directories.)

`scripts/disk_observer.py`:

```python
DEFAULT_HOT_DIRS = [
    ".codex", ".cache", ".aside", ".ollama", ".openclaw", ".hermes", ".gemini",
    "/private/tmp", "/private/var/folders",
    "Library/Application Support/Cursor", "Library/Application Support/Aside",
    "Library/Caches",
    "roadmap", "projects",   # NEW — bead disk_magician-zyn Component H
]

# _du_kb's shallow 8s default is too tight for these two large, frequently
# large-and-active roots when a step event actually triggers sizing (rare —
# gated behind check_step_event()'s >=10 GiB/30min threshold, never the
# steady 30-60s poll loop). Raise only these two; every other key keeps the
# existing 8s bound unchanged.
DEFAULT_HOT_DIR_TIMEOUTS_SEC = {
    "roadmap": 90,
    "projects": 90,
}
```

```python
def _du_kb(path: Path, run: Runner, timeout: int = 8) -> Optional[int]:
    result = run(["du", "-sk", str(path)], timeout)
    ...  # body unchanged

def collect_hot_dir_sizes(
    home: Path, run: Runner,
    hot_dirs: Sequence[str] = DEFAULT_HOT_DIRS,
    timeouts: Optional[dict] = None,
) -> dict:
    timeouts = timeouts if timeouts is not None else DEFAULT_HOT_DIR_TIMEOUTS_SEC
    sizes = {}
    for name in hot_dirs:
        path = ...  # unchanged resolution
        sizes[name] = _du_kb(path, run, timeout=timeouts.get(name, 8)) if path.exists() else None
    return sizes
```

`build_step_event_record()` gains a passthrough `timeouts: Optional[dict] = None`
kwarg forwarded to `collect_hot_dir_sizes()`, for test injection symmetry;
the CLI does not need a new flag (no caller needs to override this today).

**Acceptance criterion 3 from the bead** ("`step_events.jsonl` `hot_dirs_kb`
has non-null values for roadmap and projects on the next observer run")
requires an actual >=10 GiB/30-min step event to occur to observe — this is
inherently non-deterministic on a live box. The test suite proves the code
path deterministically (mocked `run`, forced `check_step_event` to fire);
production confirmation is "next time a real step event fires, check the
JSONL," not a thing this PR can force on a live host without a real
disk-fill event (and manufacturing one to prove a test is explicitly
against this repo's own safety rules).

## 6. Component: ledger-freshness recognition

**New file:** `scripts/check_ledger_freshness.sh`. **Touched:**
`scripts/check_launchd_fleet.sh` (append one informational section),
`disk_magician.sh` (new dispatch case + usage line).

`scripts/check_ledger_freshness.sh` (read-only, mirrors
`check_launchd_fleet.sh`'s style/exit-code contract):

1. Resolve `state_dir` via `python3 resolve_state_repo_path.py`.
2. Read `<state_dir>/ledger/topdown-5g.partial.json` and
   `<state_dir>/ledger/topdown-5g.json`, each via a tiny inline `python3 -c`
   (repo convention — see `disk_magician.sh`'s own `TOPDOWN_JSON` heredoc
   pattern) extracting `captured_at` and `mode`/`coverage_envelope`. No
   dependency on `history_diff.py` (bash script, avoid Python subprocess
   import path complexity for a 2-field read).
3. Compute `age_hours` for whichever of the two has the newer `captured_at`
   (if both present). Threshold: 36 (matches `render_topdown_ledger.py`'s
   `STALE_HOURS`, see Q6).
4. Print exactly one of:
   - `Ledger: fresh (partial, <mode>, X.Xh old, M/N roots measured) — captured <ts>` — exit 0
   - `Ledger: fresh (complete, X.Xh old) — captured <ts>` — exit 0
   - `⚠️  Ledger: stale (X.Xh old, > 36h) — last complete: <ts-or-"none">, last partial: <ts-or-"none">. Run: ./disk_magician.sh frontier` — exit 1
   - `⚠️  Ledger: no data (neither topdown-5g.json nor topdown-5g.partial.json found at <state_dir>/ledger). Run: ./disk_magician.sh frontier` — exit 1
5. Never touches launchd, never modifies anything — read-only, same
   guarantee `check_launchd_fleet.sh` documents about itself.

`check_launchd_fleet.sh` tail (after the existing `total=...`/`Fleet:
$ok/$total` block, before its own `exit 0`/`exit 1`):

```bash
if [[ -x "$(dirname "$0")/check_ledger_freshness.sh" ]]; then
  "$(dirname "$0")/check_ledger_freshness.sh" || true
fi
```

`|| true` is deliberate: `check_launchd_fleet.sh`'s own exit code continues
to reflect ONLY fleet job health (Q5) — a stale ledger is surfaced in the
same Step -1 output CLAUDE.md already mandates as the first section of
`audit`/`clean`, without making every existing caller that gates on this
script's exit code newly fail for an unrelated reason.

## 7. Risks / explicitly out of scope

- Repo growth from committing `topdown-5g.partial.json` on a ~35-min cadence:
  believed near-zero based on the observed precedent that the *unchanged*
  canonical file hasn't caused runaway growth over 11+ days of identical
  35-min re-writes (§0.7) — the commit step is diff-aware. Not re-verified
  by reading `state_repo.sh` line-by-line (unmodified infrastructure,
  outside this bead's file list); flagged here so a reviewer can decide if
  that's sufficient diligence.
- `growth-top10`'s floor selection can legitimately fail (exit 2) for as
  long as `disk_magician-4y6` remains open and no new complete snapshot
  lands within the rolling 14-day window. This is a **feature** (fail
  closed, name the real blocker) not a bug to route around in this PR.
- `collect_hot_dir_sizes()`'s 90s timeout for `roadmap`/`projects` is a
  judgment call against one day's evidence, not a proven bound under all
  load conditions — explicitly flagged as adjustable, not re-litigated here
  (Q8).
- Does not touch `disk_frontier_scan.py`'s own timeout tiers, EACCES
  handling, or root-privilege requirements (`disk_magician-4y6`'s domain).
- Does not implement `disk_magician-x78`'s ledger-cache-before-`du` refactor
  of `collect_hot_dir_sizes()` — H only widens the existing per-key `du`
  mechanism.

## 8. File list this implementation touches

- `scripts/render_topdown_ledger.py` (modify)
- `scripts/growth_top10.py` (new)
- `scripts/check_ledger_freshness.sh` (new)
- `scripts/check_launchd_fleet.sh` (modify — append one call)
- `scripts/disk_observer.py` (modify — additive constants/params only)
- `disk_magician.sh` (modify — 2 new dispatch cases + usage lines)
- `config.json.template` (modify — 1 new `monitored_dirs` entry)
- `CLAUDE.md` (modify — 1 documentation pointer under Step 1/2, manual
  ritual kept as fallback/spec)
- `tests/test_render_topdown_ledger.py` (modify — new cases)
- `tests/test_disk_observer.py` (modify — update one exact-equality
  assertion, add one timeout-override test)
- `tests/test_growth_top10.py` (new)
- `tests/test_growth_top10_dispatch.sh` (new)
- `tests/test_check_ledger_freshness.sh` (new)
- `src/disk_magician/**` mirrors of every file above (via
  `scripts/sync_package_tree.sh`, glob-based, no script change needed)

No change to: `scripts/history_diff.py`, `scripts/resolve_state_repo_path.py`,
`scripts/disk_snapshot.sh`, `pyproject.toml` (version bump intentionally
deferred — see plan §Deploy).
