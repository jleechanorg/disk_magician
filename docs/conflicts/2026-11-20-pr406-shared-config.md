# Shared configuration merge resolution for PR #406

Merged the approved deprecation source at `cee866aca1e1a99b147d5d9da86f37974d18c4ed` into the native volume branch at `aaf3ad6feffc483b6b19edc9ed08afd3ed848a86`.

## `rust/src/lib.rs`

- **Combined** the shared configuration module declaration with the platform-specific volume declarations. The public native volume API and the reclaim reader now load the same configuration module.
- **Kept both** the native volume implementation and the audited quarantine bridge. Git diff confirms that the three reviewed volume modules match the previous #406 revision and the quarantine source and tests match the approved #402 revision.

## Tests

- Before: The previous #406 revision passed hosted Rust on both platforms and six read-only APFS checks. The new parent passed its native ledger parity and quarantine fixtures.
- After: All 98 Rust tests passed on the Linux mirror. Formatting and Clippy passed on Linux and for the Apple Silicon target.
