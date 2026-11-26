# Implementation plan: native observation and expired sweep
Design: ../specs/2026-11-26-native-observation-and-expired-sweep-design.md.

Use isolated source and operator-supplied sanitized receipts. Run Cargo from repository root with `--locked --manifest-path rust/Cargo.toml`. No host mutation.

## Task 1: Data capture and capacity history
1. Add `rust/tests/capacity_history.rs`: render/check the launchd Data argument; use a disposable Git state repo to prove explicit capacity history returns a minimum over comparable samples and does not silently turn partial snapshots into top-down results. Include wrong mount/host/source, legacy, old and repeated captures, a 180-capture 30-day window, and capacity-cap overflow; fixture scope independent of actual host state.
2. Run `cargo test --locked --manifest-path rust/Cargo.toml --test capacity_history` and see missing CLI behavior and wrong template, not a compile or toolchain error.
3. Implement in `rust/src/{snapshot,status,history,main}.rs` and the snapshot plist. Reuse the existing strict UTC parser, Git history budgets and snapshot publication filename.
4. Rerun the focused command and capacity/state publisher regressions. Inspect normalized Mac df values from operator evidence, then commit the green unit.

## Task 2: exact expired candidate and bounded exit
1. Extend `rust/tests/scratch_expired.rs` using temp fixtures and configurable hooks: prove path selection rejects a nested path, previews a new exact direct candidate, preserves protected exact candidates and unrelated intents, confirms an interrupted exact stage is replayed only by the next whole-root invocation, and commits only the selected candidate after the same hold checks. Prove a spent deadline is incomplete at sweep entry. Add a probe-count RED: a clean ordinary removal performs one examination before rename and one fresh examination for the original and staged names after rename, not two separate post-stage global listings. Extend `rust/tests/time_windows.rs` to assert systemd uses a larger outer timeout without lengthening the inner budget.
2. Run `cargo test --locked --manifest-path rust/Cargo.toml --test scratch_expired --test time_windows` and see expected contract failures.
3. Change `rust/src/{main,scratch_expired,scratch_file_transaction,time_windows}.rs` and the systemd service template only. Preserve native intent schema and every existing safety predicate; exact mode uses directory candidates, not arbitrary paths. Keep conservative Git census on selected repos. Add no blanket retries or safety latch.
4. Rerun the focused suites, including existing interruption, lease, open-path, alternate and evidence tests. Commit green unit.

## Task 3: operator handoff and integration
TDD N/A: documentation and evidence only. Update `rust/README.md` and applicable native playbook sections with the commands and exact scope distinctions. Verify `cargo fmt --manifest-path rust/Cargo.toml --check`, `cargo test --locked --manifest-path rust/Cargo.toml`, `cargo clippy --locked --manifest-path rust/Cargo.toml -- -D warnings`, native `--help`, and the repository LOC/evidence gates. Review immutable design and plan and binary behavior on Linux/Mac fixture runners. Report missing host access or accounts honestly. Open one draft after custody/head recheck, no merge or deployment. Real cumulative seven-/30-day coverage and scheduled sweep headroom require later operator-owned rollout and receipts.

## TDD Plan Check
Tasks 1 and 2 each have named fixture and implementation paths, a pre-change executable RED check with expected reason, minimal implementation, targeted/full GREEN and commit. Task 3 is documentation/evidence verification only. No host deployment is a test prerequisite. Full top-down producer and classified history remain explicit gaps, not acceptance claims.
