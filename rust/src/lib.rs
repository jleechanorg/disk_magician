//! Disk Magician migration candidate.

use std::env;
use std::io;
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::path::PathBuf;

// Temporary bridge to the installed package during parity testing.
const LEGACY_CLI: &str = "disk-magician";
pub const LEGACY_COMPAT_CLI: &str = "DISKM_LEGACY_COMPAT_CLI";

/// Resolve the same explicitly selected legacy backend for dispatcher and native subcommands.
pub fn legacy_cli() -> io::Result<PathBuf> {
    let Some(configured) = env::var_os(LEGACY_COMPAT_CLI) else {
        return Ok(PathBuf::from(LEGACY_CLI));
    };
    let candidate = PathBuf::from(configured);
    if !candidate.is_absolute() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "legacy compatibility path must be absolute",
        ));
    }
    let path = std::fs::canonicalize(candidate)?;
    let metadata = std::fs::metadata(&path)?;
    if !metadata.is_file() || metadata.permissions().mode() & 0o111 == 0 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "legacy compatibility backend is not executable",
        ));
    }
    let running = std::fs::metadata(env::current_exe()?)?;
    if metadata.dev() == running.dev() && metadata.ino() == running.ino() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "refusing self-recursive legacy backend",
        ));
    }
    Ok(path)
}

pub mod history;
pub mod preview;
pub mod preview_scopes;
pub mod preview_worktrees;
pub mod reclaim_report;
pub mod scan;
pub mod scratch_dir;
pub mod scratch_manifest;
mod scratch_recovery;
pub mod scratch_target;
pub mod status;

#[cfg(target_os = "linux")]
pub mod volume_linux;

#[cfg(any(target_os = "linux", target_os = "macos"))]
mod volume_config;

#[cfg(any(target_os = "macos", test))]
mod volume_macos;
