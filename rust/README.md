# Disk Magician Rust candidate

The standalone Cargo package builds the read-only `diskm-rust` candidate. Use the installed `diskm` for production jobs and cleanup.

From the repository root:

```bash
cargo build --locked --manifest-path rust/Cargo.toml
cargo test --locked --manifest-path rust/Cargo.toml
cargo fmt --manifest-path rust/Cargo.toml --check
cargo clippy --locked --manifest-path rust/Cargo.toml --all-targets -- -D warnings
```

The build goes to Cargo's target directory. Set `CARGO_TARGET_DIR` to a verified, leased Disk Magician build directory when working on an operator host.

```text
diskm-rust status [PATH] [--state-dir DIR]
diskm-rust scan PATH [--deadline-ms N] [--max-entries N]
diskm-rust history --state-dir DIR [--days 7|30]
```

All reports are JSON. Status measures filesystem capacity without crawling. Its optional state directory is read for existing snapshot and ledger metadata. A scan returns apparent file sizes and an allocation estimate with explicit coverage gaps. It stays on one filesystem and does not follow symlinks. The deadline is cooperative between filesystem calls, so a blocked filesystem call may run past it. Incomplete scans emit a report and exit 75. History reads compatible, complete committed records from the supplied state repository. An authoritative floor can be unavailable.

The candidate has no reclaim, lease, provisioning or scheduling operations. Before a default switch, compare retained commands on macOS and Linux, prove state transfer and safe apply on each in-use backend, and rehearse rollback with live leases and interrupted recovery. See the repository's legacy CLI and tests for current behavior.
