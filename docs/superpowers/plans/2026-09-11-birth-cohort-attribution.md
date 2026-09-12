# Birth-Cohort Attribution — Plan (disk_magician-6wd)

**Goal:** Close `disk_magician-6wd` as refuted; no code is built.

**Architecture:** N/A — the mandatory falsification probe specified by the bead itself returned a clean negative (0 GiB of 18.0 GiB attributed across all 4 candidate roots), and the bead's own contract states that a refuted probe ends in bead closure, not an implementation.

**Tech Stack:** N/A

---

Full evidence, method, and the probe's raw numbers are in the paired design spec: `docs/superpowers/specs/2026-09-11-birth-cohort-attribution-design.md`. This plan has exactly one task.

### Task 1: Close the bead as refuted

**Files:** none (no code touched — no `scripts/newborn_cohort.py`, no `disk_observer.py` hook, no `config.json.template` stanza, no `pyproject.toml` version bump, no `sync_package_tree.sh` run — none of these apply because nothing was built).

**Step 1: Record the refutation in the bead**

```bash
br update disk_magician-6wd --status closed --resolution refuted \
  --note "Falsification probe (mandatory per bead text) found 0 GiB of the target 18.0 GiB / 29.8min step event (2026-09-12T00:07:40Z) attributable to newborn files across the 4 safety-bounded candidate roots (/private/tmp, /private/var/folders/.../T, ~/.cache, ~/roadmap/worldarchitect.ai/evidence) — 0% vs the required >=30% material-fraction bar, in a well-powered control (2.65M total files under the 4 roots; a 24h control window on the same /private/tmp root returned 68,104 matches, confirming the -newerBt filter and roots are live, not broken/empty). Full evidence: docs/superpowers/specs/2026-09-11-birth-cohort-attribution-design.md."
```

(Adjust exact `br` flags to whatever this repo's `br` CLI actually supports for closing with a resolution note — see `~/.claude/skills/beads-issue-tracking/SKILL.md` for the canonical close syntax; the important content is the note text above, not the exact flag spelling.)

**Step 2: Cross-link from the design spec (already done)**

The design spec at `docs/superpowers/specs/2026-09-11-birth-cohort-attribution-design.md` §5–§6 already documents the refutation and a secondary, independent defect found in the same design (the `stat -f %b` clone-double-counting claim in roadmap §6 does not hold — see spec §6). No further edit needed there.

**Step 3: No commit of source changes**

There is nothing to `git add`/`git commit` beyond the two new docs (spec + this plan), since no script or config file was created or modified. If the two docs themselves are to be committed, that is a normal doc-only commit with no version bump and no `sync_package_tree.sh` run (both are deploy mechanics for `src/disk_magician/` and repo-root scripts respectively; neither changed).

### Explicitly not done (per the dispatching contract: "do not invent a rescue")

- No `scripts/newborn_cohort.py` (per-root `find -newerBt` scanner, 5-rung owner lookup, JSON emitter).
- No `config.json.template` stanza for birth-cohort roots/timeouts.
- No `disk_observer.py` hook call at step-event time.
- No unit tests against a temp tree.
- No widening of the falsification probe to the remaining null hot-dirs (`.aside`, `.codex`, `.gemini`, `Library/Caches`, Cursor/Aside app-support) to look for the 18 GiB elsewhere — that would be a different, new investigation (or a new bead), not a rescue of this one.
- No design for a "grown-file" (append/truncate) detector to cover birth-cohort's structural blind spot noted in the spec §5 — same reasoning: that is a different mechanism than what disk_magician-6wd asked for, and inventing it now would be exactly the forbidden rescue.
