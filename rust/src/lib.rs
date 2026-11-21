//! Read-only Disk Magician migration candidate.

// Temporary bridge to the installed package during parity testing.
pub(crate) const LEGACY_CLI: &str = "disk-magician";

pub mod history;
pub mod preview;
pub mod preview_scopes;
pub mod preview_worktrees;
pub mod scan;
pub mod scratch_manifest;
pub mod scratch_target;
pub mod status;
