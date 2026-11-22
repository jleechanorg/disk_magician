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

The path file is NUL-delimited and contains exact absolute paths. Qualification
preserves input order and reports age, identity and coverage. Managed files can
receive an advisory `remove` verdict. Apply rechecks the lease, identity, active
use, evidence holds, and staging-root protection.

## Managed bundles and capacity snapshots

```bash
diskm scratch-new "$PWD" build-run --kind build
diskm scratch-lease /path/to/bundle
diskm scratch-finish /path/to/bundle completed
diskm scratch-temp-file "$PWD" temporary-log
diskm snapshot --path / --output capacity.json
```

The allocating owner finishes its bundle explicitly. Lease records store
the exact path, owner identity, allocation time and observed filesystem
times. Records are published atomically without application lock files.
The latest descendant modification time is available through the index.

The temp allocator creates a single leased file. Finish that file using the
same `scratch-finish` command after use. For an exact host-temp manifest, select
`--root system-tmp`. Scratch builds use the default root. Apply accepts the
manifest SHA-256 and a resume file outside the cleanup scope. Keep the resume
file with the manifest for interrupted-stage recovery.

## Leased runs

`diskm scratch-new <repo> <purpose> --kind build|evidence [--owner-pid PID]` allocates a leased run under `runs/`. Any process of the same user can later run `diskm scratch-finish "$OUT_DIR" completed` (or `abandoned`), so `OUT_DIR="$(diskm scratch-new ...)"` works even though that subshell exits at once. The cleaner removes files in a build run that is completed, abandoned, or never finished, once the recorded owner has exited. Each file still has to pass the 48-hour content floor and the open-file, live-directory, repository and PR-evidence checks. `--owner-pid` binds the run to a long-lived producer, and the run is kept while that process lives. Evidence runs and ad-hoc `scratch-dir` paths are never removed this way.

## Scheduled runs and installation

Install the built `diskm` as a single executable. The `disk-magician` alias
can be a symlink to it. Isolated installs on Mac and Linux verified both names
with no legacy cleaner on PATH. The launchd and systemd templates invoke the
native binary directly.

`diskm scratch-sweep` previews by default. An explicit `--clean` run uses
Scratch quota pressure or the selected system-temp age cutoff.
`diskm snapshot --path / --state-dir DIR` publishes a local capacity sample
and a terminal receipt. Capacity-only coverage is marked partial.

Before enabling the timers, verify the installed executable and confirm the
filesystem root protects its staging entries. The current Mac Scratch mount
is group-writable and returns `kept:unsafe-staging-root`. Installed timer
activation, automatic external evidence discovery, Git state publication and
older unmanaged cleanup remain pending.

See the [reimplementation plan](../docs/rust-reimplementation-plan.md) for
the remaining policy, recovery and deployment work.
