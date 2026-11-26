# Fast Scanner Redesign — Implementation Plan

**Date:** 2026-11-26
**Design Spec:** `~/roadmap/sq-fast-scanner-redesign-design-2026-11-26.md` (mirror: `docs/superpowers/specs/2026-11-26-fast-scanner-redesign-design.md`)
**Target Branch:** `feat/fast-scanner-redesign-20261126` (off `origin/main`)
**LOC Constraint:** Rust physical production LOC `<= 14,300` (baseline `14,201 / 14,300`, 99 lines headroom).

---

## Task Breakdown

### Task 1: Share macOS APFS volume-metadata skip helper and apply in `scan.rs`
- **Goal:** Eliminate the 5 permanent `readdirectory` gaps on `/Volumes/diskm-scratch` (`.DocumentRevisions-V100`, `.Spotlight-V100`, `.TemporaryItems`, `.Trashes`, `.fseventsd`) so `diskm scan` and `diskm scratch-index refresh` report `coverage_complete: true` on macOS.
- **Files:**
  - Test: `rust/tests/scan.rs` (add test asserting unreadable root-level APFS metadata directory is skipped cleanly on macOS without marking scan incomplete, while normal unreadable subdirectories still record `ScanGapKind::ReadDirectory` and `complete: false`).
  - Implementation: `rust/src/scan.rs` (expose `pub(crate) fn is_unreadable_macos_volume_metadata(path: &Path, name: &OsStr) -> bool`; skip matching root children in `scan_internal()` when `parent == 0`), `rust/src/scratch_expired.rs` (replace duplicate private helper with `crate::scan::is_unreadable_macos_volume_metadata`).
- **Commands:**
  - RED: `cargo test --manifest-path rust/Cargo.toml --test scan skips_unreadable_macos_volume_metadata` -> expected FAIL (`complete` is `false` and `gaps` contains `ReadDirectory` for `.Spotlight-V100`).
  - GREEN: `cargo test --manifest-path rust/Cargo.toml --test scan` -> expected PASS.

### Task 2: Bounded parallel candidate observation in `scratch_expired.rs::plan()`
- **Goal:** Cut `diskm scratch-expired` wall-clock scan time on Mac from ~80–120s toward ~20–30s by observing candidates in parallel using `std::thread::scope` + `AtomicUsize` (capped at `clamp(1, 8)` workers) while preserving exact deterministic ordering of `units`, `alts`, `stores`, and `blind`.
- **Files:**
  - Test: `rust/tests/scratch_expired.rs` (add test with multiple candidates including nested repos, alternates, fresh/stale dirs, and unreadable entries verifying deterministic sorted output and parity of `removals`, `kept`, `alts`, `stores`, and `blind`).
  - Implementation: `rust/src/scratch_expired.rs` (`plan()` uses `std::thread::scope` + `AtomicUsize` to run `observe()` in parallel across `items: Vec<(PathBuf, bool)>` and reassemble results in exact index order).
- **Commands:**
  - RED/Verification: `cargo test --manifest-path rust/Cargo.toml --test scratch_expired` (add deterministic multi-candidate parity + concurrency test first, verify behavior, then parallelize and re-run).
  - Benchmark: Time `diskm scratch-sweep --expired` (dry-run, `--clean` omitted) before vs after on `/Volumes/diskm-scratch`.

### Task 3: LOC budget, full Rust test suite, and Draft PR publication
- **Goal:** Verify Rust production LOC stays `<= 14,300`, all `cargo test` suites pass, and open a Draft PR with the `/sq` design spec, plan, and Phase 1 MVP code.
- **Files:**
  - `docs/superpowers/specs/2026-11-26-fast-scanner-redesign-design.md`
  - `docs/superpowers/plans/2026-11-26-fast-scanner-redesign-plan.md`
- **Commands:**
  - `node .github/scripts/check_loc_budget.js origin/main HEAD 14300 250`
  - `cargo test --manifest-path rust/Cargo.toml`
  - `gh pr create --draft ...`

### Task 4 (Deferred — Phase 2, Conditional on Operator Policy Approval)
- **Precondition:** Operator approves amending `GEMINI.md` to allow child-level expired sweeps inside declared shared umbrella containers (`tmp/`, `worldarchitect.ai/`, `mirrors/`) and retiring/raising `scratch_sweep.rs`'s 20-file pressure throttle.
- **Files:** `GEMINI.md`, `rust/src/scratch_expired.rs`, `rust/src/scratch_sweep.rs`, `rust/tests/scratch_expired.rs`.
- **Verification:** Failing test proving stale child under umbrella container is removed while fresh sibling is kept; `cargo test --manifest-path rust/Cargo.toml`.

### Task 5 (Deferred — Phase 3 & 4, Conditional on LOC Budget / Legacy Deletion)
- **Precondition:** Operator approves either raising the 14,300 Rust prod LOC cap or retiring legacy `scratch_sweep.rs` / `preview.rs` paths to fund native `diskm frontier` (`ledger/topdown-5g.json`, `disk_magician-5fba`) and compact directory-level `scratch-age.sqlite3`.
- **Files:** `rust/src/scan.rs`, `rust/src/scratch_index.rs`, `rust/src/frontier.rs` (new), `rust/src/main.rs`, `rust/tests/frontier.rs`.
- **Verification:** Failing test asserting `diskm frontier` output satisfies `history::qualifying_sample()` (`mode: "complete"`) and passes `diskm history --days 7`; `cargo test --manifest-path rust/Cargo.toml`.

---

## TDD Plan Check

- **Task 1 (`scan.rs` APFS metadata skip):** Behavior change. Sequence: add failing test `skips_unreadable_macos_volume_metadata` in `rust/tests/scan.rs` -> run `cargo test --manifest-path rust/Cargo.toml --test scan skips_unreadable_macos_volume_metadata` (verify RED: `complete == false` with `ReadDirectory` gap) -> implement shared `scan::is_unreadable_macos_volume_metadata` and root-level skip in `rust/src/scan.rs` + reuse in `rust/src/scratch_expired.rs` -> run `cargo test --manifest-path rust/Cargo.toml --test scan` and `--test scratch_expired` (verify GREEN) -> commit.
- **Task 2 (`scratch_expired.rs` parallel `observe()`):** Behavior-preserving performance refactor with concurrency invariants (deterministic order, no dropped gaps/alternates). Sequence: add multi-candidate determinism/parity test `parallel_plan_preserves_deterministic_order_and_alternates` in `rust/tests/scratch_expired.rs` -> run `cargo test --manifest-path rust/Cargo.toml --test scratch_expired` -> implement `std::thread::scope` parallel observation in `rust/src/scratch_expired.rs::plan()` -> re-run `cargo test --manifest-path rust/Cargo.toml --test scratch_expired` (verify GREEN) and measure wall-clock speedup on `/Volumes/diskm-scratch` -> commit.
- **Task 3 (Docs + LOC budget + Draft PR):** `TDD: N/A` — documentation mirroring, CI budget verification, and Draft PR creation do not alter runtime behavior. Verification: `node .github/scripts/check_loc_budget.js origin/main HEAD 14300 250` exits 0 and `cargo test --manifest-path rust/Cargo.toml` passes all tests.
- **Task 4 (Conditional Phase 2):** Behavior change, gated on operator policy approval precondition. Sequence: failing test for umbrella child removal + fresh sibling preservation -> minimal implementation -> `cargo test` GREEN -> commit.
- **Task 5 (Conditional Phase 3 & 4):** Behavior change, gated on LOC budget / legacy deletion precondition. Sequence: failing test for `frontier` output accepted by `history::qualifying_sample()` -> minimal implementation -> `cargo test` GREEN -> commit.
