use serde::Serialize;
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

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum FileKind {
    File,
    Symlink,
    Special,
}

#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ScanGapKind {
    ReadDirectory,
    Metadata,
    Deadline,
    EntryLimit,
    CrossDevice,
}

#[derive(Clone, Debug, Serialize)]
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

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
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
    pub complete: bool,
}

#[derive(Clone, Debug, Serialize)]
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
}

#[cfg(unix)]
fn inode(m: &Metadata) -> Inode {
    use std::os::unix::fs::MetadataExt;
    Inode {
        device: m.dev(),
        number: m.ino(),
    }
}
#[cfg(not(unix))]
fn inode(m: &Metadata) -> Inode {
    Inode {
        device: 0,
        number: m.len(),
    }
}
#[cfg(unix)]
fn device(m: &Metadata) -> u64 {
    use std::os::unix::fs::MetadataExt;
    m.dev()
}
#[cfg(not(unix))]
fn device(_: &Metadata) -> u64 {
    0
}
#[cfg(unix)]
fn allocated_bytes(m: &Metadata) -> u64 {
    use std::os::unix::fs::MetadataExt;
    m.blocks().saturating_mul(512)
}
#[cfg(not(unix))]
fn allocated_bytes(m: &Metadata) -> u64 {
    m.len()
}

#[cfg(unix)]
fn path_parts(path: &Path) -> (String, Option<String>) {
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
#[cfg(not(unix))]
fn path_parts(path: &Path) -> (String, Option<String>) {
    (path.to_string_lossy().into_owned(), None)
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

fn special_file_type(metadata: &Metadata) -> Option<SpecialFileKind> {
    if file_kind(metadata) != FileKind::Special {
        return None;
    }
    #[cfg(unix)]
    {
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
    #[cfg(not(unix))]
    {
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
fn add(a: u64, b: u64) -> io::Result<u64> {
    a.checked_add(b)
        .ok_or_else(|| io::Error::other("scan measurement overflow"))
}
fn gap(gaps: &mut Vec<ScanGap>, path: &Path, kind: ScanGapKind, message: impl Into<String>) {
    let (path, path_bytes_hex) = path_parts(path);
    gaps.push(ScanGap {
        path,
        path_bytes_hex,
        kind,
        message: message.into(),
    });
}
fn expired(start: Instant, budget: Duration) -> bool {
    start.elapsed() >= budget
}

pub fn scan(root: &Path, options: ScanOptions) -> io::Result<ScanReport> {
    let start = Instant::now();
    let root = root.to_path_buf();
    let root_metadata = fs::symlink_metadata(&root)?;
    let (root_wire, root_bytes_hex) = path_parts(&root);
    let root_device = device(&root_metadata);
    let mut files = Vec::new();
    let mut directories = Vec::new();
    let mut gaps = Vec::new();
    let mut seen_inodes = HashSet::new();
    let mut apparent_total = 0;
    let mut allocated_total = 0;

    if expired(start, options.deadline) {
        gap(
            &mut gaps,
            &root,
            ScanGapKind::Deadline,
            "deadline before root inspection",
        );
        return Ok(report(
            root_wire,
            root_bytes_hex,
            false,
            apparent_total,
            allocated_total,
            files,
            directories,
            gaps,
        ));
    }
    if options.max_entries == 0 {
        gap(
            &mut gaps,
            &root,
            ScanGapKind::EntryLimit,
            "entry limit is zero",
        );
        return Ok(report(
            root_wire,
            root_bytes_hex,
            false,
            apparent_total,
            allocated_total,
            files,
            directories,
            gaps,
        ));
    }
    if root_metadata.file_type().is_symlink() {
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
            FileKind::Symlink,
            &mut files,
            &mut seen_inodes,
            &mut apparent_total,
            &mut allocated_total,
        )?;
        return Ok(report(
            root_wire,
            root_bytes_hex,
            true,
            apparent_total,
            allocated_total,
            files,
            directories,
            gaps,
        ));
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
        return Ok(report(
            root_wire,
            root_bytes_hex,
            true,
            apparent_total,
            allocated_total,
            files,
            directories,
            gaps,
        ));
    }

    let mut nodes = vec![Node {
        path: root.clone(),
        metadata: root_metadata,
        children: Vec::new(),
        complete: true,
        apparent: 0,
        path_allocated: 0,
        file_paths: 0,
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
            nodes.push(Node {
                path,
                metadata,
                children: Vec::new(),
                complete: true,
                apparent: 0,
                path_allocated: 0,
                file_paths: 0,
            });
            nodes[parent].children.push(index);
            if is_dir {
                pending.push(index);
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
                nodes[index].apparent = add(nodes[index].apparent, child_apparent)?;
                nodes[index].path_allocated = add(nodes[index].path_allocated, child_allocated)?;
                nodes[index].file_paths = add(nodes[index].file_paths, child_paths)?;
                nodes[index].complete &= child_complete;
            }
            let node = &nodes[index];
            let (path, path_bytes_hex) = path_parts(&node.path);
            directories.push(DirectoryMeasurement {
                path,
                path_bytes_hex,
                apparent_bytes: node.apparent,
                path_allocated_bytes: node.path_allocated,
                file_paths: node.file_paths,
                must_itemize: node
                    .complete
                    .then_some(node.apparent >= ITEMIZATION_THRESHOLD_BYTES),
                complete: node.complete,
            });
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
        }
        all_complete &= nodes[index].complete;
    }

    files.sort_by(|a, b| a.path.cmp(&b.path));
    directories.sort_by(|a, b| a.path.cmp(&b.path));
    gaps.sort_by(|a, b| (&a.path, a.kind).cmp(&(&b.path, b.kind)));
    Ok(report(
        root_wire,
        root_bytes_hex,
        all_complete,
        apparent_total,
        allocated_total,
        files,
        directories,
        gaps,
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
    let (path, path_bytes_hex) = path_parts(path);
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
    root: String,
    root_bytes_hex: Option<String>,
    complete: bool,
    apparent_bytes: u64,
    allocated_bytes: u64,
    files: Vec<FileMeasurement>,
    directories: Vec<DirectoryMeasurement>,
    gaps: Vec<ScanGap>,
) -> ScanReport {
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
