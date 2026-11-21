//! Native producer and frame validator for generic Scratch artifact discovery.
//! The caller retains the legacy C14 lease, protection, and actuator checks.

use crate::history::parse_utc;
use crate::preview::possible_dated_run;
use std::fs::{self, OpenOptions};
use std::io::{self, Read, Write};
use std::os::unix::ffi::{OsStrExt, OsStringExt};
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::time::Instant;

const MARKER: &[u8] = b"diskm-artifact-children-v1";

#[derive(Debug)]
pub enum DiscoveryError {
    MalformedInput,
    Deadline,
    Io(io::Error),
}

impl DiscoveryError {
    pub fn reason(&self) -> &'static str {
        match self {
            Self::MalformedInput => "malformed-input",
            Self::Deadline => "deadline",
            Self::Io(_) => "unmeasurable",
        }
    }
}

impl From<io::Error> for DiscoveryError {
    fn from(error: io::Error) -> Self {
        Self::Io(error)
    }
}

fn expired(deadline: Option<Instant>) -> bool {
    deadline.is_some_and(|deadline| Instant::now() >= deadline)
}

fn parse_roots(mut input: impl Read) -> Result<Vec<PathBuf>, DiscoveryError> {
    let mut bytes = Vec::new();
    input.read_to_end(&mut bytes)?;
    if bytes.is_empty() {
        return Ok(Vec::new());
    }
    if bytes.last() != Some(&0) {
        return Err(DiscoveryError::MalformedInput);
    }
    bytes.pop();
    if bytes.is_empty() || bytes.split(|byte| *byte == 0).any(|part| part.is_empty()) {
        return Err(DiscoveryError::MalformedInput);
    }
    Ok(bytes
        .split(|byte| *byte == 0)
        .map(|value| PathBuf::from(std::ffi::OsString::from_vec(value.to_vec())))
        .collect())
}

fn exists_nofollow(path: &Path) -> io::Result<bool> {
    match fs::symlink_metadata(path) {
        Ok(_) => Ok(true),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(false),
        Err(error) => Err(error),
    }
}

fn has_git_marker(path: &Path) -> io::Result<bool> {
    if exists_nofollow(&path.join(".git"))? {
        return Ok(true);
    }
    // A bare repository has all three root markers. Metadata is never traversed.
    for marker in ["HEAD", "objects", "refs"] {
        if !exists_nofollow(&path.join(marker))? {
            return Ok(false);
        }
    }
    Ok(true)
}

fn is_managed_run(root: &Path, path: &Path) -> io::Result<bool> {
    let run_roots = [root.to_path_buf(), root.join("runs")];
    let run_shape = run_roots
        .iter()
        .any(|runs| possible_dated_run(runs, path).is_some());
    if !run_shape {
        return Ok(false);
    }
    let relative = path
        .strip_prefix(root)
        .map_err(|_| io::Error::other("managed run escaped discovery root"))?;
    let mut components: Vec<_> = relative
        .components()
        .map(|component| component.as_os_str().as_bytes())
        .collect();
    if components
        .first()
        .is_some_and(|component| *component == b"runs")
    {
        components.remove(0);
    }
    if components.len() != 3 {
        return Ok(false);
    }
    let day = std::str::from_utf8(components[0])
        .map_err(|_| io::Error::other("invalid managed run date encoding"))?;
    if day.len() != 8 || !day.bytes().all(|byte| byte.is_ascii_digit()) {
        return Ok(false);
    }
    // Use the canonical UTC date parser for calendar validation.
    let iso_day = format!("{}-{}-{}", &day[0..4], &day[4..6], &day[6..8]);
    if parse_utc(&format!("{iso_day}T00:00:00Z")).is_none() {
        return Ok(false);
    }
    let run = match fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(_) => return Ok(false),
    };
    let marker_path = path.parent().unwrap_or(path).join(".dm-quarantine");
    let marker = match fs::symlink_metadata(marker_path) {
        Ok(metadata) => metadata,
        Err(_) => return Ok(false),
    };
    Ok(run.is_dir()
        && !run.file_type().is_symlink()
        && marker.is_dir()
        && !marker.file_type().is_symlink()
        && marker.uid() == unsafe { libc::geteuid() }
        && marker.mode() & 0o7777 == 0o700)
}

// Python str(os.fsdecode(path)) compares Unicode scalar values and maps each
// undecodable byte to U+DC00..U+DCFF. Reproduce that order for traversal.
fn python_path_sort_key(path: &Path) -> Vec<u32> {
    let mut remaining = path.as_os_str().as_bytes();
    let mut key = Vec::new();
    while !remaining.is_empty() {
        match std::str::from_utf8(remaining) {
            Ok(text) => {
                key.extend(text.chars().map(u32::from));
                break;
            }
            Err(error) => {
                let valid = error.valid_up_to();
                if valid > 0 {
                    key.extend(
                        std::str::from_utf8(&remaining[..valid])
                            .unwrap()
                            .chars()
                            .map(u32::from),
                    );
                }
                let count = error.error_len().unwrap_or(remaining.len() - valid);
                for byte in &remaining[valid..valid + count] {
                    key.push(0xdc00 + u32::from(*byte));
                }
                remaining = &remaining[valid + count..];
            }
        }
    }
    key
}

fn discover_root(root: &Path, deadline: Option<Instant>) -> Result<Vec<PathBuf>, DiscoveryError> {
    let root_info = fs::symlink_metadata(root)?;
    if !root_info.is_dir() || root_info.file_type().is_symlink() {
        return Err(io::Error::other("submitted root is not a real directory").into());
    }
    if has_git_marker(root)? {
        return Ok(Vec::new());
    }

    let mut results = Vec::new();
    let mut pending = vec![root.to_path_buf()];
    while let Some(parent) = pending.pop() {
        if expired(deadline) {
            return Err(DiscoveryError::Deadline);
        }
        if has_git_marker(&parent)? {
            continue;
        }

        let entries = fs::read_dir(&parent)?;
        let mut child_directories = Vec::new();
        for entry in entries {
            if expired(deadline) {
                return Err(DiscoveryError::Deadline);
            }
            let entry = entry?;
            let name = entry.file_name();
            if name.as_bytes().starts_with(b".") {
                continue;
            }

            let child = entry.path();
            let metadata = fs::symlink_metadata(&child)?;
            if !metadata.is_dir()
                || metadata.file_type().is_symlink()
                || metadata.dev() != root_info.dev()
            {
                continue;
            }
            results.push(child.clone());
            if !has_git_marker(&child)? && !is_managed_run(root, &child)? {
                child_directories.push(child);
            }
        }
        child_directories.sort_by_key(|child| python_path_sort_key(child));
        pending.extend(child_directories.into_iter().rev());
    }
    Ok(results)
}

/// Consume the submitted roots and write blocked roots as a NUL list.
/// Candidate output is returned only after every root was fully processed.
pub fn discover_batch(
    input: impl Read,
    blocked_out: &Path,
    deadline: Option<Instant>,
) -> Result<Vec<u8>, DiscoveryError> {
    let roots = parse_roots(input)?;
    let mut blocked = Vec::new();
    let mut pairs = Vec::new();
    for root in roots {
        if expired(deadline) {
            return Err(DiscoveryError::Deadline);
        }
        let root_bytes = root.as_os_str().as_bytes().to_vec();
        match discover_root(&root, deadline) {
            Ok(children) => pairs.extend(
                children
                    .into_iter()
                    .map(|child| (root_bytes.clone(), child.as_os_str().as_bytes().to_vec())),
            ),
            Err(DiscoveryError::Deadline) => return Err(DiscoveryError::Deadline),
            Err(DiscoveryError::MalformedInput) => return Err(DiscoveryError::MalformedInput),
            Err(DiscoveryError::Io(_)) => blocked.push(root_bytes),
        }
    }

    let mut frame = Vec::new();
    frame.extend_from_slice(MARKER);
    frame.push(0);
    frame.extend_from_slice(pairs.len().to_string().as_bytes());
    frame.push(0);
    for (parent, child) in pairs {
        frame.extend_from_slice(&parent);
        frame.push(0);
        frame.extend_from_slice(&child);
        frame.push(0);
    }
    let mut blocked_file = OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .open(blocked_out)?;
    for root in blocked {
        blocked_file.write_all(&root)?;
        blocked_file.write_all(&[0])?;
    }
    blocked_file.flush()?;
    Ok(frame)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;
    use std::time::SystemTime;

    struct Fixture(PathBuf);

    impl Fixture {
        fn new(label: &str) -> Self {
            let base = std::env::var_os("DISKM_SCRATCH_TEST_DIR")
                .map(PathBuf::from)
                .expect("tests run on the configured Scratch volume");
            let base = fs::canonicalize(base).unwrap();
            let root = base.join(format!(
                "artifact-discovery-{label}-{}-{}",
                std::process::id(),
                SystemTime::now()
                    .duration_since(SystemTime::UNIX_EPOCH)
                    .unwrap()
                    .as_nanos()
            ));
            fs::create_dir_all(&root).unwrap();
            Self(root)
        }
        fn path(&self, child: &str) -> PathBuf {
            self.0.join(child)
        }
        fn roots(paths: &[&Path]) -> Vec<u8> {
            let mut output = Vec::new();
            for path in paths {
                output.extend_from_slice(path.as_os_str().as_bytes());
                output.push(0);
            }
            output
        }
        fn run(&self, roots: &[&Path]) -> Result<Vec<u8>, DiscoveryError> {
            discover_batch(
                Self::roots(roots).as_slice(),
                &self.path("blocked.roots"),
                None,
            )
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }
    fn frame_fields(frame: &[u8]) -> Vec<&[u8]> {
        assert_eq!(frame.last(), Some(&0));
        frame[..frame.len() - 1].split(|byte| *byte == 0).collect()
    }

    #[test]
    fn preserves_git_boundaries_and_hidden_names() {
        let fixture = Fixture::new("boundaries");
        let root = fixture.path("root");
        fs::create_dir(&root).unwrap();
        let alpha = root.join("alpha");
        let zeta = root.join("zeta");
        let repo = root.join("repo");
        let bare = root.join("bare");
        let hidden = root.join(".hidden");
        fs::create_dir_all(alpha.join("build")).unwrap();
        fs::create_dir_all(zeta.join("cache")).unwrap();
        fs::create_dir_all(repo.join(".git")).unwrap();
        fs::create_dir_all(bare.join("objects")).unwrap();
        fs::create_dir_all(bare.join("refs")).unwrap();
        fs::write(bare.join("HEAD"), b"ref: refs/heads/main").unwrap();
        fs::create_dir_all(hidden.join("child")).unwrap();
        let frame = fixture.run(&[&root]).unwrap();
        let fields = frame_fields(&frame);
        assert_eq!(fields[0], MARKER);
        let pair_count = std::str::from_utf8(fields[1])
            .unwrap()
            .parse::<usize>()
            .unwrap();
        assert_eq!(pair_count, (fields.len() - 2) / 2);
        let emitted: Vec<_> = fields[2..].chunks_exact(2).map(|pair| pair[1]).collect();
        assert!(emitted.contains(&repo.as_os_str().as_bytes()));
        assert!(!emitted.contains(&repo.join(".git").as_os_str().as_bytes()));
        assert!(emitted.contains(&bare.as_os_str().as_bytes()));
        assert!(!emitted.contains(&bare.join("objects").as_os_str().as_bytes()));
        assert!(!emitted
            .iter()
            .any(|path| path.starts_with(hidden.as_os_str().as_bytes())));
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn discovery_preserves_non_utf8_filesystem_paths() {
        let fixture = Fixture::new("non-utf8");
        let root = fixture.path("root");
        fs::create_dir(&root).unwrap();
        let odd = root.join(std::ffi::OsString::from_vec(b"odd\xff".to_vec()));
        fs::create_dir_all(odd.join("child")).unwrap();
        let frame = fixture.run(&[&root]).unwrap();
        let fields = frame_fields(&frame);
        let emitted: Vec<_> = fields[2..].chunks_exact(2).map(|pair| pair[1]).collect();
        assert!(emitted.contains(&odd.as_os_str().as_bytes()));
        assert!(emitted.contains(&odd.join("child").as_os_str().as_bytes()));
    }

    #[test]
    fn surrogateescape_sort_key_orders_mixed_names_without_filesystem_support() {
        let base = Path::new("/scratch/root");
        let invalid = base.join(std::ffi::OsString::from_vec(vec![0x80]));
        let unicode = base.join(std::char::from_u32(0xe000).unwrap().to_string());
        assert!(python_path_sort_key(&invalid) < python_path_sort_key(&unicode));
        let mut observed = vec![unicode, invalid];
        observed.sort_by_key(|path| python_path_sort_key(path));
        assert!(observed[0].as_os_str().as_bytes().ends_with(&[0x80]));
        assert!(observed[1]
            .as_os_str()
            .as_bytes()
            .ends_with(&[0xee, 0x80, 0x80]));
    }

    #[test]
    fn allocator_run_is_emitted_as_one_unit() {
        let fixture = Fixture::new("managed-run");
        let root = fixture.path("root");
        let run = root.join("runs/20261121/example/evidence-20261121T123456Z-123-456");
        fs::create_dir_all(run.join("nested")).unwrap();
        let marker = run.parent().unwrap().join(".dm-quarantine");
        fs::create_dir(&marker).unwrap();
        fs::set_permissions(&marker, fs::Permissions::from_mode(0o700)).unwrap();
        let frame = fixture.run(&[&root]).unwrap();
        let emitted: Vec<_> = frame_fields(&frame)[2..]
            .chunks_exact(2)
            .map(|pair| pair[1])
            .collect();
        assert!(emitted.contains(&run.as_os_str().as_bytes()));
        assert!(!emitted.contains(&run.join("nested").as_os_str().as_bytes()));
    }

    #[test]
    fn blocked_roots_and_global_malformed_or_expired_calls_are_distinct() {
        let fixture = Fixture::new("errors");
        let absent = fixture.path("absent");
        let good = fixture.path("good");
        fs::create_dir_all(good.join("child")).unwrap();
        let result = fixture.run(&[&absent, &good]).unwrap();
        assert_eq!(std::str::from_utf8(frame_fields(&result)[1]).unwrap(), "1");
        assert_eq!(
            fs::read(fixture.path("blocked.roots")).unwrap(),
            [absent.as_os_str().as_bytes(), b"\0"].concat()
        );
        assert!(matches!(
            discover_batch(b"not-nul-framed".as_slice(), &fixture.path("bad"), None),
            Err(DiscoveryError::MalformedInput)
        ));
        assert!(matches!(
            discover_batch(
                Fixture::roots(&[&good]).as_slice(),
                &fixture.path("late"),
                Some(Instant::now())
            ),
            Err(DiscoveryError::Deadline)
        ));
    }
}
