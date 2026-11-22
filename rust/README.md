# Disk Magician Rust CLI

Build the native `diskm` executable with the repository's locked dependencies
and the supported Rust toolchain:

```bash
cargo build --locked --manifest-path rust/Cargo.toml
cargo fmt --manifest-path rust/Cargo.toml --check
cargo clippy --locked --manifest-path rust/Cargo.toml -- -D warnings
```

The age index uses system SQLite. Keep build output on Scratch when testing on
an operator host. The commands below can run from the new build path in a
disposable test environment.

## Inventory and configurable age

```bash
diskm scratch-index refresh --root scratch
diskm scratch-search --root scratch --older-than 6h --limit 100
diskm scratch-index refresh --root system-tmp
diskm scratch-search --root system-tmp --older-than 12h --limit 100
```

The index stores exact paths, filesystem birth and modification timestamps,
and coverage. A directory's effective age includes descendant file and
directory changes. Search reads the published SQLite generation without
walking the root. Publication does not wait for a busy database. The cursor
preserves its original cutoff and generation.

```bash
diskm scratch-qualify --older-than 6h --paths-from candidates.nul --jobs 4
diskm scratch-manifest --before-epoch 1795300000 --path /path/to/selected/artifact
```

The path file is NUL-delimited and contains exact absolute Scratch paths.
Qualification preserves input order and reports age, identity and coverage.
Its positive age verdict remains policy-pending and carries no deletion
authority. Incomplete or inaccessible paths retain their hold reasons.
Scratch and temp previews use the native scanner. Temp removal policy and
worktree qualification are pending.

## Managed bundles and capacity snapshots

```bash
diskm scratch-new "$PWD" build-run --kind build
diskm scratch-lease /path/to/bundle
diskm scratch-finish /path/to/bundle completed
diskm snapshot --path / --output capacity.json
```

The allocating owner finishes its bundle explicitly. Lease records store
the exact path, owner identity, allocation time and observed filesystem
times. Records are published atomically without application lock files.
The latest descendant modification time is available through the index.

Snapshots report capacity and mark coverage partial. Whole-disk attribution,
snapshot publication and scheduled jobs remain separate work. The target
coordinator preserves exact selections and previous recovery state and
reports that the native mutation actuator is pending.

See the [reimplementation plan](../docs/rust-reimplementation-plan.md) for
the remaining policy, recovery and deployment work.
