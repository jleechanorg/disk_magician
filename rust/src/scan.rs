use serde::{Deserialize, Serialize};
use std::collections::HashSet;
use std::fs::{self, Metadata};
use std::io;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant, UNIX_EPOCH};

pub const ITEMIZATION_THRESHOLD_BYTES: u64 = 100 * 1024 * 1024;

#[derive(Clone, Copy, Debug)]
pub struct ScanOptions {
    pub deadline: Duration,
    /// Maximum paths whose metadata is inspected, including the root.
    pub max_entries: usize,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum FileKind {
    File,
    Symlink,
    Special,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, Ord, PartialEq, PartialOrd, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ScanGapKind {
    NotScanned,
    ReadDirectory,
    Metadata,
    Deadline,
    EntryLimit,
    CrossDevice,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct FileMeasurement {
    pub path: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub path_bytes_hex: Option<String>,
    pub kind: FileKind,
    /// Apparent size of this pathname. Hardlink paths each retain their size.
    pub apparent_bytes: u64,
    /// Allocated blocks associated with this inode path.
    pub allocated_bytes: u64,
    pub modified_epoch_seconds: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub special_type: Option<SpecialFileKind>,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum SpecialFileKind {
    Fifo,
    Socket,
    CharacterDevice,
    BlockDevice,
    Unknown,
}

#[derive(Clone, Debug, Serialize)]
pub struct DirectoryMeasurement {
    pub path: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub path_bytes_hex: Option<String>,
    /// Subtree apparent bytes, summed per pathname.
    pub apparent_bytes: u64,
    /// Subtree allocated bytes summed per pathname; not additive across siblings.
    pub path_allocated_bytes: u64,
    pub file_paths: u64,
    /// Unknown if traversal was incomplete. Exactly 100 MiB requires itemization.
    pub must_itemize: Option<bool>,
    pub newest_content_epoch_seconds: Option<i64>,
    pub contains_git: bool,
    pub complete: bool,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct ScanGap {
    pub path: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub path_bytes_hex: Option<String>,
    pub kind: ScanGapKind,
    pub message: String,
}

#[derive(Clone, Debug, Serialize)]
pub struct ScanReport {
    pub root: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub root_bytes_hex: Option<String>,
    pub threshold_bytes: u64,
    pub complete: bool,
    /// Measured apparent bytes, path-summed; a lower bound when partial.
    pub apparent_bytes: u64,
    /// Measured allocated bytes, inode-deduplicated by device and inode.
    pub allocated_bytes: u64,
    pub files: Vec<FileMeasurement>,
    pub directories: Vec<DirectoryMeasurement>,
    pub gaps: Vec<ScanGap>,
}

/// Per-path timestamps and identity observed during the same filesystem walk.
/// Paths are absolute OS-native bytes so callers can store them losslessly.
#[derive(Clone, Debug)]
pub struct AgeMeasurement {
    /// Absolute, raw OS path bytes. JSON adapters should encode these as hex.
    pub path_bytes: Vec<u8>,
    pub kind: AgeKind,
    pub created_epoch_nanos: Option<i64>,
    /// The object's own mtime. For directories, this records directory changes.
    pub modified_epoch_nanos: Option<i64>,
    pub changed_epoch_nanos: Option<i64>,
    /// For directories this is path-summed subtree allocation and overlaps descendants.
    pub allocated_bytes: u64,
    pub apparent_bytes: u64,
    pub device: u64,
    pub inode: u64,
    /// Maximum mtime of this object and all observed descendants.
    pub effective_modified_epoch_nanos: Option<i64>,
    /// False when this entry or any descendant was not fully observed.
    pub complete: bool,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum AgeKind {
    File,
    Directory,
    Symlink,
    Special,
}

#[derive(Clone, Debug)]
pub struct AgeInventoryReport {
    pub root_path_bytes: Vec<u8>,
    pub root_device: u64,
    pub root_inode: u64,
    pub entries: Vec<AgeMeasurement>,
    pub gaps: Vec<ScanGap>,
    pub complete: bool,
}

#[derive(Hash, Eq, PartialEq)]
struct Inode {
    device: u64,
    number: u64,
}

struct Node {
    path: PathBuf,
    metadata: Metadata,
    children: Vec<usize>,
    complete: bool,
    apparent: u64,
    path_allocated: u64,
    file_paths: u64,
    has_content: bool,
    newest_leaf_epoch: Option<i64>,
    empty_tree_epoch: Option<i64>,
    newest_observed_mtime_nanos: Option<i64>,
    contains_git: bool,
}

fn inode(m: &Metadata) -> Inode {
    use std::os::unix::fs::MetadataExt;
    Inode {
        device: m.dev(),
        number: m.ino(),
    }
}
fn device(m: &Metadata) -> u64 {
    use std::os::unix::fs::MetadataExt;
    m.dev()
}
fn allocated_bytes(m: &Metadata) -> u64 {
    use std::os::unix::fs::MetadataExt;
    m.blocks().saturating_mul(512)
}

pub fn path_parts_for_report(path: &Path) -> (String, Option<String>) {
    use std::os::unix::ffi::OsStrExt;
    let bytes = path.as_os_str().as_bytes();
    let hex = std::str::from_utf8(bytes).err().map(|_| {
        let mut output = String::with_capacity(bytes.len() * 2);
        for byte in bytes {
            use std::fmt::Write as _;
            let _ = write!(output, "{byte:02x}");
        }
        output
    });
    (String::from_utf8_lossy(bytes).into_owned(), hex)
}

fn file_kind(metadata: &Metadata) -> FileKind {
    if metadata.file_type().is_symlink() {
        FileKind::Symlink
    } else if metadata.is_file() {
        FileKind::File
    } else {
        FileKind::Special
    }
}

fn age_kind(metadata: &Metadata) -> AgeKind {
    if metadata.file_type().is_symlink() {
        AgeKind::Symlink
    } else if metadata.is_dir() {
        AgeKind::Directory
    } else if metadata.is_file() {
        AgeKind::File
    } else {
        AgeKind::Special
    }
}

fn special_file_type(metadata: &Metadata) -> Option<SpecialFileKind> {
    if file_kind(metadata) != FileKind::Special {
        return None;
    }
    use std::os::unix::fs::FileTypeExt;
    let file_type = metadata.file_type();
    if file_type.is_fifo() {
        Some(SpecialFileKind::Fifo)
    } else if file_type.is_socket() {
        Some(SpecialFileKind::Socket)
    } else if file_type.is_char_device() {
        Some(SpecialFileKind::CharacterDevice)
    } else if file_type.is_block_device() {
        Some(SpecialFileKind::BlockDevice)
    } else {
        Some(SpecialFileKind::Unknown)
    }
}

fn modified_epoch_seconds(m: &Metadata) -> Option<i64> {
    i64::try_from(
        m.modified()
            .ok()?
            .duration_since(UNIX_EPOCH)
            .ok()?
            .as_secs(),
    )
    .ok()
}

fn time_epoch_nanos(value: std::time::SystemTime) -> Option<i64> {
    let nanos = value.duration_since(UNIX_EPOCH).ok()?.as_nanos();
    i64::try_from(nanos).ok()
}

fn created_epoch_nanos(metadata: &Metadata) -> Option<i64> {
    time_epoch_nanos(metadata.created().ok()?)
}

fn modified_epoch_nanos(metadata: &Metadata) -> Option<i64> {
    time_epoch_nanos(metadata.modified().ok()?)
}

fn changed_epoch_nanos(metadata: &Metadata) -> Option<i64> {
    use std::os::unix::fs::MetadataExt;

    let seconds = i128::from(metadata.ctime());
    let nanoseconds = i128::from(metadata.ctime_nsec());
    i64::try_from(
        seconds
            .checked_mul(1_000_000_000)?
            .checked_add(nanoseconds)?,
    )
    .ok()
}

pub(crate) fn same_directory_observation(before: &Metadata, after: &Metadata) -> bool {
    use std::os::unix::fs::MetadataExt;

    before.dev() == after.dev()
        && before.ino() == after.ino()
        && before.mtime() == after.mtime()
        && before.mtime_nsec() == after.mtime_nsec()
        && before.ctime() == after.ctime()
        && before.ctime_nsec() == after.ctime_nsec()
}

fn path_bytes(path: &Path) -> Vec<u8> {
    use std::os::unix::ffi::OsStrExt;
    path.as_os_str().as_bytes().to_vec()
}

fn metadata_device_and_inode(metadata: &Metadata) -> (u64, u64) {
    use std::os::unix::fs::MetadataExt;
    (metadata.dev(), metadata.ino())
}

pub(crate) fn age_measurement(
    path: &Path,
    metadata: &Metadata,
    kind: AgeKind,
    allocated_bytes: u64,
    apparent_bytes: u64,
    effective_modified_epoch_nanos: Option<i64>,
    complete: bool,
) -> AgeMeasurement {
    let (device, inode) = metadata_device_and_inode(metadata);
    AgeMeasurement {
        path_bytes: path_bytes(path),
        kind,
        created_epoch_nanos: created_epoch_nanos(metadata),
        modified_epoch_nanos: modified_epoch_nanos(metadata),
        changed_epoch_nanos: changed_epoch_nanos(metadata),
        allocated_bytes,
        apparent_bytes,
        device,
        inode,
        effective_modified_epoch_nanos,
        complete,
    }
}

fn age_inventory_report(
    root: &Path,
    root_metadata: &Metadata,
    entries: Vec<AgeMeasurement>,
    gaps: &[ScanGap],
    complete: bool,
) -> AgeInventoryReport {
    let (root_device, root_inode) = metadata_device_and_inode(root_metadata);
    AgeInventoryReport {
        root_path_bytes: path_bytes(root),
        root_device,
        root_inode,
        entries,
        gaps: gaps.to_vec(),
        complete,
    }
}
fn add(a: u64, b: u64) -> io::Result<u64> {
    a.checked_add(b)
        .ok_or_else(|| io::Error::other("scan measurement overflow"))
}
fn gap(gaps: &mut Vec<ScanGap>, path: &Path, kind: ScanGapKind, message: impl Into<String>) {
    let (path, path_bytes_hex) = path_parts_for_report(path);
    gaps.push(ScanGap {
        path,
        path_bytes_hex,
        kind,
        message: message.into(),
    });
}
fn is_git_name(path: &Path) -> bool {
    path.file_name().is_some_and(|name| name == ".git")
}

fn max_epoch(left: Option<i64>, right: Option<i64>) -> Option<i64> {
    match (left, right) {
        (Some(left), Some(right)) => Some(left.max(right)),
        (Some(value), None) | (None, Some(value)) => Some(value),
        (None, None) => None,
    }
}

fn expired(start: Instant, budget: Duration) -> bool {
    start.elapsed() >= budget
}

pub fn scan(root: &Path, options: ScanOptions) -> io::Result<ScanReport> {
    scan_internal(root, options, false).map(|(report, _)| report)
}

/// Scan once and return both the existing report and per-path age inventory.
pub fn scan_with_age_inventory(
    root: &Path,
    options: ScanOptions,
) -> io::Result<(ScanReport, AgeInventoryReport)> {
    let (report, inventory) = scan_internal(root, options, true)?;
    Ok((
        report,
        inventory.expect("age inventory requested by scan_with_age_inventory"),
    ))
}

fn scan_internal(
    root: &Path,
    options: ScanOptions,
    include_age_inventory: bool,
) -> io::Result<(ScanReport, Option<AgeInventoryReport>)> {
    let start = Instant::now();
    let root = root.to_path_buf();
    let root_metadata = fs::symlink_metadata(&root)?;
    let root_device = device(&root_metadata);
    let mut files = Vec::new();
    let mut directories = Vec::new();
    let mut gaps = Vec::new();
    let mut age_entries = Vec::new();
    let mut seen_inodes = HashSet::new();
    let mut apparent_total = 0;
    let mut allocated_total = 0;

    let early_gap = if expired(start, options.deadline) {
        Some((ScanGapKind::Deadline, "deadline before root inspection"))
    } else if options.max_entries == 0 {
        Some((ScanGapKind::EntryLimit, "entry limit is zero"))
    } else {
        None
    };
    if let Some((kind, reason)) = early_gap {
        gap(&mut gaps, &root, kind, reason);
        let report = report(
            &root,
            false,
            apparent_total,
            allocated_total,
            files,
            directories,
            gaps,
        );
        let inventory = include_age_inventory.then(|| {
            age_inventory_report(
                &root,
                &root_metadata,
                vec![age_measurement(
                    &root,
                    &root_metadata,
                    if root_metadata.is_dir() {
                        AgeKind::Directory
                    } else {
                        age_kind(&root_metadata)
                    },
                    allocated_bytes(&root_metadata),
                    root_metadata.len(),
                    modified_epoch_nanos(&root_metadata),
                    false,
                )],
                &report.gaps,
                false,
            )
        });
        return Ok((report, inventory));
    }
    if !root_metadata.is_dir() {
        if modified_epoch_seconds(&root_metadata).is_none() {
            gap(
                &mut gaps,
                &root,
                ScanGapKind::Metadata,
                "modification time unavailable",
            );
        }
        add_file(
            &root,
            &root_metadata,
            file_kind(&root_metadata),
            &mut files,
            &mut seen_inodes,
            &mut apparent_total,
            &mut allocated_total,
        )?;
        let report = report(
            &root,
            gaps.is_empty(),
            apparent_total,
            allocated_total,
            files,
            directories,
            gaps,
        );
        let inventory = include_age_inventory.then(|| {
            let measurement = age_measurement(
                &root,
                &root_metadata,
                age_kind(&root_metadata),
                allocated_bytes(&root_metadata),
                root_metadata.len(),
                modified_epoch_nanos(&root_metadata),
                report.complete,
            );
            age_inventory_report(
                &root,
                &root_metadata,
                vec![measurement],
                &report.gaps,
                report.complete,
            )
        });
        return Ok((report, inventory));
    }

    let root_empty_tree_epoch = modified_epoch_seconds(&root_metadata);
    let root_contains_git = is_git_name(&root);
    let root_effective_mtime = include_age_inventory
        .then(|| modified_epoch_nanos(&root_metadata))
        .flatten();
    if include_age_inventory && root_effective_mtime.is_none() {
        gap(
            &mut gaps,
            &root,
            ScanGapKind::Metadata,
            "directory modification time unavailable",
        );
    }
    let mut nodes = vec![Node {
        path: root.clone(),
        metadata: root_metadata,
        children: Vec::new(),
        complete: !include_age_inventory || root_effective_mtime.is_some(),
        apparent: 0,
        path_allocated: 0,
        file_paths: 0,
        has_content: false,
        newest_leaf_epoch: None,
        empty_tree_epoch: root_empty_tree_epoch,
        newest_observed_mtime_nanos: root_effective_mtime,
        contains_git: root_contains_git,
    }];
    let mut pending = vec![0_usize];
    let mut visited = 1_usize;
    while let Some(parent) = pending.pop() {
        if expired(start, options.deadline) {
            nodes[parent].complete = false;
            gap(
                &mut gaps,
                &nodes[parent].path,
                ScanGapKind::Deadline,
                "deadline while reading directory",
            );
            continue;
        }
        let parent_path = nodes[parent].path.clone();
        let entries = match fs::read_dir(&parent_path) {
            Ok(entries) => entries,
            Err(e) => {
                nodes[parent].complete = false;
                gap(
                    &mut gaps,
                    &parent_path,
                    ScanGapKind::ReadDirectory,
                    e.to_string(),
                );
                continue;
            }
        };
        let before_enumeration = include_age_inventory.then(|| nodes[parent].metadata.clone());
        for entry in entries {
            if expired(start, options.deadline) {
                nodes[parent].complete = false;
                gap(
                    &mut gaps,
                    &parent_path,
                    ScanGapKind::Deadline,
                    "deadline before directory was fully enumerated",
                );
                break;
            }
            let entry = match entry {
                Ok(e) => e,
                Err(e) => {
                    nodes[parent].complete = false;
                    gap(
                        &mut gaps,
                        &parent_path,
                        ScanGapKind::ReadDirectory,
                        e.to_string(),
                    );
                    continue;
                }
            };
            if visited >= options.max_entries {
                nodes[parent].complete = false;
                gap(
                    &mut gaps,
                    &parent_path,
                    ScanGapKind::EntryLimit,
                    format!(
                        "entry limit {} reached before directory was fully enumerated",
                        options.max_entries
                    ),
                );
                break;
            }
            let path = entry.path();
            let metadata = match fs::symlink_metadata(&path) {
                Ok(m) => m,
                Err(e) => {
                    nodes[parent].complete = false;
                    gap(&mut gaps, &path, ScanGapKind::Metadata, e.to_string());
                    visited += 1;
                    continue;
                }
            };
            visited += 1;
            if device(&metadata) != root_device {
                nodes[parent].complete = false;
                gap(
                    &mut gaps,
                    &path,
                    ScanGapKind::CrossDevice,
                    "different filesystem boundary",
                );
                continue;
            }
            let index = nodes.len();
            let is_dir = metadata.is_dir();
            let empty_tree_epoch = if is_dir {
                modified_epoch_seconds(&metadata)
            } else {
                None
            };
            let entry_modified_nanos = include_age_inventory
                .then(|| modified_epoch_nanos(&metadata))
                .flatten();
            let entry_complete =
                !include_age_inventory || !is_dir || entry_modified_nanos.is_some();
            if !entry_complete {
                gap(
                    &mut gaps,
                    &path,
                    ScanGapKind::Metadata,
                    "directory modification time unavailable",
                );
            }
            let contains_git = is_git_name(&path);
            nodes.push(Node {
                path,
                metadata,
                children: Vec::new(),
                complete: entry_complete,
                apparent: 0,
                path_allocated: 0,
                file_paths: 0,
                has_content: false,
                newest_leaf_epoch: None,
                empty_tree_epoch,
                newest_observed_mtime_nanos: entry_modified_nanos,
                contains_git,
            });
            nodes[parent].children.push(index);
            if is_dir {
                pending.push(index);
            }
        }
        if let Some(before_enumeration) = before_enumeration {
            match fs::symlink_metadata(&parent_path) {
                Ok(after_enumeration) => {
                    if !same_directory_observation(&before_enumeration, &after_enumeration) {
                        nodes[parent].complete = false;
                        gap(
                            &mut gaps,
                            &parent_path,
                            ScanGapKind::Metadata,
                            "directory changed during enumeration",
                        );
                    }
                }
                Err(error) => {
                    nodes[parent].complete = false;
                    gap(
                        &mut gaps,
                        &parent_path,
                        ScanGapKind::Metadata,
                        format!("directory could not be rechecked after enumeration: {error}"),
                    );
                }
            }
        }
    }

    let mut all_complete = gaps.is_empty();
    for index in (0..nodes.len()).rev() {
        if nodes[index].metadata.is_dir() {
            let children = nodes[index].children.clone();
            for child_index in children {
                let child_apparent = nodes[child_index].apparent;
                let child_allocated = nodes[child_index].path_allocated;
                let child_paths = nodes[child_index].file_paths;
                let child_complete = nodes[child_index].complete;
                let child_has_content = nodes[child_index].has_content;
                let child_newest_leaf = nodes[child_index].newest_leaf_epoch;
                let child_empty_tree = nodes[child_index].empty_tree_epoch;
                let child_newest_observed_mtime = nodes[child_index].newest_observed_mtime_nanos;
                let child_contains_git = nodes[child_index].contains_git;
                nodes[index].apparent = add(nodes[index].apparent, child_apparent)?;
                nodes[index].path_allocated = add(nodes[index].path_allocated, child_allocated)?;
                nodes[index].file_paths = add(nodes[index].file_paths, child_paths)?;
                nodes[index].complete &= child_complete;
                nodes[index].has_content |= child_has_content;
                nodes[index].newest_leaf_epoch =
                    max_epoch(nodes[index].newest_leaf_epoch, child_newest_leaf);
                nodes[index].empty_tree_epoch =
                    max_epoch(nodes[index].empty_tree_epoch, child_empty_tree);
                nodes[index].newest_observed_mtime_nanos = max_epoch(
                    nodes[index].newest_observed_mtime_nanos,
                    child_newest_observed_mtime,
                );
                nodes[index].contains_git |= child_contains_git;
            }
            if !nodes[index].has_content && nodes[index].empty_tree_epoch.is_none() {
                nodes[index].complete = false;
                let missing_time_path = nodes[index].path.clone();
                gap(
                    &mut gaps,
                    &missing_time_path,
                    ScanGapKind::Metadata,
                    "empty directory modification time unavailable",
                );
            }
            let node = &nodes[index];
            let (path, path_bytes_hex) = path_parts_for_report(&node.path);
            directories.push(DirectoryMeasurement {
                path,
                path_bytes_hex,
                apparent_bytes: node.apparent,
                path_allocated_bytes: node.path_allocated,
                file_paths: node.file_paths,
                must_itemize: node
                    .complete
                    .then_some(node.apparent >= ITEMIZATION_THRESHOLD_BYTES),
                newest_content_epoch_seconds: if node.has_content {
                    node.newest_leaf_epoch
                } else {
                    node.empty_tree_epoch
                },
                contains_git: node.contains_git,
                complete: node.complete,
            });
            if include_age_inventory {
                age_entries.push(age_measurement(
                    &node.path,
                    &node.metadata,
                    AgeKind::Directory,
                    node.path_allocated,
                    node.apparent,
                    node.newest_observed_mtime_nanos,
                    node.complete,
                ));
            }
        } else {
            let kind = file_kind(&nodes[index].metadata);
            let path = nodes[index].path.clone();
            let metadata = nodes[index].metadata.clone();
            if modified_epoch_seconds(&metadata).is_none() {
                nodes[index].complete = false;
                gap(
                    &mut gaps,
                    &path,
                    ScanGapKind::Metadata,
                    "modification time unavailable",
                );
            }
            add_file(
                &path,
                &metadata,
                kind,
                &mut files,
                &mut seen_inodes,
                &mut apparent_total,
                &mut allocated_total,
            )?;
            nodes[index].apparent = metadata.len();
            nodes[index].path_allocated = allocated_bytes(&metadata);
            nodes[index].file_paths = 1;
            nodes[index].has_content = true;
            nodes[index].newest_leaf_epoch = modified_epoch_seconds(&metadata);
            nodes[index].newest_observed_mtime_nanos = include_age_inventory
                .then(|| modified_epoch_nanos(&metadata))
                .flatten();
            nodes[index].contains_git = is_git_name(&path);
            if include_age_inventory {
                age_entries.push(age_measurement(
                    &path,
                    &metadata,
                    age_kind(&metadata),
                    allocated_bytes(&metadata),
                    metadata.len(),
                    nodes[index].newest_observed_mtime_nanos,
                    nodes[index].complete,
                ));
            }
        }
        all_complete &= nodes[index].complete;
    }

    files.sort_by(|a, b| a.path.cmp(&b.path));
    directories.sort_by(|a, b| a.path.cmp(&b.path));
    gaps.sort_by(|a, b| (&a.path, a.kind).cmp(&(&b.path, b.kind)));
    age_entries.sort_by(|a, b| a.path_bytes.cmp(&b.path_bytes));
    let inventory = include_age_inventory
        .then(|| age_inventory_report(&root, &nodes[0].metadata, age_entries, &gaps, all_complete));
    Ok((
        report(
            &root,
            all_complete,
            apparent_total,
            allocated_total,
            files,
            directories,
            gaps,
        ),
        inventory,
    ))
}

fn add_file(
    path: &Path,
    metadata: &Metadata,
    kind: FileKind,
    files: &mut Vec<FileMeasurement>,
    seen: &mut HashSet<Inode>,
    apparent_total: &mut u64,
    allocated_total: &mut u64,
) -> io::Result<()> {
    let apparent = metadata.len();
    let allocated = allocated_bytes(metadata);
    *apparent_total = add(*apparent_total, apparent)?;
    if seen.insert(inode(metadata)) {
        *allocated_total = add(*allocated_total, allocated)?;
    }
    let (path, path_bytes_hex) = path_parts_for_report(path);
    files.push(FileMeasurement {
        path,
        path_bytes_hex,
        kind,
        apparent_bytes: apparent,
        allocated_bytes: allocated,
        modified_epoch_seconds: modified_epoch_seconds(metadata),
        special_type: special_file_type(metadata),
    });
    Ok(())
}

fn report(
    root_path: &Path,
    complete: bool,
    apparent_bytes: u64,
    allocated_bytes: u64,
    files: Vec<FileMeasurement>,
    directories: Vec<DirectoryMeasurement>,
    gaps: Vec<ScanGap>,
) -> ScanReport {
    let (root, root_bytes_hex) = path_parts_for_report(root_path);
    ScanReport {
        root,
        root_bytes_hex,
        threshold_bytes: ITEMIZATION_THRESHOLD_BYTES,
        complete,
        apparent_bytes,
        allocated_bytes,
        files,
        directories,
        gaps,
    }
}
