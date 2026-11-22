use crate::preview::{possible_dated_run, registered_scratch};
use crate::scan::{self, ScanOptions};
use serde::Serialize;
use std::collections::BTreeSet;
use std::fs::{self, Metadata};
use std::io;
use std::os::unix::fs::MetadataExt;
use std::path::{Component, Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::mpsc;
use std::time::Duration;

const NANOS_PER_SECOND: i64 = 1_000_000_000;

#[derive(Serialize)]
pub struct Manifest {
    version: u8,
    root: RootIdentity,
    before_epoch_seconds: i64,
    entries: Vec<Entry>,
}

#[derive(Serialize)]
struct RootIdentity {
    path: PathBuf,
    dev: u64,
    ino: u64,
}

#[derive(Serialize)]
struct Entry {
    path: PathBuf,
    kind: String,
    dev: u64,
    ino: u64,
    size: u64,
    mtime_ns: i64,
    ctime_ns: i64,
}

#[derive(Clone, Debug, Serialize)]
pub struct QualificationReport {
    pub root: Option<PathBuf>,
    pub roots: Vec<PathBuf>,
    pub cutoff_epoch_seconds: i64,
    pub cutoff_source: &'static str,
    pub complete: bool,
    pub entries: Vec<Qualification>,
}

#[derive(Clone, Debug, Serialize)]
pub struct Qualification {
    pub path: PathBuf,
    pub kind: String,
    pub created_epoch_nanos: Option<i64>,
    pub modified_epoch_nanos: Option<i64>,
    pub changed_epoch_nanos: Option<i64>,
    pub effective_modified_epoch_nanos: Option<i64>,
    pub cutoff_epoch_seconds: i64,
    pub allocated_bytes: Option<u64>,
    pub apparent_bytes: Option<u64>,
    pub device: Option<u64>,
    pub inode: Option<u64>,
    pub coverage_complete: bool,
    pub verdict: String,
    pub deletion_authority: &'static str,
}

fn timestamp_ns(seconds: i64, nanos: i64) -> io::Result<i64> {
    seconds
        .checked_mul(NANOS_PER_SECOND)
        .and_then(|n| n.checked_add(nanos))
        .ok_or_else(|| io::Error::other("filesystem timestamp is out of range"))
}

fn epoch_nanos(seconds: i64, nanoseconds: i64) -> Option<i64> {
    seconds
        .checked_mul(NANOS_PER_SECOND)?
        .checked_add(nanoseconds)
}

fn creation_epoch_nanos(metadata: &Metadata) -> Option<i64> {
    let duration = metadata
        .created()
        .ok()?
        .duration_since(std::time::UNIX_EPOCH)
        .ok()?;
    i64::try_from(duration.as_nanos()).ok()
}

pub(crate) fn age_measurement(
    root: &Path,
    path: &Path,
    device: u64,
    cutoff_epoch_seconds: i64,
    scan_options: ScanOptions,
) -> Qualification {
    let base = || Qualification {
        path: path.to_path_buf(),
        kind: "unknown".into(),
        created_epoch_nanos: None,
        modified_epoch_nanos: None,
        changed_epoch_nanos: None,
        effective_modified_epoch_nanos: None,
        cutoff_epoch_seconds,
        allocated_bytes: None,
        apparent_bytes: None,
        device: None,
        inode: None,
        coverage_complete: false,
        verdict: "deferred:unmeasured".into(),
        deletion_authority: "none",
    };
    let mut result = base();
    let relative = match path.strip_prefix(root) {
        Ok(relative) => relative,
        Err(_) => {
            result.verdict = "kept:outside-registered-scratch".into();
            return result;
        }
    };
    let mut components = relative.components().peekable();
    if components.peek().is_none()
        || !components
            .clone()
            .all(|component| matches!(component, Component::Normal(_)))
    {
        result.verdict = "kept:invalid-scope".into();
        return result;
    }
    let mut current = root.to_path_buf();
    for component in components {
        current.push(component.as_os_str());
        match fs::symlink_metadata(&current) {
            Ok(metadata) if metadata.file_type().is_symlink() => {
                result.verdict = "kept:symlink".into();
                return result;
            }
            Ok(metadata) if metadata.dev() != device => {
                result.verdict = "kept:filesystem-boundary".into();
                return result;
            }
            Ok(metadata) if !metadata.is_file() && !metadata.is_dir() => {
                result.verdict = "kept:unsupported-path".into();
                return result;
            }
            Ok(_) => {}
            Err(error) if error.kind() == io::ErrorKind::NotFound => {
                result.verdict = "kept:missing".into();
                return result;
            }
            Err(_) => {
                result.verdict = "deferred:metadata".into();
                return result;
            }
        }
    }
    let relative_components: Vec<_> = relative.components().collect();
    let first = relative_components[0].as_os_str();
    if first.as_encoded_bytes().starts_with(b".")
        || first == ".diskm-ballast"
        || relative_components
            .iter()
            .any(|part| part.as_os_str() == "evidence")
    {
        result.verdict = "kept:protected-scratch-scope".into();
        return result;
    }
    let Ok(before) = fs::symlink_metadata(path) else {
        result.verdict = "deferred:metadata".into();
        return result;
    };
    let cutoff_ns = match epoch_nanos(cutoff_epoch_seconds, 0) {
        Some(cutoff) => cutoff,
        None => {
            result.verdict = "deferred:cutoff-out-of-range".into();
            return result;
        }
    };
    let measurement = if before.is_dir() {
        let (report, inventory) = match scan::scan_with_age_inventory(path, scan_options) {
            Ok(result) => result,
            Err(_) => {
                result.verdict = "deferred:tree-scan".into();
                return result;
            }
        };
        let path_bytes = path.as_os_str().as_encoded_bytes();
        inventory
            .entries
            .into_iter()
            .find(|entry| entry.path_bytes == path_bytes)
            .filter(|entry| report.complete && inventory.complete && entry.complete)
    } else {
        let modified_ns = epoch_nanos(before.mtime(), before.mtime_nsec());
        let created_ns = creation_epoch_nanos(&before);
        #[cfg(unix)]
        use std::os::unix::fs::MetadataExt;
        #[cfg(unix)]
        let (entry_device, inode, allocated_bytes) = (
            before.dev(),
            before.ino(),
            before.blocks().saturating_mul(512),
        );
        #[cfg(not(unix))]
        let (entry_device, inode, allocated_bytes) = (device, before.len(), before.len());
        let mut record = result.clone();
        record.kind = "regular_file".into();
        record.created_epoch_nanos = created_ns;
        record.modified_epoch_nanos = modified_ns;
        record.changed_epoch_nanos = epoch_nanos(before.ctime(), before.ctime_nsec());
        record.effective_modified_epoch_nanos = modified_ns;
        record.allocated_bytes = Some(allocated_bytes);
        record.apparent_bytes = Some(before.len());
        record.device = Some(entry_device);
        record.inode = Some(inode);
        record.coverage_complete = true;
        record.verdict = if modified_ns.is_some_and(|mtime| mtime < cutoff_ns) {
            "age_qualified_policy_pending".into()
        } else {
            "kept:recent-activity".into()
        };
        record.deletion_authority = "none";
        match fs::symlink_metadata(path) {
            Ok(after)
                if (
                    before.dev(),
                    before.ino(),
                    before.mtime(),
                    before.mtime_nsec(),
                    before.ctime(),
                    before.ctime_nsec(),
                ) == (
                    after.dev(),
                    after.ino(),
                    after.mtime(),
                    after.mtime_nsec(),
                    after.ctime(),
                    after.ctime_nsec(),
                ) => {}
            _ => {
                record.coverage_complete = false;
                record.verdict = "deferred:identity".into();
            }
        }
        return record;
    };
    let Some(measurement) = measurement else {
        result.verdict = "deferred:coverage-incomplete".into();
        return result;
    };
    let Ok(after) = fs::symlink_metadata(path) else {
        result.verdict = "deferred:identity".into();
        return result;
    };
    #[cfg(unix)]
    if (
        before.dev(),
        before.ino(),
        before.mtime(),
        before.mtime_nsec(),
        before.ctime(),
        before.ctime_nsec(),
    ) != (
        after.dev(),
        after.ino(),
        after.mtime(),
        after.mtime_nsec(),
        after.ctime(),
        after.ctime_nsec(),
    ) {
        result.verdict = "deferred:identity".into();
        return result;
    }
    result.kind = "directory".into();
    result.created_epoch_nanos = measurement.created_epoch_nanos;
    result.modified_epoch_nanos = measurement.modified_epoch_nanos;
    result.changed_epoch_nanos = measurement.changed_epoch_nanos;
    result.effective_modified_epoch_nanos = measurement.effective_modified_epoch_nanos;
    result.allocated_bytes = Some(measurement.allocated_bytes);
    result.apparent_bytes = Some(measurement.apparent_bytes);
    result.device = Some(measurement.device);
    result.inode = Some(measurement.inode);
    result.coverage_complete = measurement.complete;
    result.verdict = if measurement
        .effective_modified_epoch_nanos
        .is_some_and(|modified| modified < cutoff_ns)
    {
        "age_qualified_policy_pending".into()
    } else {
        "kept:recent-activity".into()
    };
    result.deletion_authority = "none";
    result
}

/// Inspect each exact Scratch path in parallel. Results preserve input order.
/// Eligibility is advisory. Apply independently rechecks policy and identity.
pub fn qualify_exact(
    paths: &[PathBuf],
    cutoff_epoch_seconds: i64,
    scan_options: ScanOptions,
    jobs: usize,
) -> io::Result<QualificationReport> {
    let (root, _) = registered_scratch()?;
    qualify_under_roots(
        paths,
        cutoff_epoch_seconds,
        scan_options,
        jobs,
        vec![root.clone()],
        Some(root),
    )
}

pub fn qualify_host_temp(
    paths: &[PathBuf],
    cutoff_epoch_seconds: i64,
    scan_options: ScanOptions,
    jobs: usize,
) -> io::Result<QualificationReport> {
    let scopes = crate::preview_scopes::resolve_host_temp_scopes()?;
    let roots = scopes.roots.into_iter().map(|scope| scope.path).collect();
    qualify_under_roots(
        paths,
        cutoff_epoch_seconds,
        scan_options,
        jobs,
        roots,
        Some(crate::scratch_lease::temp_path()?),
    )
}

fn qualify_under_roots(
    paths: &[PathBuf],
    cutoff_epoch_seconds: i64,
    scan_options: ScanOptions,
    jobs: usize,
    roots: Vec<PathBuf>,
    policy_root: Option<PathBuf>,
) -> io::Result<QualificationReport> {
    if paths.is_empty() || jobs == 0 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "qualification needs paths and a positive worker count",
        ));
    }
    if roots.is_empty() {
        return Err(io::Error::other("no verified qualification roots"));
    }
    let identities = roots
        .iter()
        .map(|root| {
            let metadata = fs::symlink_metadata(root)?;
            if !metadata.is_dir() {
                return Err(io::Error::other("qualification root changed"));
            }
            Ok((root, metadata.dev(), metadata.ino()))
        })
        .collect::<io::Result<Vec<_>>>()?;
    #[cfg(target_os = "macos")]
    let path_alias = identities
        .iter()
        .any(|(path, _, _)| path.as_path() == Path::new("/private/tmp"))
        && fs::canonicalize("/tmp").is_ok_and(|path| path == Path::new("/private/tmp"));
    let next = AtomicUsize::new(0);
    let (sender, receiver) = mpsc::channel();
    let worker_count = jobs.min(paths.len());
    std::thread::scope(|scope| {
        for _ in 0..worker_count {
            let next = &next;
            let sender = sender.clone();
            let identities = &identities;
            let policy_root = &policy_root;
            scope.spawn(move || loop {
                let index = next.fetch_add(1, Ordering::Relaxed);
                let Some(path) = paths.get(index) else {
                    break;
                };
                #[cfg(target_os = "macos")]
                let aliased = path_alias
                    .then(|| path.strip_prefix("/tmp").ok())
                    .flatten()
                    .map(|relative| Path::new("/private/tmp").join(relative));
                #[cfg(target_os = "macos")]
                let path = aliased.as_ref().unwrap_or(path);
                let (root, device, _) = identities
                    .iter()
                    .filter(|(root, _, _)| path.starts_with(root))
                    .max_by_key(|(root, _, _)| root.components().count())
                    .unwrap_or(&identities[0]);
                let mut qualification =
                    age_measurement(root, path, *device, cutoff_epoch_seconds, scan_options);
                if policy_root.as_ref() == Some(*root)
                    && qualification.verdict == "age_qualified_policy_pending"
                {
                    qualification.verdict = if qualification.kind == "regular_file" {
                        crate::preview::managed_file_verdict(
                            root,
                            path,
                            *device,
                            cutoff_epoch_seconds,
                        )
                    } else {
                        "kept:native-file-only"
                    }
                    .into();
                }
                if sender.send((index, qualification)).is_err() {
                    break;
                }
            });
        }
    });
    drop(sender);
    for (root, device, inode) in identities {
        let after = fs::symlink_metadata(root)?;
        if !after.is_dir() || (device, inode) != (after.dev(), after.ino()) {
            return Err(io::Error::other("qualification root identity changed"));
        }
    }
    let mut slots: Vec<Option<Qualification>> = (0..paths.len()).map(|_| None).collect();
    for (index, entry) in receiver {
        slots[index] = Some(entry);
    }
    let entries = slots
        .into_iter()
        .collect::<Option<Vec<_>>>()
        .ok_or_else(|| io::Error::other("qualification result missing"))?;
    let complete = entries
        .iter()
        .all(|entry| entry.coverage_complete && !entry.verdict.starts_with("deferred:"));
    Ok(QualificationReport {
        root: (roots.len() == 1).then(|| roots[0].clone()),
        roots,
        cutoff_epoch_seconds,
        cutoff_source: "explicit",
        complete,
        entries,
    })
}

// An exact path list is a nomination, never a cleanup verdict. The apply side
// independently checks this identity, the exclusive cutoff, and all C14 holds.
pub fn create(paths: &[PathBuf], before_epoch_seconds: i64) -> io::Result<Manifest> {
    create_in(paths, before_epoch_seconds, false)
}

pub fn create_in(
    paths: &[PathBuf],
    before_epoch_seconds: i64,
    system_tmp: bool,
) -> io::Result<Manifest> {
    if paths.is_empty() {
        return Err(io::Error::other("scratch-manifest needs at least one path"));
    }
    let cutoff_ns = timestamp_ns(before_epoch_seconds, 0)?;
    let root = if system_tmp {
        crate::scratch_lease::temp_path()?
    } else {
        registered_scratch()?.0
    };
    let root_meta = fs::symlink_metadata(&root)?;
    let dev = root_meta.dev();
    if !root_meta.is_dir() {
        return Err(io::Error::other("Scratch root changed during resolution"));
    }
    let mut seen = BTreeSet::new();
    let mut entries = Vec::with_capacity(paths.len());
    let qualification = qualify_under_roots(
        paths,
        before_epoch_seconds,
        ScanOptions {
            deadline: Duration::from_secs(30),
            max_entries: 1_000_000,
        },
        1,
        vec![root.clone()],
        None,
    )?;
    for verdict in &qualification.entries {
        let path = &verdict.path;
        let relative = path
            .strip_prefix(&root)
            .map_err(|_| io::Error::other(format!("outside manifest root: {}", path.display())))?;
        let metadata = entry_metadata(&root, relative, dev)?;
        if verdict.verdict != "age_qualified_policy_pending" || !verdict.coverage_complete {
            return Err(io::Error::other(format!(
                "exact path is not an old, completely observed candidate: {} ({})",
                path.display(),
                verdict.verdict
            )));
        }
        let mtime_ns = timestamp_ns(metadata.mtime(), metadata.mtime_nsec())?;
        let ctime_ns = timestamp_ns(metadata.ctime(), metadata.ctime_nsec())?;
        if verdict.device != Some(metadata.dev())
            || verdict.inode != Some(metadata.ino())
            || verdict.modified_epoch_nanos != Some(mtime_ns)
            || verdict.changed_epoch_nanos != Some(ctime_ns)
        {
            return Err(io::Error::other(format!(
                "exact path identity changed after qualification: {}",
                path.display()
            )));
        }
        let kind = if metadata.is_file() {
            if mtime_ns >= cutoff_ns {
                return Err(io::Error::other(format!(
                    "file is at or after the cutoff: {}",
                    path.display()
                )));
            }
            "regular_file"
        } else if metadata.is_dir() {
            if possible_dated_run(&root.join("runs"), path).is_some() {
                "managed_run"
            } else {
                "directory"
            }
        } else {
            return Err(io::Error::other(format!(
                "manifest requires a regular file or exact managed run: {}",
                path.display()
            )));
        };
        if !seen.insert(relative) {
            return Err(io::Error::other(format!(
                "duplicate file path: {}",
                path.display()
            )));
        }
        entries.push(Entry {
            path: relative.into(),
            kind: kind.to_owned(),
            dev,
            ino: metadata.ino(),
            size: metadata.len(),
            mtime_ns,
            ctime_ns,
        });
    }
    let current = fs::symlink_metadata(&root)?;
    if !current.is_dir() || current.dev() != dev || current.ino() != root_meta.ino() {
        return Err(io::Error::other(
            "Scratch root changed while building manifest",
        ));
    }
    Ok(Manifest {
        version: 1,
        root: RootIdentity {
            path: root,
            dev,
            ino: root_meta.ino(),
        },
        before_epoch_seconds,
        entries,
    })
}

pub(crate) fn entry_metadata(root: &Path, relative: &Path, device: u64) -> io::Result<Metadata> {
    let mut current = root.to_path_buf();
    let mut parts = relative.components().peekable();
    if parts.peek().is_none() || relative.to_str().is_none() {
        return Err(io::Error::other(
            "manifest requires a descendant UTF-8 path",
        ));
    }
    while let Some(Component::Normal(name)) = parts.next() {
        current.push(name);
        let metadata = fs::symlink_metadata(&current)?;
        if metadata.dev() != device {
            return Err(io::Error::other(
                "manifest path crosses a filesystem boundary",
            ));
        }
        if parts.peek().is_none() && (metadata.is_file() || metadata.is_dir()) {
            return Ok(metadata);
        }
        if !metadata.is_dir() {
            break;
        }
    }
    Err(io::Error::other(format!(
        "manifest requires a regular file or managed run through real directories: {}",
        relative.display()
    )))
}
