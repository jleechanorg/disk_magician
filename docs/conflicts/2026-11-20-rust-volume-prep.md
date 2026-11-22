# Merge resolution for the native Scratch volume branch

Merged the protected-preview cutover stack at `20a1f9c83bed08a5543a603682fa010d7405e82f` into the native volume preparation branch at `6fed19e92c611e67dba8bb3c87649703366b3536`.

## `rust/README.md`

- **Kept both** the cutover stack's 48-hour ledger coverage and safety notes and the preparation branch's native mount verification instructions.

## Tests

- Before: The merged Rust apply suite failed six cases because its fixtures used a fake legacy backend through PATH without selecting compatibility mode. Standalone apply correctly attempted native measurement.
- After: All 91 Rust tests passed on Linux with an explicitly selected fixture backend. Formatting, Clippy and an Apple Silicon check passed. The production binary resolved the live Linux ext4 Scratch root for volume lookup, scratch-dir and an empty-ledger preview with no legacy binary on PATH. Verification rejected a different mount. No removal or service change ran.
