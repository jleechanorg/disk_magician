# Machine-vs-Human Epistemic Boundary for `human-review-brief` and `pr-summary` — Design Specification

Date: 2026-10-14
Status: Design (approved via `/sq` auto-pick; implementation tracked in the companion plan)
Plan: `docs/superpowers/plans/2026-10-14-human-review-epistemic-boundary.md`

## 1. Problem Statement

When summarizing PR #184 (`/Users/jleechan/roadmap/pr-summary-184-disk-governor.md`), the generated `## What to Review as a Human` section followed the existing `/Users/jleechan/.claude/skills/human-review-brief/SKILL.md` instructions literally—and produced low-value, machine-certifiable homework for the human reviewer:

1. **Mechanical Code / Inode Verification Offloaded to Human**:
   - *"Review `scripts/worktree_quarantine.py` lines `314–340` (`bind_restored_checkout`) and `269–307` (`rollback`), where checkout `.git` pointer and `(checkout_dev, checkout_inode)` are verified before running `git worktree repair` or `git worktree unlock`."*
   - Why this failed: Checking whether `bind_restored_checkout` compares `(dev, ino)` before running `git worktree repair` is a deterministic mechanical property that unit tests and LLM code reviewers (`/cs`, `/advice`, `/wa`) already verified. Asking a human to read lines 314–340 wastes human attention on machine work.
2. **OS / Language Runtime Quirk Offloaded to Human**:
   - *"Review `scripts/lib/actuator_deadline.sh` and `tests/test_review_cleanup_deadline_receipt.py` lines `18–32` and `172–194`: on macOS, Xcode CLT `/usr/bin/python3` (Python 3.9.6) uses a process-relative `time.monotonic()` epoch (`~0.005s` at startup), whereas Python 3.10+ uses system uptime (`CLOCK_UPTIME_RAW`)."*
   - Why this failed: Interpreter-epoch compatibility across subprocess boundaries is a pure deterministic bug class. Once tested and fixed, it belongs in `## What Was Done` (or `### How It Works`), not in `## What to Review as a Human`.

### Root Cause in Current Skill Instructions

In `/Users/jleechan/.claude/skills/human-review-brief/SKILL.md` (lines 34–62), Section 2 (`## What to Review as a Human`) conflates two fundamentally different concepts:
- **Agent Pre-Flight Verification Duties** (e.g., Category 5 *"Cite exact `file:line` for any new backend guard, clamp, fallback"*, Category 8 *"Verify portability across macOS Bash 3.2 ... and Linux"*, Category 10 *"Confirm backgrounded CLI invocations close stdin"*), which the agent/test suite/LLM reviewers must verify *before* claiming readiness; and
- **Genuine Human Epistemic Decisions** (value/risk tradeoffs, unobservable human workflow intent, sim-to-real production gaps, and perceptual UX judgment), which no LLM or closed-world test suite can certify on the owner's behalf.

Because the skill instructed agents to *"Select 3 to 6 concrete bullets from the 10 empirical Mac + Linux blind-spot categories"* and *"Cite exact `file:line`"*, agents dutifully formatted their completed mechanical checks as "things for the human to review."

---

## 2. Goals & Non-Goals

### Goals
1. **Enforce the Machine-vs-Human Epistemic Boundary**: Draw a hard architectural line between what machines/tests/LLMs can certify (which must be proven autonomously and reported as facts in `## What Was Done`) and what requires human judgment (which belongs in `## What to Review as a Human`).
2. **Ban Machine-Certifiable Homework from `## What to Review as a Human`**: Prohibit prompts asking the human to inspect `file:line` mechanical guards, inode/lock races, OS/Python version quirks, syntax, or test wiring—unless a required check is explicitly marked `[UNVERIFIED]` or `[BLOCKED]` and escalated as a known gap.
3. **Define the 4 Epistemic Categories of Human Review**: Restrict `## What to Review as a Human` items (1 to 5 items per brief, or 0 items with an explicit `"None — no human-epistemic decisions; all changes are machine-certified in Section 1"` declaration on purely mechanical/test-only PRs) to:
   - Category 1: **Policy, Value & Risk-Appetite Tradeoffs (`[Policy / Risk Tradeoff]`)**
   - Category 2: **Unobservable Human Intent & External Workflow State (`[Human Workflow Intent]`)**
   - Category 3: **Sim-to-Real / Closed-World Test Illusion (`[Sim-to-Real / Ops Gap]`)**
   - Category 4: **Perceptual / UX / Aesthetic Judgment (`[Perceptual / UX]`)** (when UI/UX/copy changes)
4. **Enforce a Mandatory 3-Subbullet Format per Human Review Item**:
   - **Decision / Behavior at Stake** (plain English, zero code-reading required)
   - **Why an LLM / Test Suite Cannot Certify This** (the specific epistemic gap)
   - **Human Judgment Needed & Override / Rollback Lever** (the concrete decision question, production symptom to watch for, and verified single CLI command or config knob to adjust/revert it)
5. **Preserve the 10 Empirical Mac + Linux Blind-Spot Checks as Agent Pre-Flight Duties**: Move the mechanical blind-spot checks into Section 1 (`## What Was Done` / Agent Pre-Flight Verification) so agents still check them without dumping them onto the human as review homework.
6. **Apply the Redesigned Guidance to PR #184**: Rewrite `/Users/jleechan/roadmap/pr-summary-184-disk-governor.md` Section 4 (`## 4. What to Review as a Human`) using verified `diskm` CLI commands as the canonical exemplar.

### Non-Goals
- Modifying any tracked files inside `/Users/jleechan/.worktrees/disk_magician/task11-receipt-accounting` (strictly isolated for concurrent coding lanes).
- Adding any files or symlinks under `~/.codex/skills/` (which is not a skill root per global policy; only `~/.claude/skills/` and existing `~/.agents/skills/` projections are used).
- Weakening any existing `/green`, `/es`, `/er`, `/cs`, `/advice`, or `/wa` gate requirements.
- Removing `file:line` provenance from the rest of `/pr-summary` (`### How It Works` and `## What Was Done` retain full file and line provenance).

---

## 3. Architectural Approaches Considered

| Approach | Description | Verdict |
|---|---|---|
| **A. Prose Disclaimer Only** | Keep the 10 categories in Section 2 of `human-review-brief/SKILL.md` and add a warning: *"Do not include things a machine can check."* | **Rejected**: Self-contradictory. Categories 5, 8, 9, and 10 in Section 2 explicitly tell the agent to cite `file:line` guards and OS/shell portability checks inside `## What to Review as a Human`. Agents follow structural templates over prose disclaimers. |
| **B. Unstructured "Ask the LLM What Needs Human Judgment"** | Delete the 10 empirical categories and tell the agent to brainstorm 3–5 human review items from scratch on every turn. | **Rejected**: Discards hard-won empirical memory (merge-tree silent reverts, substitute-provider gates, cross-PR ratchets, sim-to-real gaps). Without structured categories and a required 3-subbullet schema, agents regress to generic filler (*"Review the tests to make sure edge cases are covered"*). |
| **C. Two-Stage Epistemic Boundary Architecture + 3-Subbullet Contract + Deterministic Structural Validator (Recommended)** | Partition `human-review-brief/SKILL.md` and `pr-summary/SKILL.md` into: (1) **Machine-Certifiable Pre-Flight Duties** (verified by the agent and reported in `## What Was Done`, only escalated to the human if *unverified/blocked*), and (2) **The 4 Human Epistemic Categories** in `## What to Review as a Human`, where every item must pass the **Epistemic Litmus Test**, carry a canonical `[Category Tag]`, use the **3-Subbullet Contract** (`Decision / Behavior at Stake`, `Why an LLM / Test Suite Cannot Certify This`, `Human Judgment Needed & Override / Rollback Lever` with a backticked CLI/config lever), and pass `validate_human_review_brief.py`. | **Selected**: Eliminates machine homework by construction, preserves every empirical Mac/Linux blind-spot check as an agent pre-flight duty, and gives the human actionable policy/workflow/operational decisions with verified one-command levers. |

---

## 4. Detailed Design

### D1. The Epistemic Litmus Test & Ban on Machine-Certifiable Homework

Before placing any item into `## What to Review as a Human`, the agent must apply the **Epistemic Litmus Test**:

> *"Could a deterministic test, static analyzer, or independent LLM reviewer (`/cs`, `/advice`, `/wa`) verify whether this is right or wrong given the existing specification?"*

- **If YES (Machine-Certifiable)**:
  - It is **BANNED** from `## What to Review as a Human` (unless the check *could not be run* and is explicitly tagged in the item title as **`[Sim-to-Real / Ops Gap]` `[UNVERIFIED]`** or **`[BLOCKED]`**, with the attempted command and failure reason stated in the body).
  - The agent MUST verify it autonomously and record the verified fact in `## What Was Done` or `### How It Works`.
  - **Explicitly Banned Homework Patterns**:
    - Structural line-range or `file:line` inspection prompts (*"Review/Inspect/Check/Verify `<file>` lines X–Y..."*, *"Review `foo.py:42`..."*)
    - Mechanical inode/lock/race verification (*"`checkout_dev` / `checkout_inode`"*)
    - OS/runtime/shell compatibility mechanics (*"`time.monotonic()` epoch"*, *"Bash 3.2"*, *"BSD `sed`"*, *"`mapfile`"*, *"`declare -A`"*, *"`< /dev/null`"*, *"`sync_package_tree.sh --check`"*)

- **If NO (Human-Epistemic)**:
  - An LLM or test suite cannot certify it even with 100% line coverage and 3/3 LLM approvals, because correctness depends on **the owner's utility function / risk appetite**, **unobservable human mental state / external workflow**, **live production physics outside closed-world test fixtures**, or **human perceptual/aesthetic experience**.
  - It belongs in `## What to Review as a Human`.

### D2. The 4 Epistemic Categories Requiring Human Judgment

Every bullet in `## What to Review as a Human` must carry one of these four category tags in its title (selecting the **1 to 5 items** that actually apply to the change, or emitting `- None — no human-epistemic decisions; all changes are machine-certified in Section 1.` when zero human-epistemic tradeoffs exist):

1. **Category 1 — Policy, Value & Risk-Appetite Tradeoffs (`[Policy / Risk Tradeoff]`)**:
   - **What it covers**: Numeric thresholds, default modes, retention windows, admission floors, conservative vs. optimistic accounting, and fail-closed vs. fail-open policy choices where safety trades off against availability, convenience, or cost.
   - **Why an LLM cannot certify it**: A test proves the code enforces `threshold = X`; it cannot prove `X` matches the human owner's current tolerance for false positives vs. false negatives.
   - **Examples**:
     - Refusing new worktrees at `<10 GiB` free disk unless a released worktree idle `>=2h` can be recycled.
     - Charging a conservative upper-bound byte estimate (`_charge_estimate`) when a short-lived birth disappears before `du` can measure it (preventing unmeasured burst loops at the cost of potentially over-charging ephemeral directories).
     - Shipping `launchd` governor plist templates with `--act` enabled by default vs. observe-only.

2. **Category 2 — Unobservable Human Intent & External Workflow State (`[Human Workflow Intent]`)**:
   - **What it covers**: Assumptions about how the human works outside the repository's observable telemetry—editor buffers, terminal tabs without an active child `cwd`, branch-naming conventions, `/private/tmp` inspection habits, or cross-repo hook rollout timing.
   - **Why an LLM cannot certify it**: `lsof`, `ps`, and `git status` only see OS kernel and Git metadata; they cannot read the human's mind to know whether a clean, pushed, dead-PID worktree or vacated branch is still part of an active human investigation thread.
   - **Examples**:
     - Treating a worktree whose lease PID is dead or released for `>2h` (under `<10 GiB` pressure) as safe to quarantine or recycle when the human has no shell `cwd` or open file handle inside it.
     - Retaining a vacated branch ref when worktree-reuse recovery fails (preventing accidental branch deletion, at the cost of leaving an orphan branch name until pruned).
     - Decoupling external dotfile hook registration (`~/.claude/settings.json`, `~/.codex/hooks.json`) from the core `disk_magician` repository merge.

3. **Category 3 — Sim-to-Real / Closed-World Test Illusion (`[Sim-to-Real / Ops Gap]`)**:
   - **What it covers**: Production host behaviors that passing unit/shell suites in `/tmp` fixtures cannot prove—1 TB APFS filesystem contention under multi-agent load, APFS local snapshot space pinning, two-step deployment boundaries (`git merge` vs. `diskm deploy` + `launchd` reload), or multi-week pilot drift. Also covers any check explicitly tagged `[UNVERIFIED]` or `[BLOCKED]` in the item title.
   - **Why an LLM cannot certify it**: Isolated tests run in millisecond `/tmp` repositories with synthetic directory trees; they cannot experience real I/O stalls, `launchd` background throttling, or 14-day calibration drift on the live workstation.
   - **Examples**:
     - Actuator deadline timeouts (`actuator_deadline.sh`) when `du` or `lsof` runs against a loaded 1 TB APFS volume vs. fast `/tmp` test fixtures.
     - The operational cutover gap between merging PR #184 to `origin/main` and running `diskm deploy` (`tools/deploy_uv_tool.sh`) + `bash scripts/install_launchd_sweepers.sh`.

4. **Category 4 — Perceptual / UX / Aesthetic Judgment (`[Perceptual / UX]`, when UI/copy changes)**:
   - **What it covers**: Visual hierarchy, layout density, animation pacing, copy tone, and cognitive load across `1440x900` desktop, `700–1024px` narrow desktop, and `375x812` mobile viewports (linked via real screenshots/video timestamps).
   - **Why an LLM cannot certify it**: Playwright assertions verify element visibility and bounding-box non-overlap, but cannot judge whether a screen feels cluttered, confusing, or visually jarring to a human player/user.

### D3. Mandatory 3-Subbullet Schema & Deterministic Structural Validator Contract

Every numbered item in `## What to Review as a Human` MUST follow this exact structure:

```markdown
1. **`[Policy / Risk Tradeoff | Human Workflow Intent | Sim-to-Real / Ops Gap | Perceptual / UX]` Short Title of the Tradeoff or Operational Boundary**:
   - **Decision / Behavior at Stake**: Plain-English statement of what the system will now do in production and under what condition (understandable without opening any source file).
   - **Why an LLM / Test Suite Cannot Certify This**: The specific epistemic gap (value/risk tradeoff, unobservable human workflow habit, sim-to-real host behavior, or perceptual judgment) that unit tests and LLM code reviewers cannot resolve on your behalf.
   - **Human Judgment Needed & Override / Rollback Lever**: The concrete question to decide (`Is policy X acceptable, or should we tune it to Y?`), the symptom to watch for in production, and the exact verified CLI command (`diskm ...`), config key, or rollback command (in backticks) to change or disable it.
```

The deterministic structural validator (`/Users/jleechan/.claude/skills/human-review-brief/scripts/validate_human_review_brief.py`) enforces:
1. Presence of the `What to Review as a Human` section header.
2. Item count between `1` and `5` inclusive, OR `0` items when an explicit `None — no human-epistemic decisions; all changes are machine-certified in Section 1` declaration is present (with `items_region` bounded strictly before `- **What Current Evidence Does NOT Prove**`).
3. Presence of one of the 4 canonical `[Category Tag]` strings in every numbered item's title.
4. When `[UNVERIFIED]` or `[BLOCKED]` is used, it must appear in the item's title alongside `[Sim-to-Real / Ops Gap]`.
5. Absence of structural line-number homework references (`lines X-Y` or `file.ext:123`) unless the item title explicitly declares `[Sim-to-Real / Ops Gap]` + `[UNVERIFIED]`/`[BLOCKED]`. (Semantic judgment of mechanical vs. epistemic content remains in `SKILL.md` prose and LLM review `/cs` / `/advice` rather than brittle keyword blacklists.)
6. Presence of all 3 required subbullets (`Decision / Behavior at Stake`, `Why an LLM / Test Suite Cannot Certify This`, `Human Judgment Needed & Override / Rollback Lever`) within each item's bounded block, with at least one backticked command/config lever inside `Human Judgment Needed & Override / Rollback Lever`.
7. Presence of both mandatory closing bullets (`What Current Evidence Does NOT Prove` and `Exact Human Decision Needed`).

### D4. Reclassifying the 10 Legacy Blind-Spot Categories

To ensure zero loss of empirical safety while eliminating machine homework from `## What to Review as a Human`, `/Users/jleechan/.claude/skills/human-review-brief/SKILL.md` partitions the 10 categories into two tables:

| Legacy Category | New Home in `human-review-brief` | Rule |
|---|---|---|
| 2. Main-Merge Smuggling & Silent Reverts | **Section 1 (`## What Was Done` #3)** | Agent MUST run `git merge-tree` + `comm -23` and report clean/0 reverts in Section 1. Only appears in Section 2 if a conflict resolution made a semantic tradeoff. |
| 3. Partial, Stale-SHA, or Substitute-Provider Gates | **Section 1 (`## What Was Done` #4) + Section 2 (`What Current Evidence Does NOT Prove`)** | Agent discloses exact SHA/gate matrix in Section 1; any unverified/stale/substitute gate is escalated in `What Current Evidence Does NOT Prove` or tagged `[UNVERIFIED]`/`[BLOCKED]` in a Category 3 item title. |
| 5. ZFC & Mechanical Backend Guards (`dev`/`inode`, locks, reducers) | **Section 1 (`## What Was Done` #5) / `### How It Works`** | Mechanical correctness is certified by tests + `/cs` + `/advice`. Only the *policy consequence* enters Section 2 under Category 1 or 2. |
| 7. Provider-Boundary Schema Probing | **Section 1 (`## What Was Done` #5)** | Agent must live-probe or disclose as unexercised in `What Current Evidence Does NOT Prove`. |
| 8. Cross-Host (macOS vs Linux) & Python/Bash Parity | **Section 1 (`## What Was Done` #5)** | Agent must verify Bash 3.2 / BSD userland / Python epoch parity via tests. Never ask the human to check OS/interpreter quirks. |
| 9. Linux Systemd / Cgroup Live State | **Section 1 (`## What Was Done` #5)** | Agent must query live `systemctl show` / cgroup state; only surface in Section 2 if live host state is `[UNVERIFIED]`/`[BLOCKED]` in a Category 3 title. |
| 10. Delivery vs Execution, Subprocess Stdin & Hook Hygiene | **Section 1 (for stdin/hook mechanics) + Section 2 Category 3 (for merge-vs-live-deploy activation gap)** | Mechanical `< /dev/null` and hook timeouts belong in Section 1; operational cutover (merge vs. live deploy/pilot) belongs in Section 2 Category 3 with verified deploy/rollback commands. |
| 4. Product Constants, Cooldowns & Thresholds | **Section 2 — Category 1 (`[Policy / Risk Tradeoff]`)** | Framed as a value/risk tradeoff with a verified override lever, never as *"go read lines X–Y"*. |
| 6. Cross-PR Stack & Workflow Assumptions | **Section 2 — Category 2 (`[Human Workflow Intent]`)** | Framed around human workflow habits and merge/hook sequencing. |
| 1. Visual / UX Verification | **Section 2 — Category 4 (`[Perceptual / UX]`)** | Framed around human visual/perceptual judgment using linked viewport captures after mechanical layout checks pass. |

### D5. Concrete Application to PR #184 (`/Users/jleechan/roadmap/pr-summary-184-disk-governor.md`)

Applying D1–D4 to `/Users/jleechan/roadmap/pr-summary-184-disk-governor.md` (with every CLI lever verified against `/Users/jleechan/.worktrees/disk_magician/task11-receipt-accounting/disk_magician.sh`, `scripts/budget_controls.py`, `scripts/budget_status.py`, `scripts/quarantine_rename.py`, and `scripts/worktree_quarantine.py`):
1. The mechanical verifications previously placed in Section 4 (inode verification in `worktree_quarantine.py`, vacated-branch retention in `worktree_new.sh`, and `time.monotonic()` Python 3.9 vs 3.10+ epoch handling in `actuator_deadline.sh`) are moved into `## 3. What Was Done` bullet 5 (`Autonomous Mac + Linux Blind-Spot Pre-Flight Verification`).
2. Section 4 (`## 4. What to Review as a Human`) is rewritten around the **5 genuine, independently actionable human-epistemic items** for PR #184:
   - **Item 1 (`[Policy / Risk Tradeoff]` — Autonomous Non-Worktree Actuation (`--act` Enabled in Governor Launchd Template))**:
     - **Decision / Behavior at Stake**: Once deployed, the launchd governor (`com.jleechanorg.disk-magician-govern`) runs with `--act` enabled—automatically dispatching non-worktree cleanups (`/private/tmp`, caches, Colima, Codex document blobs) whenever a class exceeds budget and the `C14` self-test passes, rather than running in `--mode observe`.
     - **Why an LLM / Test Suite Cannot Certify This**: Tests prove that `--act` respects `C14` safety gates and never dispatches worktree deletion automatically, but an LLM cannot decide whether you want autonomous background cleanup active on day one of the 14-day pilot vs. skipping per-class budget actuation via `--mode observe`.
     - **Human Judgment Needed & Override / Rollback Lever**: Decide whether enabling autonomous non-worktree `--act` cleanup matches your risk appetite for the 14-day pilot. If you want to skip per-class budget actuation while keeping emergency pressure-sweep kickstart and quarantine reconciliation active, change `--act` to `--mode observe` in `launchd/com.jleechanorg.disk-magician-govern.plist.template` and re-run `bash scripts/install_launchd_sweepers.sh`; if you want to stop **all** governor tick actions completely (including pressure-sweep kickstart and quarantine reconciliation), unload the governor job via `launchctl bootout gui/$(id -u)/com.jleechanorg.disk-magician-govern`.
   - **Item 2 (`[Policy / Risk Tradeoff]` — Conservative Missing-Birth Charging & Low-Disk Admission Stage Thresholds)**:
     - **Decision / Behavior at Stake**: When a newly admitted worktree or scratch directory disappears or is replaced before its first `du` scan completes, `birth_audit.py` charges a conservative upper-bound estimate (`_charge_estimate`, using the class estimate or largest observed birth) rather than `0 bytes`, and low-disk admission gates new worktrees/scratch when free space drops below stage thresholds (`<10 GiB` Red, `<25 GiB` Orange).
     - **Why an LLM / Test Suite Cannot Certify This**: Tests prove conservative missing-birth charging prevents unmeasured burst loops from gaming the budget, but cannot decide your personal tradeoff between strict disk-floor protection and false-positive budget throttling during rapid ephemeral test bursts.
     - **Human Judgment Needed & Override / Rollback Lever**: Confirm that conservative missing-birth charging and the admission thresholds match your workflow priorities. Watch `diskm budget status` for `ALERT:burst_over_margin`; you can change the enforcement stage at runtime via `diskm budget set-stage observe` (or `warn` / `refuse_red` / `refuse_orange`), widen the burst margin via `diskm budget set-margin <gb>`, or promote recalibrated class estimates via `diskm budget promote-estimates` (note: `promote-estimates` also resets `budget.json`'s `pilot_start` timestamp and restarts the 14-day acceptance clock).
   - **Item 3 (`[Human Workflow Intent]` — Quarantine-First Staging & 2-Hour Released-Worktree Recycling vs. Unobservable Mental Context)**:
     - **Decision / Behavior at Stake**: Instead of deleting directly with `rm -rf`, eligible stale artifacts and worktrees are atomically renamed into recoverable `.dm-quarantine` staging before phase-2 purge. During low-disk admission (`<10 GiB` free), `worktree_new.sh` can recycle a clean, pushed worktree whose lease was explicitly released or whose owner PID died `>2 hours` ago (while routine `cleanup_worktrees.sh` retains the 3-day floor). If worktree-reuse recovery fails mid-flight, `worktree_new.sh` leaves the vacated branch ref intact rather than deleting it.
     - **Why an LLM / Test Suite Cannot Certify This**: Kernel probes (`lsof`, `ps`, `c14_probe.py`) and Git checks can prove no live process has a `cwd`, open file descriptor, active lease, or uncommitted/unpushed state in a worktree—but no machine can observe whether you still intend to inspect that dead-PID worktree or `/private/tmp` directory in an open editor tab or ongoing mental debugging thread.
     - **Human Judgment Needed & Override / Rollback Lever**: Confirm that a 2-hour post-release/dead-PID recycling window (only under `<10 GiB` free-space pressure) and quarantine-first staging fit your day-to-day debugging workflow. If any quarantined artifact or worktree is still needed, restore it via `diskm quarantine restore <id>` (or `diskm quarantine reconcile` for general artifacts) or `diskm worktree-quarantine restore <id>` (or `diskm worktree-quarantine reconcile` for worktrees).
   - **Item 4 (`[Sim-to-Real / Ops Gap]` — Live 1 TB APFS Contention vs. `/tmp` Fixtures & Two-Step Post-Merge Cutover)**:
     - **Decision / Behavior at Stake**: Merging PR #184 updates the repository source only; live production behavior on this Mac does not change until `bash ./disk_magician.sh deploy` (`tools/deploy_uv_tool.sh` inside a clean `origin/main` source checkout) is run and `bash scripts/install_launchd_sweepers.sh` loads `com.jleechanorg.disk-magician-govern` and `com.jleechanorg.disk-magician-govern-measure`. Once live, all 16 actuators execute under `actuator_deadline.sh` wall-clock deadlines and `disk_budget.py` defers daily class measurements (`exit 3`) when the snapshot lock is contended.
     - **Why an LLM / Test Suite Cannot Certify This**: All 669 Python tests and 132 shell test suites run against small, fast `/tmp` fixtures; they cannot prove that real-world `du -sk` and `lsof` scans across a 1 TB APFS volume under multi-agent load will not hit actuator deadlines or lock contention and carry forward stale class measurements during the 14-day pilot window.
     - **Human Judgment Needed & Override / Rollback Lever**: Confirm whether to proceed with live post-merge deployment (`bash ./disk_magician.sh deploy` from a clean `origin/main` source checkout + `bash scripts/install_launchd_sweepers.sh`) and begin the 14-day pilot. Monitor `diskm budget status`, `diskm budget status --weekly-check`, and `diskm budget status --pilot-check` over the first 48 hours; if live APFS latency causes repeated deadline timeouts, unload the governor jobs immediately via `launchctl bootout gui/$(id -u)/com.jleechanorg.disk-magician-govern` and `launchctl bootout gui/$(id -u)/com.jleechanorg.disk-magician-govern-measure`, or merge a revert PR for `<merge-sha>` to `origin/main` and re-run `bash ./disk_magician.sh deploy` from that clean `origin/main` checkout.
   - **Item 5 (`[Human Workflow Intent]` — Decoupled External Consumer Hook Rollout (`D6` Producers Outside This Repo))**:
     - **Decision / Behavior at Stake**: PR #184 ships the admission/lease libraries (`scripts/lib/admit_caller.sh`, `scripts/lib/worktree_lease.sh`) and `birth_audit.py` first-sighting accounting inside `disk_magician`, while leaving external producer hook registrations (`~/.claude/settings.json`, `~/.codex/hooks.json`, external CI runner wrappers) decoupled until after the `disk-magician` `uv tool` deploy is live. Until external hooks are registered, unhooked directory creations are caught and charged asynchronously by `birth_audit.py` on first sighting rather than pre-blocked at creation time.
     - **Why an LLM / Test Suite Cannot Certify This**: Tests in this repository verify that hooked callers (`worktree_new.sh`, `scratch_new.sh`, `ci_admit.sh`) and unhooked birth auditing work in isolation, but cannot decide when you want global Claude/Codex hooks in your personal dotfiles (`~/.claude/`, `~/.codex/`) switched over across concurrent agent sessions.
     - **Human Judgment Needed & Override / Rollback Lever**: Confirm you want to land and deploy `disk_magician` first (relying on `diskm birth-audit` first-sighting attribution for unhooked callers) before enabling global external consumer hooks, and check `diskm budget status --pilot-check` to see which external hook/deployment gates remain required before pilot sign-off (or inspect `~/.disk_magician_state/hook_bypass.jsonl` after external hooks are enabled).
   - **Closing Bullets**:
     - **`What Current Evidence Does NOT Prove`**
     - **`Exact Human Decision Needed`**

---

## 5. Assumptions and Recommended Defaults

| Question | Auto-picked answer | Rationale |
|---|---|---|
| Should `## What to Review as a Human` ever include `file:line` mechanical code checks? | **No — strictly banned when verified** | If a machine, test, or LLM reviewer can verify an invariant, offloading it to the human defeats autonomous verification (`Core Invariant #2`). Only checks explicitly tagged `[Sim-to-Real / Ops Gap]` + `[UNVERIFIED]`/`[BLOCKED]` in the item title may be escalated. |
| Where do the 10 empirical Mac + Linux blind-spot checks go if removed from human homework? | **Partitioned: mechanical checks move to Section 1 (`## What Was Done` pre-flight duties); policy/workflow/sim-to-real/UX checks map to the 4 Epistemic Categories in Section 2** | Preserves 100% of the empirical failure-mode checklist while stopping agents from disguising completed mechanical checks as human review items. |
| What structure should every bullet in `## What to Review as a Human` follow? | **Mandatory 3-subbullet schema + `[Category Tag]` + backticked CLI/config lever**: (1) `Decision / Behavior at Stake`, (2) `Why an LLM / Test Suite Cannot Certify This`, (3) `Human Judgment Needed & Override / Rollback Lever` | Directly answers the user's request (*"what to review as a human, why an LLM cannot easily certify its good, why human judgement needed"*) and guarantees verified, copy-pasteable CLI/config levers. |
| How many human review bullets should be emitted per PR? | **1 to 5 high-signal bullets, or 0 bullets with an explicit `None — no human-epistemic decisions; all changes are machine-certified in Section 1` declaration** (plus the 2 mandatory closing bullets: `What Current Evidence Does NOT Prove` and `Exact Human Decision Needed`) | Prevents review fatigue and avoids forcing padded filler on small mechanical or test-only PRs. |
| Where do skill projections live across CLIs? | **Canonical files in `~/.claude/skills/{human-review-brief,pr-summary}/SKILL.md` with existing projections in `~/.agents/skills/` (never add links under `~/.codex/skills/`)** | Honors the global policy that `~/.codex/skills/` is not a skill root while `~/.agents/skills/human-review-brief` and `~/.agents/skills/pr-summary` already point to `~/.claude/skills/`. |
| How should compliance with the new format be verified automatically? | **A deterministic structural Python validator (`validate_human_review_brief.py`) with unit tests (`test_validate_human_review_brief.py`)** | Enforces 1–5 items (or explicit 0-item line), `[Category Tag]` headers, structural line-reference detection, title-level `[Sim-to-Real / Ops Gap]` + `[UNVERIFIED]`/`[BLOCKED]` escalation, 3 subbullets bounded before closing bullets, backticked lever requirement, and closing bullets without brittle PR-specific identifier blacklists. |

---

## 6. Implementation Preconditions

1. **Isolation Invariant**: No files inside `/Users/jleechan/.worktrees/disk_magician/task11-receipt-accounting` may be modified during this task.
2. **Skill Root Policy**: Edit `/Users/jleechan/.claude/skills/human-review-brief/SKILL.md` and `/Users/jleechan/.claude/skills/pr-summary/SKILL.md` in place and verify existing `~/.agents/skills/` symlinks; do not create any files or symlinks under `~/.codex/skills/`.
3. **Verified Levers**: Every CLI command cited as an override or rollback lever in `/Users/jleechan/roadmap/pr-summary-184-disk-governor.md` must match an actual subcommand in `disk_magician.sh`, `scripts/budget_controls.py`, `scripts/budget_status.py`, `scripts/quarantine_rename.py`, or `scripts/worktree_quarantine.py`, and any `tools/deploy_uv_tool.sh` (`diskm deploy`) rollback must respect its clean `origin/main` guard.

---

## 7. Verification Strategy

1. **Deterministic Contract & Unit Tests (`test_validate_human_review_brief.py`)**:
   - Rejects the legacy PR #184 `What to Review as a Human` section.
   - Rejects rephrased mechanical homework (`Inspect scripts/foo.py:42`, `verify lines 40-55 handle Bash 3.2`) and items missing backticked CLI/config levers.
   - Allows items explicitly marked `[UNVERIFIED]` or `[BLOCKED]` under `[Sim-to-Real / Ops Gap]`.
   - Verifies both `/Users/jleechan/.claude/skills/human-review-brief/SKILL.md` and `/Users/jleechan/.claude/skills/pr-summary/SKILL.md` contain the required epistemic boundary clauses and that `~/.agents/skills/human-review-brief` resolves to `~/.claude/skills/human-review-brief`.
   - Validates `/Users/jleechan/roadmap/pr-summary-184-disk-governor.md` with exit code `0` (`OK`).
2. **Independent Multi-Reviewer Validation (`/advice` + `/dot`)**:
   - Run `/advice` document-review mode (`run_primary_pair.py --document ...`) on this spec and companion plan.
   - Query `/dot` (`scripts/dot.sh`) to critique and sharpen both the general epistemic boundary criteria and PR #184's rewritten human review section.

---

## 8. Risks & Mitigations

- **Risk 1 — Agents hide unverified mechanical checks to avoid the "No Machine Homework" ban**:
  - *Mitigation*: Both `SKILL.md` and `validate_human_review_brief.py` explicitly allow `[UNVERIFIED]` or `[BLOCKED]` escalations under Category 3 (`[Sim-to-Real / Ops Gap]`) and require listing unexercised surfaces in `What Current Evidence Does NOT Prove`.
- **Risk 2 — Agents invent non-existent CLI flags or rollback commands that fail deploy guards**:
  - *Mitigation*: `validate_human_review_brief.py` requires backticked levers in every item's third subbullet, and the skill requires verifying every cited CLI subcommand against the repo's dispatcher (`disk_magician.sh` / `--help`) and deploy guards before emitting the brief.
