//! Disk Magician migration candidate.

use std::{io, path::PathBuf};

/// Verify the local Scratch registry against the mounted filesystem.
#[cfg(any(target_os = "linux", target_os = "macos"))]
pub fn verified_scratch_volume(
    expected: Option<&std::path::Path>,
    for_reclaim: bool,
) -> io::Result<Option<PathBuf>> {
    #[cfg(target_os = "linux")]
    {
        let _ = for_reclaim;
        volume_linux::verified_root(expected)
    }
    #[cfg(target_os = "macos")]
    volume_macos::verified_root(expected, for_reclaim)
}

pub mod artifact_batch;
pub mod artifact_discovery;
pub mod evidence_holds;
pub mod history;
pub mod job_receipt;
pub mod preview;
pub mod preview_scopes;
pub mod reclaim_report;
pub mod scan;
pub mod scratch_dir;
mod scratch_file_transaction;
pub mod scratch_index;
pub mod scratch_lease;
pub mod scratch_manifest;
mod scratch_recovery;
pub mod scratch_sweep;
pub mod scratch_target;
pub mod snapshot;
pub mod state_commit;
pub mod state_publish;
pub mod status;
pub mod time_windows;
mod volume_config;

#[cfg(target_os = "linux")]
pub mod volume_linux;

#[cfg(any(target_os = "macos", test))]
mod volume_macos;
