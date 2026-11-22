# Disk Magician legacy removal implementation plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Ship one Rust Disk Magician runtime and delete replaced Python/Bash cleanup code and wiring.

**Architecture:** Extend exact native selection and target coordination, migrate remaining state and scheduled callers, then remove the compatibility modules and package entry points alongside their verified replacements.

**Tech Stack:** Rust, existing Disk Magician state formats, macOS APFS, Linux Scratch, launchd and systemd.

## Implementation Preconditions

Pin the active Rust baseline and reconcile overlapping cleanup changes before altering the same call paths. Use disposable registered Scratch fixtures for mutation tests. Live removal remains an explicit exact scope. Drain old scheduled writers before any installed writer switch and preserve existing recovery data.

## Current cleanup baseline

The operator’s November 22 six-hour inventory recorded 98,872 Scratch candidates
and 17,176 temp candidates across three roots. Zero were confirmed eligible.
Scratch had 98,852 verification-limit deferrals and 20 unavailable-verdict
deferrals. All temp candidates were deferred by the retired policy backend.
Use the saved candidate JSON as age input. Before any removal, qualify an exact
batch with native lease, identity, evidence, and active-use checks. Persist the
verified result separately from age observations. Deferred entries and coverage
gaps remain visible.

## Task 1 — Retire generic forwarding

Modify `rust/src/main.rs`, `rust/tests/cli_contract.rs`, and `rust/README.md`. Add `native_cli_rejects_unported_commands_without_launching_the_backend`. Run `cargo test --locked --manifest-path rust/Cargo.toml --test cli_contract` with the existing Scratch fixture environment. RED shows a missing Rust command starts the backend. Remove generic forwarding. GREEN shows native help and exit 2 for unsupported verbs with no backend calls. Existing named adapters remain testable. Commit the deletion.

## Task 2 — Replace the cleanup actuator and recover prior operations

Extend `rust/src/scratch_manifest.rs`, `rust/src/scratch_target.rs`, `rust/src/scratch_recovery.rs` and the existing `rust/tests/scratch_target_contract.rs`. Add fixtures with an old legacy directory, a newly changed child, active producer, known evidence hold and interrupted exact removal. Exercise at least two relative age values, an absolute cutoff, cutoff equality, and restart with the original cutoff. RED shows the old directory is unsupported or recovery cannot return an unambiguous final verdict. Run `cargo test --locked --manifest-path rust/Cargo.toml --test scratch_target_contract`. GREEN uses the actual Rust executable to remove only the selected eligible fixture, holds changed or live paths and recovers interruption. Inject interruption at durable intent, entry removal, parent sync and completion. Verify partial-tree restart, descendant holds, mount changes, symlink and ancestor replacement, and an overlapping producer claim. Exercise old quarantine restore through the retained compatibility reader. Verify macOS and Linux before removing the legacy apply caller and its now-unused code.

## Task 3 — Transfer scheduled operations and state

Modify `rust/src/main.rs`, lease and state modules, service definitions in `launchd/` and `systemd/`, and the install tooling in `tools/deploy_uv_tool.sh`. Add `rust/tests/retained_jobs_contract.rs` to launch Scratch, temp, reserve and snapshot jobs against isolated state. Run `cargo test --locked --manifest-path rust/Cargo.toml --test retained_jobs_contract`. RED shows missing verbs or incompatible receipts. GREEN proves the actual package exposes each retained command, uses matching ownership and floors, publishes a terminal receipt, and handles interrupted writers. Port helpers with verified live callers in separate commits. Explicitly remove obsolete schedules and their callers. Enumerate every shipped alias, scheduler, installer and helper caller and its Rust owner or retirement disposition. Test stale scheduler starts during handoff. Check rollback against the pinned package after draining the Rust writer and recover from migrated durable state before changing live jobs.

## Task 4 — Remove the legacy package

Update the installer, `pyproject.toml`, `setup.py`, and disk command documentation. After Tasks 2 and 3, verify retained callers and packages on both platforms. Run `cargo test --locked --manifest-path rust/Cargo.toml --all-targets` and the retained job suite with the Python/Bash package absent from the isolated test environment. Install the final distributable in clean Mac and Linux fixtures without legacy Disk Magician on PATH. The installed aliases must resolve to the same native build and all retained jobs must complete there. Delete the old dispatcher, compatibility adapters and package sources after the installed-contract RED/GREEN checks fail and then pass without the legacy runtime. Keep fixtures needed to read or restore older state.

## TDD Plan Check

Tasks 1–4 name behavior and exact failing and passing checks. Use the existing short Scratch fixture path, then record each test's RED and GREEN, run regressions, and commit at green. Documentation-only updates use command-transcript and link checks.
