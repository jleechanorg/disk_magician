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

`diskm-rust preview --state-dir DIR [--min-hours 6|48] [--max-candidates N] [--dry-run]`
reads the per-host `reclaim/directory-ledger.json` and checks recorded paths under
the registered Scratch volume. Results record the current C14 verdict from
`diskm quarantine verdict`. History supplies leads. The reported `eligible`
field means C14 returned `remove` at check time. Any lane or PR evidence holds
outside C14 still apply. The report covers known exact paths within its candidate
and deadline bounds. It does not inventory the volume or project physical savings.
