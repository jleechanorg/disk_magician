use std::collections::{HashMap, HashSet};
use std::fs;
use std::io::{self, Read};
use std::os::unix::ffi::{OsStrExt, OsStringExt};
use std::path::{Component, Path, PathBuf};
use std::process::{Command, Stdio};

fn parse_paths(input: impl Read) -> io::Result<Vec<PathBuf>> {
    let mut bytes = Vec::new();
    input.take(usize::MAX as u64).read_to_end(&mut bytes)?;
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
    if bytes.is_empty() || bytes.split(|b| *b == 0).any(|part| part.is_empty()) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "invalid NUL path list",
        ));
    }
    Ok(bytes
        .split(|b| *b == 0)
        .map(|part| PathBuf::from(std::ffi::OsString::from_vec(part.to_vec())))
        .collect())
}

fn supported_path(path: &Path) -> bool {
    let raw = path.as_os_str().as_bytes();
    if std::str::from_utf8(raw).is_err()
        || raw.iter().any(u8::is_ascii_control)
        || !path.is_absolute()
    {
        return false;
    }
    let mut canonical = PathBuf::new();
    for component in path.components() {
        match component {
            Component::RootDir => canonical.push("/"),
            Component::Normal(part) => canonical.push(part),
            _ => return false,
        }
    }
    canonical.as_os_str().as_bytes() == raw
}

fn valid_directory(path: &Path) -> bool {
    fs::symlink_metadata(path)
        .map(|m| m.is_dir() && !m.file_type().is_symlink())
        .unwrap_or(false)
}

fn safe_gap(ancestor: &Path, descendant: &Path) -> bool {
    let Ok(relative) = descendant.strip_prefix(ancestor) else {
        return false;
    };
    let components: Vec<_> = relative.components().collect();
    if components.is_empty() {
        return false;
    }
    let mut current = ancestor.to_path_buf();
    for component in components.iter().take(components.len() - 1) {
        let Component::Normal(name) = component else {
            return false;
        };
        current.push(name);
        if !valid_directory(&current) {
            return false;
        }
    }
    true
}

fn du_group(top_roots: &[PathBuf], minimum_kb: u64) -> bool {
    let mut command = Command::new("du");
    command
        .args(["-0skl", "--"])
        .args(top_roots)
        .stderr(Stdio::null());
    let Ok(output) = command.output() else {
        return false;
    };
    if !output.status.success() {
        return false;
    }
    let Some(payload) = output.stdout.strip_suffix(&[0]) else {
        return false;
    };
    let rows: Vec<_> = payload.split(|b| *b == 0).collect();
    if rows.len() != top_roots.len() || rows.iter().any(|row| row.is_empty()) {
        return false;
    }
    let mut seen = HashSet::with_capacity(rows.len());
    for row in rows {
        let Some(tab) = row.iter().position(|b| *b == b'\t') else {
            return false;
        };
        let Ok(size) = std::str::from_utf8(&row[..tab])
            .unwrap_or("")
            .parse::<u64>()
        else {
            return false;
        };
        let raw_path = &row[tab + 1..];
        if !top_roots
            .iter()
            .any(|p| p.as_os_str().as_bytes() == raw_path)
            || !seen.insert(raw_path.to_vec())
            || size >= minimum_kb
        {
            return false;
        }
    }
    seen.len() == top_roots.len()
}

/// Return submitted directories certified strictly below the threshold.
pub fn measure_batch(input: impl Read, minimum_kb: u64) -> io::Result<Vec<u8>> {
    let submitted = parse_paths(input)?;
    let mut occurrences = HashMap::<PathBuf, usize>::new();
    for path in &submitted {
        *occurrences.entry(path.clone()).or_default() += 1;
    }
    let repeated: HashSet<_> = occurrences
        .into_iter()
        .filter_map(|(path, count)| (count > 1).then_some(path))
        .collect();
    let eligible: Vec<_> = submitted
        .into_iter()
        .filter(|path| valid_directory(path))
        .collect();

    let mut output = Vec::new();
    for group in eligible.chunks(200) {
        if group.iter().any(|path| !supported_path(path)) {
            continue;
        }
        let mut unique = HashSet::with_capacity(group.len());
        if group
            .iter()
            .any(|path| repeated.contains(path) || !unique.insert(path.clone()))
        {
            continue;
        }
        let mut top_roots = Vec::new();
        let mut has_overlap = false;
        for path in group {
            let mut ancestor = path.parent();
            let mut covered = false;
            while let Some(parent) = ancestor {
                if unique.contains(parent) {
                    covered = true;
                    has_overlap = true;
                    break;
                }
                ancestor = parent.parent();
            }
            if !covered {
                top_roots.push(path.clone());
            }
        }
        let safe_coverage = group.iter().all(|path| {
            unique
                .iter()
                .filter(|candidate| path != *candidate && path.starts_with(candidate))
                .max_by_key(|candidate| candidate.components().count())
                .is_none_or(|ancestor| safe_gap(ancestor, path))
        });
        if !has_overlap || !safe_coverage || !du_group(&top_roots, minimum_kb) {
            continue;
        }
        for path in group {
            output.extend_from_slice(path.as_os_str().as_bytes());
            output.push(0);
        }
    }
    Ok(output)
}

#[cfg(all(test, target_os = "linux"))]
mod tests {
    use super::*;
    use std::os::unix::fs::symlink;
    use std::sync::atomic::{AtomicU64, Ordering};
    static NEXT: AtomicU64 = AtomicU64::new(0);

    struct Fixture(PathBuf);
    impl Fixture {
        fn new() -> Self {
            let scratch = std::env::var_os("DISKM_SCRATCH_TEST_DIR")
                .map(PathBuf::from)
                .expect("tests require registered Scratch");
            let root = fs::canonicalize(scratch).unwrap().join(format!(
                "artifact-size-pilot-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
            fs::create_dir(&root).unwrap();
            Self(root)
        }
        fn path(&self, name: &str) -> PathBuf {
            self.0.join(name)
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }
    fn framed(paths: &[&Path]) -> Vec<u8> {
        paths
            .iter()
            .flat_map(|path| path.as_os_str().as_bytes().iter().copied().chain([0]))
            .collect()
    }
    fn rows(bytes: &[u8]) -> Vec<Vec<u8>> {
        bytes
            .split(|b| *b == 0)
            .filter(|p| !p.is_empty())
            .map(<[u8]>::to_vec)
            .collect()
    }
    fn du_kb(paths: &[&Path]) -> Vec<(u64, Vec<u8>)> {
        let output = Command::new("du")
            .args(["-0skl", "--"])
            .args(paths)
            .output()
            .unwrap();
        assert!(output.status.success());
        output
            .stdout
            .split(|b| *b == 0)
            .filter(|r| !r.is_empty())
            .map(|r| {
                let tab = r.iter().position(|b| *b == b'\t').unwrap();
                (
                    std::str::from_utf8(&r[..tab]).unwrap().parse().unwrap(),
                    r[tab + 1..].to_vec(),
                )
            })
            .collect()
    }

    #[test]
    fn overlap_hardlinks_and_strict_cutoff_match_gnu_du() {
        let f = Fixture::new();
        let parent = f.path("parent");
        let child = parent.join("child");
        fs::create_dir_all(&child).unwrap();
        fs::write(child.join("one"), vec![b'x'; 1024]).unwrap();
        fs::hard_link(child.join("one"), child.join("two")).unwrap();
        let independent = f.path("independent");
        fs::create_dir(&independent).unwrap();
        fs::write(independent.join("payload"), b"small").unwrap();
        let paths = [parent.as_path(), child.as_path(), independent.as_path()];
        let du = du_kb(&[&parent, &independent]);
        assert_eq!(du.len(), 2);
        let cutoff = du.iter().map(|row| row.0).max().unwrap();
        assert!(rows(&measure_batch(framed(&paths).as_slice(), cutoff).unwrap()).is_empty());
        let output = measure_batch(framed(&paths).as_slice(), cutoff + 1).unwrap();
        assert_eq!(
            rows(&output),
            paths
                .iter()
                .map(|p| p.as_os_str().as_bytes().to_vec())
                .collect::<Vec<_>>()
        );
    }

    #[test]
    fn symlink_intermediate_invalidates_overlapping_group() {
        let f = Fixture::new();
        let parent = f.path("parent");
        let external = f.path("external");
        let child = external.join("child");
        fs::create_dir_all(&child).unwrap();
        fs::create_dir(&parent).unwrap();
        symlink(&external, parent.join("alias")).unwrap();
        assert!(measure_batch(
            framed(&[&parent, &parent.join("alias/child")]).as_slice(),
            u64::MAX
        )
        .unwrap()
        .is_empty());
    }

    #[test]
    fn independent_and_unsupported_paths_produce_no_hints() {
        let f = Fixture::new();
        let one = f.path("one");
        let two = f.path("two");
        fs::create_dir(&one).unwrap();
        fs::create_dir(&two).unwrap();
        assert!(measure_batch(framed(&[&one, &two]).as_slice(), u64::MAX)
            .unwrap()
            .is_empty());
        let raw = f.0.join(std::ffi::OsString::from_vec(b"raw-\xff".to_vec()));
        fs::create_dir(&raw).unwrap();
        let sym = f.path("sym");
        symlink(&one, &sym).unwrap();
        assert!(measure_batch(
            framed(&[&raw, &one, &one.join("missing"), &sym]).as_slice(),
            u64::MAX
        )
        .unwrap()
        .is_empty());
    }
}
