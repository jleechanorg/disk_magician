//! Read-only allocated-size prefilter for submitted Scratch directories.
//! Unknown subtrees are omitted so the existing du batch can remain the fallback.

use std::collections::HashMap;
use std::fs;
use std::io::{self, Read};
use std::os::unix::ffi::{OsStrExt, OsStringExt};
use std::os::unix::fs::MetadataExt;
use std::path::PathBuf;

#[derive(Clone)]
struct Node {
    path: PathBuf,
    parent: Option<usize>,
    dev: u64,
    ino: u64,
    mode: u32,
    nlink: u64,
    size: u64,
    blocks: u64,
    mtime: (i64, i64),
    ctime: (i64, i64),
    is_dir: bool,
    known: bool,
    allocated_bytes: u128,
}

impl Node {
    fn new(path: PathBuf, metadata: &fs::Metadata, parent: Option<usize>) -> Self {
        Self {
            path,
            parent,
            dev: metadata.dev(),
            ino: metadata.ino(),
            mode: metadata.mode(),
            nlink: metadata.nlink(),
            size: metadata.size(),
            blocks: metadata.blocks(),
            mtime: (metadata.mtime(), metadata.mtime_nsec()),
            ctime: (metadata.ctime(), metadata.ctime_nsec()),
            is_dir: metadata.is_dir(),
            known: true,
            allocated_bytes: u128::from(metadata.blocks()) * 512,
        }
    }

    fn unchanged(&self, metadata: &fs::Metadata) -> bool {
        (
            self.dev,
            self.ino,
            self.mode,
            self.nlink,
            self.size,
            self.blocks,
            self.mtime,
            self.ctime,
        ) == (
            metadata.dev(),
            metadata.ino(),
            metadata.mode(),
            metadata.nlink(),
            metadata.size(),
            metadata.blocks(),
            (metadata.mtime(), metadata.mtime_nsec()),
            (metadata.ctime(), metadata.ctime_nsec()),
        )
    }
}

fn parse_roots(input: impl Read) -> io::Result<Vec<PathBuf>> {
    let mut bytes = Vec::new();
    let mut input = input.take(usize::MAX as u64);
    input.read_to_end(&mut bytes)?;
    if bytes.is_empty() {
        return Ok(Vec::new());
    }
    if bytes.last() != Some(&0) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "invalid NUL path list",
        ));
    }
    bytes.pop();
    if bytes.is_empty() || bytes.split(|byte| *byte == 0).any(|path| path.is_empty()) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "invalid NUL path list",
        ));
    }
    Ok(bytes
        .split(|byte| *byte == 0)
        .map(|path| PathBuf::from(std::ffi::OsString::from_vec(path.to_vec())))
        .collect())
}

/// Output records each measured candidate as raw allocated 512-byte blocks, NUL, path, NUL.
/// The caller uses the result only when it has exactly one record per input.
pub fn measure_batch(input: impl Read) -> io::Result<Vec<u8>> {
    let requested = parse_roots(input)?;
    let mut occurrences = HashMap::<PathBuf, usize>::new();
    for path in &requested {
        *occurrences.entry(path.clone()).or_default() += 1;
    }
    // Checking lexical ancestors keeps overlap discovery proportional to path depth.
    let top_roots = occurrences.keys().filter(|path| {
        !path
            .ancestors()
            .skip(1)
            .any(|ancestor| occurrences.contains_key(ancestor))
    });

    let mut nodes = Vec::<Node>::new();
    let mut visited_dirs = HashMap::<(u64, u64), usize>::new();

    for root in top_roots {
        let root_metadata = match fs::symlink_metadata(root) {
            Ok(metadata) if metadata.is_dir() && !metadata.file_type().is_symlink() => metadata,
            Ok(_) => continue,
            Err(_) => continue,
        };
        if let Some(previous) = visited_dirs
            .get(&(root_metadata.dev(), root_metadata.ino()))
            .copied()
        {
            nodes[previous].known = false;
            continue;
        }
        let root_index = nodes.len();
        nodes.push(Node::new(root.clone(), &root_metadata, None));
        visited_dirs.insert((root_metadata.dev(), root_metadata.ino()), root_index);
        let root_dev = root_metadata.dev();
        let mut pending = vec![root_index];

        while let Some(parent_index) = pending.pop() {
            let parent_path = nodes[parent_index].path.clone();
            let entries = match fs::read_dir(&parent_path) {
                Ok(entries) => entries,
                Err(_) => {
                    nodes[parent_index].known = false;
                    continue;
                }
            };
            for entry in entries {
                let entry = match entry {
                    Ok(entry) => entry,
                    Err(_) => {
                        nodes[parent_index].known = false;
                        continue;
                    }
                };
                let child_path = entry.path();
                let metadata = match fs::symlink_metadata(&child_path) {
                    Ok(metadata) => metadata,
                    Err(_) => {
                        nodes[parent_index].known = false;
                        continue;
                    }
                };
                if metadata.dev() != root_dev {
                    nodes[parent_index].known = false;
                    continue;
                }
                if !metadata.is_dir() && metadata.nlink() > 1 {
                    nodes[parent_index].known = false;
                    continue;
                }

                let child_index = nodes.len();
                if metadata.is_dir() {
                    let inode = (metadata.dev(), metadata.ino());
                    if let Some(previous) = visited_dirs.get(&inode).copied() {
                        nodes[previous].known = false;
                        nodes[parent_index].known = false;
                        continue;
                    }
                    visited_dirs.insert(inode, child_index);
                }
                let is_directory = metadata.is_dir();
                nodes.push(Node::new(child_path, &metadata, Some(parent_index)));
                if is_directory {
                    pending.push(child_index);
                }
            }
        }

        for node in &mut nodes[root_index..] {
            match fs::symlink_metadata(&node.path) {
                Ok(metadata) if node.unchanged(&metadata) => {}
                _ => node.known = false,
            }
        }
    }

    // A later top root can reveal an alias inside an earlier root. Propagate
    // all omissions after the walk, once the visited inode set is complete.
    for index in (0..nodes.len()).rev() {
        if let Some(parent) = nodes[index].parent {
            let child_bytes = nodes[index].allocated_bytes;
            let child_known = nodes[index].known;
            nodes[parent].allocated_bytes += child_bytes;
            nodes[parent].known &= child_known;
        }
    }

    let by_path: HashMap<_, _> = nodes
        .iter()
        .enumerate()
        .map(|(index, node)| (&node.path, index))
        .collect();
    let mut output = Vec::new();
    for path in requested {
        let Some(index) = by_path.get(&path).copied() else {
            continue;
        };
        let node = &nodes[index];
        if !node.known || !node.is_dir {
            continue;
        }
        if occurrences.get(&path).copied() != Some(1) {
            continue;
        }
        let Ok(blocks) = u64::try_from(node.allocated_bytes / 512) else {
            continue;
        };
        output.extend_from_slice(blocks.to_string().as_bytes());
        output.push(0);
        output.extend_from_slice(path.as_os_str().as_bytes());
        output.push(0);
    }
    Ok(output)
}

#[cfg(all(test, target_os = "linux"))]
mod tests {
    use super::*;
    use std::os::unix::ffi::OsStrExt;
    use std::os::unix::fs::symlink;
    use std::path::Path;
    use std::process::Command;
    use std::sync::atomic::{AtomicU64, Ordering};

    static NEXT: AtomicU64 = AtomicU64::new(0);

    struct Fixture(PathBuf);

    impl Fixture {
        fn new() -> Self {
            let scratch = std::env::var_os("DISKM_SCRATCH_TEST_DIR")
                .map(PathBuf::from)
                .expect("tests require DISKM_SCRATCH_TEST_DIR on registered Scratch");
            let root = fs::canonicalize(scratch).unwrap().join(format!(
                "artifact-size-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
            fs::create_dir(&root).unwrap();
            Self(root)
        }

        fn path(&self, value: &str) -> PathBuf {
            self.0.join(value)
        }
    }

    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    fn measure(paths: &[&Path]) -> Vec<(u64, Vec<u8>)> {
        let mut input = Vec::new();
        for path in paths {
            input.extend_from_slice(path.as_os_str().as_bytes());
            input.push(0);
        }
        let result = measure_batch(input.as_slice()).unwrap();
        let fields: Vec<_> = result[..result.len().saturating_sub(usize::from(!result.is_empty()))]
            .split(|byte| *byte == 0)
            .collect();
        fields
            .chunks_exact(2)
            .map(|pair| {
                (
                    std::str::from_utf8(pair[0]).unwrap().parse().unwrap(),
                    pair[1].to_vec(),
                )
            })
            .collect()
    }

    fn du_kib(path: &Path) -> u64 {
        let result = Command::new("du")
            .args(["-sk", "--"])
            .arg(path)
            .output()
            .unwrap();
        assert!(
            result.status.success(),
            "{}",
            String::from_utf8_lossy(&result.stderr)
        );
        std::str::from_utf8(result.stdout.split(|byte| *byte == b'\t').next().unwrap())
            .unwrap()
            .trim()
            .parse()
            .unwrap()
    }

    #[test]
    fn reports_sparse_file_and_directory_sizes_matching_du() {
        let fixture = Fixture::new();
        let root = fixture.path("root");
        fs::create_dir(&root).unwrap();
        fs::create_dir(root.join("nested")).unwrap();
        fs::write(root.join("plain"), vec![b'x'; 1200]).unwrap();
        fs::File::create(root.join("nested/sparse"))
            .unwrap()
            .set_len(64 * 1024 * 1024)
            .unwrap();
        symlink("nested/sparse", root.join("link")).unwrap();
        let sizes = measure(&[&root]);
        assert_eq!(sizes.len(), 1);
        assert_eq!(sizes[0].0.div_ceil(2), du_kib(&root));
        assert_eq!(sizes[0].1, root.as_os_str().as_bytes());
        let nested = root.join("nested");
        let other = fixture.path("other");
        fs::create_dir(&other).unwrap();
        fs::write(other.join("payload"), b"independent").unwrap();
        let expected_blocks = fs::symlink_metadata(&root).unwrap().blocks()
            + fs::symlink_metadata(root.join("nested")).unwrap().blocks()
            + fs::symlink_metadata(root.join("plain")).unwrap().blocks()
            + fs::symlink_metadata(root.join("nested/sparse"))
                .unwrap()
                .blocks()
            + fs::symlink_metadata(root.join("link")).unwrap().blocks();
        let sizes = measure(&[&root, &nested, &other]);
        assert_eq!(sizes.len(), 3);
        assert_eq!(sizes[0].0, expected_blocks);
        assert_eq!(sizes[0].0.div_ceil(2), du_kib(&root));
        assert_eq!(sizes[1].0.div_ceil(2), du_kib(&nested));
        assert_eq!(sizes[2].0.div_ceil(2), du_kib(&other));
    }

    #[test]
    fn preserves_overlapping_roots_and_raw_non_utf8_names() {
        let fixture = Fixture::new();
        let root = fixture.path("root");
        fs::create_dir(&root).unwrap();
        let raw = root.join(std::ffi::OsString::from_vec(b"dir-\xff".to_vec()));
        fs::create_dir(&raw).unwrap();
        fs::write(raw.join("payload"), b"payload").unwrap();
        let result = measure(&[&root, &raw, &root]);
        // Duplicate candidates remain unknown so the caller can fall back to
        // the original batch command and preserve cross-operand inode rules.
        assert_eq!(result.len(), 1);
        assert_eq!(result[0].1, raw.as_os_str().as_bytes());
        assert_eq!(result[0].0.div_ceil(2), du_kib(&raw));
        let overlapping = measure(&[&root, &raw]);
        assert_eq!(overlapping.len(), 2);
        assert_eq!(overlapping[0].0.div_ceil(2), du_kib(&root));
        assert_eq!(overlapping[1].0.div_ceil(2), du_kib(&raw));
    }

    #[test]
    fn raw_blocks_explain_ordered_overlapping_du_operands() {
        let fixture = Fixture::new();
        let root = fixture.path("parent");
        let child = root.join("child");
        fs::create_dir_all(&child).unwrap();
        fs::write(child.join("payload"), vec![b'c'; 1536]).unwrap();
        fs::write(root.join("sibling"), vec![b's'; 2300]).unwrap();

        let measured = measure(&[&root, &child]);
        assert_eq!(measured.len(), 2);
        let root_blocks = fs::symlink_metadata(&root).unwrap().blocks()
            + fs::symlink_metadata(&child).unwrap().blocks()
            + fs::symlink_metadata(child.join("payload"))
                .unwrap()
                .blocks()
            + fs::symlink_metadata(root.join("sibling")).unwrap().blocks();
        let child_blocks = fs::symlink_metadata(&child).unwrap().blocks()
            + fs::symlink_metadata(child.join("payload"))
                .unwrap()
                .blocks();
        assert_eq!(
            measured[0],
            (root_blocks, root.as_os_str().as_bytes().to_vec())
        );
        assert_eq!(
            measured[1],
            (child_blocks, child.as_os_str().as_bytes().to_vec())
        );

        let operands = |paths: &[&Path]| {
            let output = Command::new("du")
                .args(["-sk", "--"])
                .args(paths)
                .output()
                .unwrap();
            assert!(output.status.success());
            String::from_utf8(output.stdout)
                .unwrap()
                .lines()
                .map(|line| {
                    let (kb, path) = line.split_once('\t').unwrap();
                    (kb.parse::<u64>().unwrap(), path.to_owned())
                })
                .collect::<Vec<_>>()
        };
        let parent_first = operands(&[&root, &child]);
        assert_eq!(parent_first.len(), 1);
        assert_eq!(parent_first[0].1, root.to_string_lossy());
        assert_eq!(parent_first[0].0, root_blocks.div_ceil(2));
        let child_first = operands(&[&child, &root]);
        assert_eq!(child_first[0].1, child.to_string_lossy());
        assert_eq!(child_first[0].0, child_blocks.div_ceil(2));
        assert_eq!(child_first[1].1, root.to_string_lossy());
        assert_eq!(child_first[1].0, (root_blocks - child_blocks).div_ceil(2));
    }

    #[test]
    fn hardlinks_make_the_whole_containing_candidate_unknown() {
        let fixture = Fixture::new();
        let root = fixture.path("root");
        fs::create_dir(&root).unwrap();
        let file = root.join("a");
        fs::write(&file, b"same inode").unwrap();
        fs::hard_link(&file, root.join("b")).unwrap();
        let clean = root.join("clean");
        fs::create_dir(&clean).unwrap();
        fs::write(clean.join("payload"), b"one ordinary inode").unwrap();
        let measured = measure(&[&root, &clean]);
        assert_eq!(measured.len(), 1);
        assert_eq!(measured[0].1, clean.as_os_str().as_bytes());
        assert_eq!(measured[0].0.div_ceil(2), du_kib(&clean));
    }

    #[test]
    fn symlink_leaves_are_counted_without_following_the_target() {
        let fixture = Fixture::new();
        let root = fixture.path("root");
        fs::create_dir(&root).unwrap();
        let target = root.join("large");
        fs::File::create(&target)
            .unwrap()
            .set_len(32 * 1024 * 1024)
            .unwrap();
        let link = root.join("link");
        symlink(&target, &link).unwrap();
        let result = measure(&[&root]);
        assert_eq!(result[0].0.div_ceil(2), du_kib(&root));
    }

    #[test]
    fn invalid_framing_produces_no_size_rows() {
        assert!(measure_batch(b"unterminated".as_slice()).is_err());
        assert!(measure(&[]).is_empty());
    }
}
