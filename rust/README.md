# Disk Magician Rust candidate

The standalone Cargo package builds a migration candidate named `diskm`. Run it by its build path. Preview and target apply use the installed legacy `disk-magician` executable by name. Keep the installed production entry points and jobs until parity and rollback are verified.

From the repository root:

```bash
cargo build --locked --manifest-path rust/Cargo.toml
cargo test --locked --manifest-path rust/Cargo.toml
cargo fmt --manifest-path rust/Cargo.toml --check
cargo clippy --locked --manifest-path rust/Cargo.toml --all-targets -- -D warnings
```

The build goes to Cargo's target directory. Set `CARGO_TARGET_DIR` to a verified, leased Disk Magician build directory when working on an operator host. The scanner tests also require `DISKM_SCRATCH_TEST_DIR` to name an existing disposable directory, which CI sets to its runner temporary directory.

```text
diskm status [PATH] [--state-dir DIR]
diskm scan PATH [--deadline-ms N] [--max-entries N]
diskm history --state-dir DIR [--days 7|30]
```

All reports are JSON. Status measures filesystem capacity without crawling. Its optional state directory is read for existing snapshot and ledger metadata. A scan returns apparent file sizes and an allocation estimate with explicit coverage gaps. It reports symlinks as leaves and marks filesystem boundaries as incomplete. The scan uses path-based metadata and directory reads. On a concurrently changing tree, the result is a best-effort observation and cannot be used to authorize mutation. The deadline is cooperative between filesystem calls, so a blocked filesystem call may run past it. Incomplete scans emit a report and exit 75. History reads compatible, complete committed records from the supplied state repository. The candidate accepts a conservative subset of legacy complete ledger records. It groups observations by recorded host and root path. That identity cannot distinguish remounts at the same path. A report without comparable records has no authoritative floor.

Target apply uses the legacy quarantine actuator. Native lease, provisioning, scheduled cleanup, and recovery parity remain migration work. Before a default switch, compare retained commands on macOS and Linux, prove state transfer and safe apply on each in-use backend, and rehearse rollback with live leases and interrupted recovery. See the repository's legacy CLI and tests for current behavior.

### Scratch cleanup preview

`diskm preview --state-dir DIR --min-hours 6 --dry-run` inventories the
registered Scratch filesystem without an entry or scan deadline cap. Old
regular files and complete artifact directories below 100 MiB are considered
independently of newer siblings. Larger trees are itemized. Historical paths
supply provenance, and live discovery works when the ledger is absent.

The report separates discovery coverage and its filesystem gaps from verdicts.
Each proposed path gets its own deadline with `diskm quarantine verdict`.
Live preview ranks candidates by allocated bytes, with path order as a tie-break.
The report retains both allocated and apparent sizes. These figures can count
shared blocks more than once and do not measure space a deletion will free.
The verdict pass checks 20 paths by default. Use `--max-candidates N` to change that count. The report still includes all discovered
candidates and marks unchecked paths deferred. Linked checkouts and bare Git
mirrors are excluded from six-hour verdicts. Only a current
C14 `remove` verdict is labeled eligible. Ownership and PR evidence holds
outside C14 still apply. Apparent sizes are file-summed and do not project
physical reclaim.

A ledger-only report marks filesystem coverage incomplete and names the
Scratch root in its discovery gaps.

The default 48-hour preview reads prior cleanup paths from the supplied state
directory. The separate six-hour scan does not alter that policy, run cleanup,
or change worktree retention.

For a bounded six-hour Scratch discovery, pass `--deadline-ms N`. This
cooperative deadline applies only to filesystem discovery. An expired scan still
returns its measured candidates with named gaps and incomplete coverage. Incomplete
directories are not proposed; each measured file or complete directory candidate
still receives the normal C14 verdict. Verdict checks run after scanning, up to
12 seconds per candidate, bounded separately by `--max-candidates`. Without
`--deadline-ms`, the six-hour scan remains unlimited.

### Other cleanup locations

Use `--scope tmp` to inventory canonical host temporary roots, including
`/private/tmp` on macOS. The requested age filters discovery. The separate
`diskm cleanup-tmp --dry-run --no-job-receipt` output applies the installed cleaner's policy.
Inventory rows remain unqualified until that policy can establish eligibility.

Use `--scope worktrees` to run the installed worktree dry run against its
standard roots, including `~/.worktrees`. Its eligible rows are preliminary.
The worktree cleaner applies its own retention policy and revalidates Git state,
ownership, and safety before removal.

Use `--scope ledger --state-dir DIR` to read known cleanup paths and patterns.
Ledger rows are historical leads. With `--scope all --state-dir DIR`, the JSON
includes the Scratch, temp, worktree, and ledger views. A failed view is reported
under its own scope.

### Exact-file Scratch manifest

Use the built candidate's `scratch-manifest --before-epoch SECONDS --path ABSOLUTE_FILE`
to turn selected regular files into an identity-bound JSON manifest. Repeat
`--path` or pass a NUL-terminated UTF-8 path list with `--paths-from FILE`.
The cutoff is exclusive. Outside paths, symlinks, nonregular entries, duplicate
paths and files at or after the cutoff are rejected. A manifest records selected
file identities and is read-only. The applying cleaner must recheck every entry
and evaluate live protection and cleanup policy before removing anything.

The compatibility apply route is `disk-magician quarantine scratch-apply
--manifest FILE --manifest-sha256 SHA --path RELATIVE_FILE`. Repeat
`--path` for an exact subset, or explicitly use `--all` for all rows in
the referenced digest. This first apply slice targets regular files in
existing Scratch. Managed dated runs are reclaimed as lease-backed units.
Files with path characters the canonical deletion log cannot represent
remain in place. Both staged executables are required until the Rust
quarantine and recovery port is complete.

### Checkpointed Scratch preview and target apply

Use `diskm preview --state-dir DIR --resume-state ABSOLUTE_FILE --deadline-ms N`
to scan Scratch against the default 48-hour age floor. Repeat the command
with the same checkpoint to process unfinished paths and deferred verdicts.
A prior remove verdict is retained as `historical:remove` until a fresh
check qualifies the path. Discovery and allocation figures describe a scan
pass. Allocated bytes estimate reclaim.

Use `diskm scratch-target-apply --manifest FILE --manifest-sha256 SHA
--resume-state FILE --target-used-bytes N` with an explicit initial
`--path RELATIVE_FILE` selection or `--all` for a reviewed manifest.
The resume file lives outside the Scratch volume. Repeat the same command
without selection flags to use its saved queue. The candidate measures the
verified mount before applying and after each completed entry. It saves
the remaining queue when usage reaches the target or measurement is unavailable.
An interrupted mutation reports `recovery_required` and leaves the in-flight
entry in the checkpoint. The existing legacy writer lock returns immediately
under contention.
