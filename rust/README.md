# Disk Magician Rust candidate

The standalone Cargo package builds the read-only `diskm-rust` candidate. Use the installed `diskm` for production jobs and cleanup.

From the repository root:

```bash
cargo build --locked --manifest-path rust/Cargo.toml
cargo test --locked --manifest-path rust/Cargo.toml
cargo fmt --manifest-path rust/Cargo.toml --check
cargo clippy --locked --manifest-path rust/Cargo.toml --all-targets -- -D warnings
```

The build goes to Cargo's target directory. Set `CARGO_TARGET_DIR` to a verified, leased Disk Magician build directory when working on an operator host. The scanner tests also require `DISKM_SCRATCH_TEST_DIR` to name an existing disposable directory, which CI sets to its runner temporary directory.

```text
diskm-rust status [PATH] [--state-dir DIR]
diskm-rust scan PATH [--deadline-ms N] [--max-entries N]
diskm-rust history --state-dir DIR [--days 7|30]
```

All reports are JSON. Status measures filesystem capacity without crawling. Its optional state directory is read for existing snapshot and ledger metadata. A scan returns apparent file sizes and an allocation estimate with explicit coverage gaps. It reports symlinks as leaves and marks filesystem boundaries as incomplete. The scan uses path-based metadata and directory reads. On a concurrently changing tree, the result is a best-effort observation and cannot be used to authorize mutation. The deadline is cooperative between filesystem calls, so a blocked filesystem call may run past it. Incomplete scans emit a report and exit 75. History reads compatible, complete committed records from the supplied state repository. The candidate accepts a conservative subset of legacy complete ledger records. It groups observations by recorded host and root path. That identity cannot distinguish remounts at the same path. A report without comparable records has no authoritative floor.

The candidate has no reclaim, lease, provisioning or scheduling operations. Before a default switch, compare retained commands on macOS and Linux, prove state transfer and safe apply on each in-use backend, and rehearse rollback with live leases and interrupted recovery. See the repository's legacy CLI and tests for current behavior.

### Scratch cleanup preview

`diskm-rust preview --state-dir DIR --min-hours 6 --dry-run` inventories the
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

The default 48-hour preview reads prior cleanup paths from the supplied state
directory. The separate six-hour scan does not alter that policy, run cleanup,
or change worktree retention.

### Other cleanup locations

Use `--scope tmp` to inventory canonical host temporary roots, including
`/private/tmp` on macOS. The requested age filters discovery. The separate
`diskm cleanup-tmp --dry-run` output applies the installed cleaner's policy.
Inventory rows remain unqualified until that policy can establish eligibility.

Use `--scope worktrees` to run the installed worktree dry run against its
standard roots, including `~/.worktrees`. Its eligible rows are preliminary.
The worktree cleaner applies its own retention policy and revalidates Git state,
ownership, and safety before removal.

Use `--scope ledger --state-dir DIR` to read known cleanup paths and patterns.
Ledger rows are historical leads. With `--scope all --state-dir DIR`, the JSON
includes the Scratch, temp, worktree, and ledger views. A failed view is reported
under its own scope.
