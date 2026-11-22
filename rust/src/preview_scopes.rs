//! Read-only scope discovery for the cleanup preview.

use serde::{Deserialize, Serialize};
use std::collections::HashSet;
use std::fs;
use std::io;
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::process::Command;

const LEDGER_PATH: &str = "reclaim/directory-ledger.json";
const MAX_LEDGER_BYTES: u64 = 32 * 1024 * 1024;

#[derive(Clone, Debug, Serialize, Eq, PartialEq)]
#[serde(rename_all = "snake_case")]
pub enum RootSource {
    PrivateTmp,
    Tmp,
    UserTmp,
    AgentCacheScratch,
}

#[derive(Clone, Debug, Serialize, Eq, PartialEq)]
pub struct RootScope {
    pub path: PathBuf,
    pub source: RootSource,
}

#[derive(Clone, Debug, Serialize, Eq, PartialEq)]
pub struct HostTempScopes {
    pub roots: Vec<RootScope>,
    pub scratch_scope_availability: TempScopeAvailability,
}

#[derive(Clone, Debug, Serialize, Eq, PartialEq)]
#[serde(rename_all = "snake_case")]
pub enum TempScopeAvailability {
    RegisteredScratchExcluded,
    ScratchNotConfigured,
}

#[derive(Clone, Debug, Deserialize, Serialize, Eq, PartialEq)]
pub struct LedgerPathHint {
    pub row_type: String,
    pub canonical_path: Option<PathBuf>,
}

#[derive(Clone, Debug, Deserialize, Serialize, Eq, PartialEq)]
pub struct LedgerSummary {
    pub rows: Vec<LedgerPathHint>,
}

/// Resolve the same host temp locations that the canonical tmp sweeper uses.
/// All returned paths are canonical and unique. Roots sharing Scratch's device
/// are omitted because this list is specifically for host temp observations.
pub fn resolve_host_temp_scopes() -> io::Result<HostTempScopes> {
    let (scratch_device, scratch_scope_availability) =
        match crate::verified_scratch_volume(None, false)? {
            Some(root) => (
                Some(fs::metadata(root)?.dev()),
                TempScopeAvailability::RegisteredScratchExcluded,
            ),
            None => (None, TempScopeAvailability::ScratchNotConfigured),
        };

    let mut candidates = Vec::new();
    if let Some(root) = private_tmp_root() {
        candidates.push(RootScope {
            path: root,
            source: RootSource::PrivateTmp,
        });
    }
    let tmp_root = std::env::var_os("DISK_MAGICIAN_TMP_ROOT_OVERRIDE")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/tmp"));
    if let Some(root) = existing_canonical(&tmp_root) {
        candidates.push(RootScope {
            path: root,
            source: RootSource::Tmp,
        });
    }
    if cfg!(target_os = "macos") {
        if let Some(root) = user_temp_root()? {
            candidates.push(RootScope {
                path: root,
                source: RootSource::UserTmp,
            });
        }
    }
    let agent_cache = std::env::var_os("DISK_MAGICIAN_AGENT_CACHE_SCRATCH_OVERRIDE")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            PathBuf::from(std::env::var_os("HOME").unwrap_or_default())
                .join(".hermes/cache/scratch")
        });
    if let Some(root) = existing_canonical(&agent_cache) {
        candidates.push(RootScope {
            path: root,
            source: RootSource::AgentCacheScratch,
        });
    }
    canonical_temp_scopes(candidates, scratch_device).map(|roots| HostTempScopes {
        roots,
        scratch_scope_availability,
    })
}

fn private_tmp_root() -> Option<PathBuf> {
    if let Some(root) = std::env::var_os("DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE") {
        return existing_canonical(&PathBuf::from(root));
    }
    let candidates = std::env::var_os("DISK_MAGICIAN_PRIVATE_TMP_CANDIDATES")
        .unwrap_or_else(|| "/private/tmp:/tmp".into());
    std::env::split_paths(&candidates).find_map(|candidate| existing_canonical(&candidate))
}

fn user_temp_root() -> io::Result<Option<PathBuf>> {
    if let Some(root) = std::env::var_os("DISK_MAGICIAN_DARWIN_USER_TEMP_DIR_OVERRIDE") {
        return Ok(existing_canonical(&PathBuf::from(root)));
    }
    let output = Command::new("getconf")
        .arg("DARWIN_USER_TEMP_DIR")
        .output()?;
    if !output.status.success() {
        return Ok(None);
    }
    let root = String::from_utf8(output.stdout).map_err(io::Error::other)?;
    Ok(existing_canonical(Path::new(root.trim())))
}

fn existing_canonical(path: &Path) -> Option<PathBuf> {
    if !path.is_absolute() || path == Path::new("/") || !path.is_dir() {
        return None;
    }
    fs::canonicalize(path).ok().filter(|path| path.is_dir())
}

pub fn canonical_temp_scopes(
    candidates: Vec<RootScope>,
    scratch_device: Option<u64>,
) -> io::Result<Vec<RootScope>> {
    let mut seen_paths = HashSet::new();
    let mut roots = Vec::new();
    for candidate in candidates {
        let Some(path) = existing_canonical(&candidate.path) else {
            continue;
        };
        let metadata = fs::metadata(&path)?;
        if scratch_device.is_some_and(|device| metadata.dev() == device)
            || !seen_paths.insert(path.clone())
        {
            continue;
        }
        roots.push(RootScope {
            path,
            source: candidate.source,
        });
    }
    Ok(roots)
}

pub fn read_ledger(state_dir: &Path) -> io::Result<LedgerSummary> {
    let path = state_dir.join(LEDGER_PATH);
    let bytes = crate::job_receipt::read_bounded(&path, MAX_LEDGER_BYTES)?;
    let ledger: LedgerSummary = serde_json::from_slice(&bytes).map_err(io::Error::other)?;
    Ok(LedgerSummary {
        rows: ledger
            .rows
            .into_iter()
            .filter(|row| {
                matches!(
                    row.row_type.as_str(),
                    "cleanup_event" | "cleanup_root" | "pattern"
                )
            })
            .collect(),
    })
}
