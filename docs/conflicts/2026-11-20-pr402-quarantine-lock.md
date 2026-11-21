# Managed-run quarantine merge resolution for PR #402

Merged the approved quarantine source at `55e319bf91691ee52c30a4a6131bc0f6d9ae5aa6` into the deprecation branch at `20a1f9c83bed08a5543a603682fa010d7405e82f`.

## `scripts/quarantine_scratch_manifest.py`

- **Combined** the managed-run inventory cutoff and fingerprint checks with the canonical nonblocking writer launcher. The writer descriptor reaches the quarantine subprocess for both regular files and managed runs. The read-only check-entry, check-inventory and fingerprint modes remain available before writer acquisition.
- **Kept both** the exact selection rules and the current argument parser. A managed run passes both its content cutoff and the inherited writer descriptor to the actuator.

## Tests

- Before: The former #402 revision passed both hosted Rust jobs. The new parent independently passed 78 Rust and 11 quarantine integration tests.
- After: Linux passed all 87 Rust and 14 quarantine integration tests, formatting and Clippy. Package synchronization and version checks passed.
