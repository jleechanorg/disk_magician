//! Read-only scope discovery for the cleanup preview.

use serde::{Deserialize, Serialize};
use std::collections::HashSet;
use std::fs::{self, File};
use std::io::{self, Read};
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::process::Command;

const LEDGER_PATH: &str = "reclaim/directory-ledger.json";
const MAX_LEDGER_BYTES: u64 = 32 * 1024 * 1024;
const POLICY_TIMEOUT_SECONDS: u64 = 30;
const MAX_POLICY_OUTPUT_BYTES: usize = 256 * 1024;

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

#[derive(Clone, Debug, Serialize, Eq, PartialEq)]
pub struct LedgerSummary {
    pub rows: Vec<LedgerPathHint>,
}

#[derive(Clone, Debug, Serialize, Eq, PartialEq)]
pub struct TempPolicyPreview {
    pub command: Vec<String>,
    pub status: Option<i32>,
    pub timed_out: bool,
    pub truncated: bool,
    pub output: String,
    /// cleanup_tmp records an actuator job receipt even when run with --dry-run.
    pub may_write_job_receipt: bool,
    pub receipt_trigger: String,
}

#[derive(Deserialize)]
struct Ledger {
    rows: Vec<LedgerPathHint>,
}

/// Resolve the same host temp locations that the canonical tmp sweeper uses.
/// All returned paths are canonical and unique. Roots sharing Scratch's device
/// are omitted because this list is specifically for host temp observations.
pub fn resolve_host_temp_scopes() -> io::Result<HostTempScopes> {
    let scratch_path = Command::new(crate::legacy_cli()?)
        .args(["volume", "path", "scratch"])
        .output()?;
    let (scratch_device, scratch_scope_availability) = if scratch_path.status.success() {
        let scratch_path = String::from_utf8(scratch_path.stdout).map_err(io::Error::other)?;
        let scratch_root = PathBuf::from(scratch_path.trim());
        let scratch_root = fs::canonicalize(scratch_root)?;
        let scratch_metadata = fs::metadata(&scratch_root)?;
        if !scratch_metadata.is_dir() {
            return Err(io::Error::other(
                "registered Scratch volume is not a directory",
            ));
        }
        (
            Some(scratch_metadata.dev()),
            TempScopeAvailability::RegisteredScratchExcluded,
        )
    } else if scratch_path.status.code() == Some(3) {
        (None, TempScopeAvailability::ScratchNotConfigured)
    } else {
        return Err(io::Error::other(
            "registered Scratch identity is unavailable",
        ));
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
    let metadata = fs::symlink_metadata(&path)?;
    if !metadata.file_type().is_file() {
        return Err(io::Error::other("directory ledger is not a regular file"));
    }
    let mut bytes = Vec::new();
    File::open(path)?
        .take(MAX_LEDGER_BYTES + 1)
        .read_to_end(&mut bytes)?;
    if bytes.len() as u64 > MAX_LEDGER_BYTES {
        return Err(io::Error::other("directory ledger exceeds the read limit"));
    }
    let ledger: Ledger = serde_json::from_slice(&bytes).map_err(io::Error::other)?;
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

/// Ask the canonical temp cleaner for its default dry-run selection. The cleaner writes a run receipt, which is flagged in the result.
pub fn temp_policy_preview() -> io::Result<TempPolicyPreview> {
    temp_policy_preview_command(&crate::legacy_cli()?)
}

pub fn temp_policy_preview_command(executable: &Path) -> io::Result<TempPolicyPreview> {
    const PYTHON: &str = r#"
import json, os, signal, subprocess, sys
timeout = int(sys.argv[1])
limit = int(sys.argv[2])
proc = subprocess.Popen(sys.argv[3:], stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                        start_new_session=True, env={**os.environ, 'DISK_MAGICIAN_AGE_FLOOR_MINUTES': ''})
try:
    output, _ = proc.communicate(timeout=timeout)
    timed_out = False
except subprocess.TimeoutExpired:
    try:
        os.killpg(proc.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    output, _ = proc.communicate()
    timed_out = True
print(json.dumps({
    'status': proc.returncode,
    'timed_out': timed_out,
    'truncated': len(output) > limit,
    'output': output[:limit].decode('utf-8', 'replace'),
}))
"#;
    let executable_name = executable.as_os_str().to_string_lossy().into_owned();
    let args = vec![
        executable_name.clone(),
        "cleanup-tmp".to_owned(),
        "--dry-run".to_owned(),
    ];
    let output = Command::new("python3")
        .arg("-c")
        .arg(PYTHON)
        .arg(POLICY_TIMEOUT_SECONDS.to_string())
        .arg(MAX_POLICY_OUTPUT_BYTES.to_string())
        .args(&args)
        .env_remove("DISK_MAGICIAN_AGE_FLOOR_MINUTES")
        .env("DISK_MAGICIAN_RECEIPT_TRIGGER", "rust-preview")
        .output()?;
    if !output.status.success() {
        return Err(io::Error::other(
            String::from_utf8_lossy(&output.stderr).trim().to_owned(),
        ));
    }
    let response: BoundedCommandOutput =
        serde_json::from_slice(&output.stdout).map_err(io::Error::other)?;
    Ok(TempPolicyPreview {
        command: args,
        status: response.status,
        timed_out: response.timed_out,
        truncated: response.truncated,
        output: response.output,
        may_write_job_receipt: true,
        receipt_trigger: "rust-preview".to_owned(),
    })
}

#[derive(Deserialize)]
struct BoundedCommandOutput {
    status: Option<i32>,
    timed_out: bool,
    truncated: bool,
    output: String,
}
