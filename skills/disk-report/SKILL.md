---
name: disk-report
description: Use when the user wants a full-disk breakdown report with every bucket over 5 GiB drilled down to leaves, reconciled to total disk capacity.
---

# disk-report — full ≥5GiB-granularity breakdown, reconciled to total capacity

Produces a single markdown report where **every node over 5 GiB is expanded to its children** (recursively) until each row is either ≤5 GiB or genuinely opaque (a single undecomposed measured blob), and where the table **reconciles to the drive's real total capacity** (used + free) — not just to the used-space subset. Read-only: this skill never deletes anything and never proposes destructive commands.

Pair with `scripts/disk_report_breakdown.py` (pure-Python tree/reconciliation logic, no subagent spawning) and `tests/test_disk_report_breakdown.sh` (fixture-based regression coverage).

## Step 1 — Source snapshot selection

Prefer the live frontier scan state if it's fresh and non-empty:

```bash
python3 - <<'PY'
import json, time
p = "~/.disk_magician_state/frontier_last.json"
import os
p = os.path.expanduser(p)
try:
    d = json.load(open(p))
    print("captured_at:", d.get("captured_at"), "buckets:", len(d.get("granularity_buckets") or []))
except (OSError, ValueError) as e:
    print("unreadable:", e)
PY
```

Use `~/.disk_magician_state/frontier_last.json` when `captured_at` is **<36h old** AND `granularity_buckets` is non-empty. Exact field names (do not guess others): `captured_at`, `granularity_buckets` (list of `{"path"` or `"source_path", "measured_kb"}`), `oversize_indivisible_files` (same shape, for files too big to subdivide), `residual_kb`.

Otherwise, fall back to the **densest** of the last ~14 daily commits to the git-backed ledger:

```bash
git -C ~/.disk_magician_backup log --oneline -14 -- ledger/topdown-5g.json
# for each <sha> above:
git -C ~/.disk_magician_backup show <sha>:ledger/topdown-5g.json > /tmp/candidate-<sha>.json
python3 -c "import json; print(len(json.load(open('/tmp/candidate-<sha>.json')).get('granularity_buckets') or []))"
```

Pick the candidate with the **most `granularity_buckets` entries** (densest = most information). The ledger schema (see `scripts/render_topdown_ledger.py`) uses the identical field names as the frontier state.

**State the chosen source + its `captured_at` timestamp in the report header — never silently mix sources.**

## Step 2 — Total disk capacity (df, not the snapshot)

```bash
df -k /System/Volumes/Data
```

Parse TOTAL/USED/FREE in KB. State in the report that this is the drive's **real usable APFS capacity**, typically **not exactly 1024 GiB / "1TB"** even on a nominal 1TB drive — decimal-vs-binary GiB conversion plus filesystem/container overhead reduce it (e.g. ~926 GiB observed on this machine). The correctness invariant is `sum(all top-level rows) + residual + free == this measured total capacity` — never a hardcoded 1024/931 GiB assumption. These df numbers become `--df-total-kb` / `--df-free-kb` to the render subcommand below.

## Step 3 — Build tree

`scripts/disk_report_breakdown.py` does this parsing for you (do not reimplement it in shell): it strips a trailing bracketed suffix (e.g. `" [direct files + directory metadata 1/2]"`) and a leading `/System/Volumes/Data` prefix from each bucket path, inserts every path into a component trie, and computes each node's subtree sum bottom-up.

## Step 4 — Full expansion rule (no elision)

Any node whose subtree sum is **> 5 GiB** (`5*1048576` KB) MUST show **all** of its immediate children as separate rows, recursively, until every leaf row is either `<= 5 GiB` or **opaque** (subtree `> 5 GiB` but the ledger has zero children for it — a single measured blob: a large file, an un-decomposed directory, or an `oversize_indivisible_files` entry). This is handled by `disk_report_breakdown.py render`; do not hand-truncate the table.

## Step 5 — Parallel drill-down for opaque >5GiB leaves

This is the actual fan-out — it happens when **this skill runs**, not inside the Python script (the script never spawns subagents or shells out).

1. Get the opaque leaves needing drill-down:
   ```bash
   python3 scripts/disk_report_breakdown.py list-opaque-leaves --snapshot <chosen-snapshot> \
     > /tmp/disk-report-opaque-leaves.json
   ```
2. Sample load: `uptime` (load1) and `sysctl -n hw.ncpu` (core count).
3. Enumerate every opaque leaf from step 1 — these are independent, disjoint subtrees with no shared mutable state, so they are safe to fan out.
4. Apply the **same backpressure threshold `disk_frontier_scan.py`'s own scanner uses** (`maybe_throttle()`, `scripts/disk_frontier_scan.py:900-919`), for consistency with the rest of this repo's tooling: `under_pressure = load1 > ncpu OR free_gb < 15`.
   - If **not** under pressure: fan out **one lane per opaque leaf**, up to all of them at once.
   - If **under pressure**: cap concurrency to **4 lanes max**.
   Either way, each lane runs a **shallow, non-recursive** listing scoped only to its own leaf — never a full recursive `du` (this machine's `du` repeatedly stalls/EINTRs on deep recursive calls under load; see this repo's `CLAUDE.md` and `findings_wiki/`):
   ```bash
   timeout 45 du -sk "<leaf>"/*/ 2>/dev/null   # preferred
   # or, if du is unavailable/unreliable: ls -lhS "<leaf>"
   ```
5. **Isolation invariant:** each lane writes its result to its **own** scratch file — never a shared mutable file:
   ```
   docs/.disk-report-scratch/<url-safe-slug-of-leaf-path>.json
   ```
   Create the directory if missing; `docs/.disk-report-scratch/` is gitignored. Scratch file schema (exact, matches `disk_report_breakdown.py`'s `render` splice logic):
   ```json
   {"leaf": "<path>", "children": [{"path": "<abs path>", "kb": <int>}, ...]}
   ```
6. After all lanes complete (or hit their 45s timeout), do a **single** merge step: `render` (step 6 below) reads every scratch file and splices results into the tree at the matching node. A timed-out lane's leaf stays **opaque** in the final report, explicitly marked `[opaque]` — never silently dropped.

## Step 6 — Reconciliation invariants (mandatory, never silently fail)

`disk_report_breakdown.py render` computes both and emits an explicit gap row for either:

- **(a) parent == sum(children).** Every parent's subtree sum must equal the sum of its immediate children (within ~0.05 GiB rounding). A mismatch — most likely from a scratch-drilled leaf's children summing differently than the leaf's original ledger measurement — becomes a row: `(reconciliation gap at <path>: <reason>)`.
- **(b) sum(all top-level rows) + residual_kb (if present) + free_space == total_capacity_from_df.** This is the "whole disk, not just used space" requirement. A mismatch becomes a row: `(unaccounted vs df total capacity: <delta> GiB)`. Never hardcode 1024/931 GiB — always the live `df` total from Step 2.

## Step 7 — Render + output

```bash
python3 scripts/disk_report_breakdown.py render \
  --snapshot <chosen-snapshot> \
  --scratch-dir docs/.disk-report-scratch \
  --df-total-kb <TOTAL_KB> \
  --df-free-kb <FREE_KB> \
  --out docs/disk-report-$(date +%Y-%m-%d).md
```

The written report's header states: the source snapshot + its timestamp, df total/used/free (with the "not exactly 1TB, here's why" one-liner), total row count, and PASS/FAIL + gap amounts for both invariants. Table columns: `GiB | Path` (indented by depth, `▼` for expanded parents, `[opaque]` tag for undecomposed >5GiB leaves).

## Step 8 — Commit + push

```bash
git add docs/disk-report-<date>.md   # path-scoped only — never git add -A / git add .
git commit -m "findings: full disk breakdown report <date>"
git push
```

Report the resulting commit SHA.

## Step 9 — Read-only stance

This skill never deletes anything and never runs a destructive command inline. Recommendations, if any, are the same posture as `disk-root-cause`: safe-cleanup commands are named for the human to run, not auto-executed.

## Exit criteria

- [ ] Source snapshot + its timestamp stated (frontier vs ledger, never silently mixed)
- [ ] Live `df -k` total/used/free captured; "not exactly 1TB" caveat stated
- [ ] Every node >5 GiB expanded to children, recursively, until ≤5 GiB or opaque
- [ ] Opaque leaves drilled in parallel lanes per the backpressure-aware fan-out rule, each isolated to its own scratch file
- [ ] Timed-out lanes marked `[opaque]`, not silently dropped
- [ ] Both reconciliation invariants computed with explicit gap rows (never silently rounded away)
- [ ] Report written to `docs/disk-report-<date>.md`, committed with a `findings:` prefix, and pushed
- [ ] No destructive command executed or proposed inline
