# Machine-vs-Human Epistemic Boundary Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Redesign `/Users/jleechan/.claude/skills/human-review-brief/SKILL.md` and `/Users/jleechan/.claude/skills/pr-summary/SKILL.md` around the Machine-vs-Human Epistemic Boundary (banning machine-certifiable homework, enforcing the 4 Epistemic Categories and the Mandatory 3-Subbullet Schema with verified CLI levers), and apply the improved guidance to PR #184 (`/Users/jleechan/roadmap/pr-summary-184-disk-governor.md`).

**Architecture:** Partition the 10 empirical Mac + Linux blind-spot checks into (1) **Section 1: Autonomous Agent Pre-Flight Verification Duties** (reported as verified facts in `## What Was Done` or `### How It Works`), and (2) **Section 2: `## What to Review as a Human`** (restricted to 1–5 items tagged with the 4 Human Epistemic Categories—or an explicit 0-item declaration on purely mechanical/test-only PRs—where every bullet states `Decision / Behavior at Stake`, `Why an LLM / Test Suite Cannot Certify This`, and `Human Judgment Needed & Override / Rollback Lever` with a backticked CLI/config lever). Validate skill and PR-summary compliance via a deterministic structural Python contract validator (`validate_human_review_brief.py`).

**Tech Stack:** Markdown skill specifications (`~/.claude/skills/`, projected via existing `~/.agents/skills/` symlinks), Python 3 stdlib (`re`, `sys`, `pathlib`, `unittest`) for deterministic structural contract verification.

**Spec:** `docs/superpowers/specs/2026-10-14-human-review-epistemic-boundary-design.md`

---

### Task 1: Build the Deterministic Human-Review-Brief Structural Validator & Unit Tests

**Files:**
- Create: `/Users/jleechan/.claude/skills/human-review-brief/scripts/validate_human_review_brief.py`
- Test: `/Users/jleechan/.claude/skills/human-review-brief/tests/test_validate_human_review_brief.py`

**Step 1: Write the failing test**

Create `/Users/jleechan/.claude/skills/human-review-brief/tests/test_validate_human_review_brief.py`:

```python
import pathlib
import unittest
from scripts.validate_human_review_brief import validate_markdown_text


BAD_LEGACY_SECTION = """
## 4. What to Review as a Human (`human-review-brief` Section 2)

1. **Zero-Framework Cognition (ZFC) & Scope-Blind Backend Guards**:
   - Review `/Users/jleechan/.worktrees/disk_magician/task11-receipt-accounting/scripts/worktree_quarantine.py` lines `314–340` (`bind_restored_checkout`) where `(checkout_dev, checkout_inode)` are verified.
2. **Cross-Host (macOS vs Linux) & Python Subprocess Parity**:
   - Review `scripts/lib/actuator_deadline.sh:18`: on macOS, Python 3.9.6 uses a process-relative `time.monotonic()` epoch.
- **What Current Evidence Does NOT Prove**:
  - Not deployed yet.
- **Exact Human Decision Needed**:
  - Reply MERGE APPROVED.
"""

REPHRASED_HOMEWORK_SECTION = """
## 4. What to Review as a Human

1. **`[Policy / Risk Tradeoff]` Guard Inspection**:
   - **Decision / Behavior at Stake**: Inspect `scripts/foo.py:42` and verify lines 40-55 handle array edge cases.
   - **Why an LLM / Test Suite Cannot Certify This**: Could be tricky.
   - **Human Judgment Needed & Override / Rollback Lever**: Check the file manually without any command lever.
- **What Current Evidence Does NOT Prove**:
  - Live load.
- **Exact Human Decision Needed**:
  - Reply `MERGE APPROVED`.
"""

UNVERIFIED_ESCALATION_SECTION = """
## 4. What to Review as a Human

1. **`[Sim-to-Real / Ops Gap]` `[BLOCKED]` Unverified Live Host Check (`scripts/foo.sh:42`)**:
   - **Decision / Behavior at Stake**: The live systemd probe at `scripts/foo.sh:42` could not be executed in this container (`systemctl show` returned connection refused).
   - **Why an LLM / Test Suite Cannot Certify This**: Host daemon access was unavailable during the offline test run.
   - **Human Judgment Needed & Override / Rollback Lever**: Run `diskm check-launchd-fleet` on the target host before enabling.
- **What Current Evidence Does NOT Prove**:
  - Live host execution.
- **Exact Human Decision Needed**:
  - Reply `MERGE APPROVED`.
"""

ZERO_ITEMS_SECTION = """
## 4. What to Review as a Human

- None — no human-epistemic decisions; all changes are machine-certified in Section 1.
- **What Current Evidence Does NOT Prove**:
  - Only unit tests ran; no live deployment needed for test-only refactor.
- **Exact Human Decision Needed**:
  - Reply `MERGE APPROVED`.
"""

CLOSING_LEAK_SECTION = """
## 4. What to Review as a Human

1. **`[Policy / Risk Tradeoff]` Autonomous Actuation**:
   - **Decision / Behavior at Stake**: Enables `--act` in governor launchd template.
   - **Why an LLM / Test Suite Cannot Certify This**: Risk appetite tradeoff between disk protection and false throttling.
   - **Human Judgment Needed & Override / Rollback Lever**: Pause the governor service without backticks here.
- **What Current Evidence Does NOT Prove**:
  - Live `diskm deploy` execution.
- **Exact Human Decision Needed**:
  - Reply `MERGE APPROVED`.
"""

GOOD_EPISTEMIC_SECTION = """
## 4. What to Review as a Human (`human-review-brief` Section 2)

1. **`[Policy / Risk Tradeoff]` Autonomous Non-Worktree Actuation (`--act`)**:
   - **Decision / Behavior at Stake**: Once deployed, the launchd governor runs with `--act` enabled to dispatch non-worktree cleanups automatically.
   - **Why an LLM / Test Suite Cannot Certify This**: Tests prove `C14` gates hold, but cannot decide your personal risk tolerance between automatic cleanup and observe-only monitoring.
   - **Human Judgment Needed & Override / Rollback Lever**: Confirm `--act` matches your 14-day pilot risk appetite; pause via `launchctl bootout gui/$(id -u)/com.jleechanorg.disk-magician-govern` or switch to observe-only via `diskm budget set-stage observe`.
2. **`[Human Workflow Intent]` Quarantine Staging & 2-Hour Released-Worktree Recycling**:
   - **Decision / Behavior at Stake**: Under `<10 GiB` free disk pressure, `worktree_new.sh` can recycle a clean, pushed worktree whose lease was released or whose owner PID died `>2h` ago by moving it into quarantine.
   - **Why an LLM / Test Suite Cannot Certify This**: Kernel `lsof` and Git checks cannot observe whether you still intend to inspect a dead-PID worktree in an open editor mental thread.
   - **Human Judgment Needed & Override / Rollback Lever**: Restore any needed worktree via `python3 scripts/worktree_quarantine.py restore <id>` or `diskm quarantine restore <id>`.
- **What Current Evidence Does NOT Prove**:
  - Does not prove live 14-day launchd pilot execution on the 1 TB APFS volume.
- **Exact Human Decision Needed**:
  - Reply `MERGE APPROVED` on PR #184 once CI step 9 finishes green.
"""


class ValidateHumanReviewBriefTests(unittest.TestCase):
    def test_rejects_legacy_machine_homework_and_missing_subbullets(self):
        errors = validate_markdown_text(BAD_LEGACY_SECTION)
        self.assertTrue(any("Decision / Behavior at Stake" in e for e in errors))
        self.assertTrue(any("machine-certifiable homework" in e for e in errors))
        self.assertTrue(any("title must include one of" in e for e in errors))

    def test_rejects_rephrased_homework_and_missing_lever_backticks(self):
        errors = validate_markdown_text(REPHRASED_HOMEWORK_SECTION)
        self.assertTrue(any("machine-certifiable homework" in e for e in errors))
        self.assertTrue(any("backticked CLI command or config lever" in e for e in errors))

    def test_bounds_item_end_before_closing_bullets(self):
        errors = validate_markdown_text(CLOSING_LEAK_SECTION)
        self.assertTrue(any("backticked CLI command or config lever" in e for e in errors))

    def test_allows_unverified_or_blocked_escalation_in_title(self):
        errors = validate_markdown_text(UNVERIFIED_ESCALATION_SECTION)
        self.assertEqual(errors, [])

    def test_allows_explicit_zero_items_declaration(self):
        errors = validate_markdown_text(ZERO_ITEMS_SECTION)
        self.assertEqual(errors, [])

    def test_accepts_valid_epistemic_boundary_section(self):
        errors = validate_markdown_text(GOOD_EPISTEMIC_SECTION)
        self.assertEqual(errors, [])


if __name__ == "__main__":
    unittest.main()
```

**Step 2: Run test to verify it fails**

Run:
```bash
PYTHONPATH=/Users/jleechan/.claude/skills/human-review-brief python3 -m unittest discover -s /Users/jleechan/.claude/skills/human-review-brief/tests -p 'test_*.py' -v
```
Expected: FAIL with `ModuleNotFoundError: No module named 'scripts.validate_human_review_brief'`.

**Step 3: Write minimal implementation**

Create `/Users/jleechan/.claude/skills/human-review-brief/scripts/validate_human_review_brief.py` implementing the structural contract from Spec D3 (section extraction, `items_region` bounded before `- **What Current Evidence Does NOT Prove**`, 1–5 items or explicit `None — no human-epistemic decisions; all changes are machine-certified in Section 1` declaration, canonical `[Category Tag]` in every title, `[UNVERIFIED]`/`[BLOCKED]` restricted to `[Sim-to-Real / Ops Gap]` titles, structural line-reference detection `lines X-Y` / `file.ext:123` outside `[UNVERIFIED]`/`[BLOCKED]` titles, 3 required subbullets, backticked lever requirement, and both closing bullets).

**Step 4: Run test to verify it passes**

Run:
```bash
PYTHONPATH=/Users/jleechan/.claude/skills/human-review-brief python3 -m unittest discover -s /Users/jleechan/.claude/skills/human-review-brief/tests -p 'test_*.py' -v
```
Expected: PASS (`Ran 6 tests ... OK`).

---

### Task 2: Update `/Users/jleechan/.claude/skills/human-review-brief/SKILL.md` and `/Users/jleechan/.claude/skills/pr-summary/SKILL.md`

**Files:**
- Modify: `/Users/jleechan/.claude/skills/human-review-brief/SKILL.md`
- Modify: `/Users/jleechan/.claude/skills/pr-summary/SKILL.md`
- Verify existing symlink: `/Users/jleechan/.agents/skills/human-review-brief` -> `/Users/jleechan/.claude/skills/human-review-brief` (never touch `~/.codex/skills/`)
- Test: `/Users/jleechan/.claude/skills/human-review-brief/tests/test_validate_human_review_brief.py`

**Step 1: Add failing test for both `SKILL.md` files and `~/.agents/skills/human-review-brief` projection**

Add `test_skills_and_agents_symlink_contain_epistemic_boundary_contract` to `/Users/jleechan/.claude/skills/human-review-brief/tests/test_validate_human_review_brief.py` asserting that both `/Users/jleechan/.claude/skills/human-review-brief/SKILL.md` and `/Users/jleechan/.claude/skills/pr-summary/SKILL.md` contain:
- `Machine-vs-Human Epistemic Boundary`
- `Ban on Machine-Certifiable Homework`
- `Decision / Behavior at Stake`
- `Why an LLM / Test Suite Cannot Certify This`
- `Human Judgment Needed & Override / Rollback Lever`
and that `/Users/jleechan/.agents/skills/human-review-brief` is a symlink resolving to `/Users/jleechan/.claude/skills/human-review-brief`.

**Step 2: Run test to verify it fails (RED)**

Run:
```bash
PYTHONPATH=/Users/jleechan/.claude/skills/human-review-brief python3 -m unittest discover -s /Users/jleechan/.claude/skills/human-review-brief/tests -p 'test_*.py' -v
```
Expected: FAIL on `AssertionError` because the legacy `SKILL.md` files do not yet contain the epistemic boundary contract clauses.

**Step 3: Update `/Users/jleechan/.claude/skills/human-review-brief/SKILL.md` and `/Users/jleechan/.claude/skills/pr-summary/SKILL.md`**

1. Update `/Users/jleechan/.claude/skills/human-review-brief/SKILL.md` so:
   - Section 1 (`## What Was Done`) includes bullet 5 (`Autonomous Mac + Linux Blind-Spot Pre-Flight Verification`) covering ZFC/inode/lock mechanics, cross-host Bash 3.2/Python monotonic clock parity, subprocess `< /dev/null` stdin/hook hygiene, and provider schema probing.
   - Section 2 (`## What to Review as a Human`) enforces the **Machine-vs-Human Epistemic Boundary**, the **Ban on Machine-Certifiable Homework**, the **4 Epistemic Categories** (`[Policy / Risk Tradeoff]`, `[Human Workflow Intent]`, `[Sim-to-Real / Ops Gap]`, `[Perceptual / UX]`), 1–5 items or the explicit 0-item declaration, the **Mandatory 3-Subbullet Schema** with verified backticked CLI/config levers, and the **Mandatory Closing Bullets**.
2. Update `/Users/jleechan/.claude/skills/pr-summary/SKILL.md` (`#### ### What to Review as a Human`) to enforce the same Machine-vs-Human Epistemic Boundary, 4 Epistemic Categories, 3-subbullet schema, and `validate_human_review_brief.py` validation check.

**Step 4: Run test to verify it passes (GREEN)**

Run:
```bash
PYTHONPATH=/Users/jleechan/.claude/skills/human-review-brief python3 -m unittest discover -s /Users/jleechan/.claude/skills/human-review-brief/tests -p 'test_*.py' -v
```
Expected: PASS (`Ran 7 tests ... OK`).

---

### Task 3: Rewrite PR #184 Summary (`/Users/jleechan/roadmap/pr-summary-184-disk-governor.md`) Around the Epistemic Boundary

**Files:**
- Modify: `/Users/jleechan/roadmap/pr-summary-184-disk-governor.md`
- Test: `/Users/jleechan/.claude/skills/human-review-brief/scripts/validate_human_review_brief.py`

**Step 1: Run the validator against the legacy `/Users/jleechan/roadmap/pr-summary-184-disk-governor.md` to verify it fails (RED)**

Run:
```bash
python3 /Users/jleechan/.claude/skills/human-review-brief/scripts/validate_human_review_brief.py /Users/jleechan/roadmap/pr-summary-184-disk-governor.md
```
Expected: FAIL (exit 1) reporting structural machine-certifiable homework (`Review .../scripts/worktree_quarantine.py lines 314–340`), missing category tags, and missing required subbullets (`Decision / Behavior at Stake`, `Why an LLM / Test Suite Cannot Certify This`, `Human Judgment Needed & Override / Rollback Lever`).

**Step 2: Update `/Users/jleechan/roadmap/pr-summary-184-disk-governor.md`**

In `/Users/jleechan/roadmap/pr-summary-184-disk-governor.md`:
1. Move the verified mechanical invariants (`bind_restored_checkout` inode verification, `worktree_new.sh` vacated-branch preservation, and `actuator_deadline.sh` Python `time.monotonic()` interpreter-family consistency) into `## 3. What Was Done` bullet 5 (`Autonomous Mac + Linux Blind-Spot Pre-Flight Verification`).
2. Rewrite `## 4. What to Review as a Human` using the 5 independently actionable human-epistemic items from Spec D5 (`[Policy / Risk Tradeoff]` on `--act`, `[Policy / Risk Tradeoff]` on conservative missing-birth charging & admission stage thresholds, `[Human Workflow Intent]` on quarantine-first staging & 2h low-disk worktree recycling, `[Sim-to-Real / Ops Gap]` on live 1 TB APFS latency & two-step `diskm deploy` + `install_launchd_sweepers.sh` cutover, and `[Human Workflow Intent]` on decoupled external consumer hook rollout) with verified CLI commands (`diskm budget status`, `diskm budget set-stage observe`, `diskm budget set-margin <gb>`, `diskm budget promote-estimates`, `diskm quarantine restore <id>`, `python3 scripts/worktree_quarantine.py restore <id>`, `diskm birth-audit`, `diskm budget status --pilot-check`, `launchctl bootout gui/$(id -u)/com.jleechanorg.disk-magician-govern`, `git revert <merge-sha>` on `origin/main` + `diskm deploy`), plus `What Current Evidence Does NOT Prove` and `Exact Human Decision Needed`.

**Step 3: Run the validator and unit tests to verify they pass (GREEN)**

Run:
```bash
python3 /Users/jleechan/.claude/skills/human-review-brief/scripts/validate_human_review_brief.py /Users/jleechan/roadmap/pr-summary-184-disk-governor.md && PYTHONPATH=/Users/jleechan/.claude/skills/human-review-brief python3 -m unittest discover -s /Users/jleechan/.claude/skills/human-review-brief/tests -p 'test_*.py' -v
```
Expected: PASS (`/Users/jleechan/roadmap/pr-summary-184-disk-governor.md: OK` and all 7 unit tests `OK`).

---

## TDD Plan Check

| Task | Behavior Change? | TDD Sequence Verified |
|---|---|---|
| **Task 1: `validate_human_review_brief.py`** | Yes (new Python structural contract validator) | **Verified**: Step 1 writes failing unit tests (`test_validate_human_review_brief.py`) -> Step 2 runs `unittest discover` and verifies `ModuleNotFoundError` (RED) -> Step 3 writes `validate_human_review_brief.py` -> Step 4 runs `unittest discover` and verifies `OK` (GREEN). |
| **Task 2: `human-review-brief/SKILL.md` + `pr-summary/SKILL.md`** | Yes (skill contract change across both skills) | **Verified**: Step 1 adds `test_skills_and_agents_symlink_contain_epistemic_boundary_contract` -> Step 2 runs `unittest discover` and verifies `AssertionError` against legacy `SKILL.md` files (RED) -> Step 3 updates both `SKILL.md` files and verifies `~/.agents/skills/human-review-brief` symlink -> Step 4 runs `unittest discover` and verifies `OK` (GREEN). |
| **Task 3: `pr-summary-184-disk-governor.md`** | Yes (enforces contract on PR #184 summary) | **Verified**: Step 1 runs `validate_human_review_brief.py` against legacy `pr-summary-184-disk-governor.md` and verifies exit 1 with banned homework, missing category tags, and missing subbullets (RED) -> Step 2 updates `pr-summary-184-disk-governor.md` with verified `diskm` CLI levers -> Step 3 re-runs `validate_human_review_brief.py` and `unittest discover` to verify exit 0 `OK` (GREEN). |
