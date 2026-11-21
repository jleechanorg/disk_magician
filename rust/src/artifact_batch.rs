//! Validate the complete path frame emitted by Scratch artifact discovery.
//! This hidden command performs validation only; the caller owns cleanup policy.

use std::collections::HashSet;
use std::fs;
use std::io::{self, Read, Write};
use std::os::unix::ffi::OsStrExt;
use std::path::Path;
use std::process::ExitCode;

const HEADER: &[u8] = b"diskm-artifact-children-v1";

fn framed_fields(bytes: &[u8]) -> Result<Vec<&[u8]>, &'static str> {
    if bytes.is_empty() {
        return Ok(Vec::new());
    }
    if bytes.last() != Some(&0) {
        return Err("malformed-header");
    }
    Ok(bytes[..bytes.len() - 1].split(|byte| *byte == 0).collect())
}

fn parse_count(value: &[u8]) -> Option<usize> {
    if value.is_empty()
        || !value.iter().all(u8::is_ascii_digit)
        || (value.len() > 1 && value[0] == b'0')
    {
        return None;
    }
    std::str::from_utf8(value).ok()?.parse().ok()
}

fn lexical_components(parent: &[u8], child: &[u8]) -> Result<Vec<Vec<u8>>, &'static str> {
    let mut prefix = Vec::with_capacity(parent.len() + 1);
    prefix.extend_from_slice(parent);
    prefix.push(b'/');
    let Some(relative) = child.strip_prefix(prefix.as_slice()) else {
        return Err("candidate-child-mismatch");
    };
    if relative.is_empty()
        || relative.ends_with(b"/")
        || relative.windows(2).any(|pair| pair == b"//")
    {
        return Err("invalid-child-path");
    }
    let components: Vec<Vec<u8>> = relative
        .split(|byte| *byte == b'/')
        .map(<[u8]>::to_vec)
        .collect();
    if components
        .iter()
        .any(|part| part.is_empty() || part == b"." || part == b"..")
    {
        return Err("invalid-child-component");
    }
    Ok(components)
}

enum ChildState {
    Directory,
    Vanished,
}

fn validate_child(
    parent: &[u8],
    child: &[u8],
    components: &[Vec<u8>],
) -> Result<ChildState, &'static str> {
    let parent_path = Path::new(std::ffi::OsStr::from_bytes(parent));
    let child_path = Path::new(std::ffi::OsStr::from_bytes(child));
    let mut probe = parent_path.to_path_buf();
    let mut vanished = false;

    for component in components {
        if vanished {
            continue;
        }
        probe.push(std::ffi::OsStr::from_bytes(component));
        match fs::symlink_metadata(&probe) {
            Ok(metadata) if metadata.file_type().is_symlink() => return Err("symlink-component"),
            Ok(_) => {}
            Err(error)
                if matches!(
                    error.kind(),
                    io::ErrorKind::NotFound | io::ErrorKind::NotADirectory
                ) =>
            {
                vanished = true;
            }
            Err(_) => vanished = true,
        }
    }

    if fs::symlink_metadata(parent_path).is_ok_and(|metadata| metadata.file_type().is_symlink()) {
        return Err("path-changed");
    }
    if vanished {
        return Ok(ChildState::Vanished);
    }
    match fs::symlink_metadata(child_path) {
        Ok(metadata) if metadata.file_type().is_symlink() => Err("symlink-component"),
        Ok(metadata) if metadata.is_dir() => Ok(ChildState::Directory),
        Ok(_) => Err("path-changed"),
        Err(error)
            if matches!(
                error.kind(),
                io::ErrorKind::NotFound | io::ErrorKind::NotADirectory
            ) =>
        {
            Ok(ChildState::Vanished)
        }
        Err(_) => Err("path-changed"),
    }
}

fn validate_frames(parents: &[u8], batch: &[u8]) -> Result<Vec<Vec<u8>>, &'static str> {
    let submitted = framed_fields(parents).map_err(|_| "candidate-child-mismatch")?;
    let mut parent_set = HashSet::<Vec<u8>>::with_capacity(submitted.len());
    for parent in submitted {
        if parent.is_empty() {
            return Err("candidate-child-mismatch");
        }
        parent_set.insert(parent.to_vec());
    }

    let fields = framed_fields(batch)?;
    if fields.len() < 2 || fields[0] != HEADER || parse_count(fields[1]).is_none() {
        return Err("malformed-header");
    }
    let expected = parse_count(fields[1]).ok_or("malformed-header")?;
    let pairs = &fields[2..];
    if pairs.len() % 2 != 0 || pairs.len() / 2 != expected {
        return Err("pair-count-mismatch");
    }

    let mut output = Vec::with_capacity(expected);
    for pair in pairs.chunks_exact(2) {
        let (parent, child) = (pair[0], pair[1]);
        if !parent_set.contains(parent) {
            return Err("candidate-child-mismatch");
        }
        let components = lexical_components(parent, child)?;
        if let ChildState::Directory = validate_child(parent, child, &components)? {
            output.push(child.to_vec());
        }
    }
    Ok(output)
}

pub fn validate(
    batch_file: &Path,
    mut input: impl Read,
    mut output: impl Write,
    mut stderr: impl Write,
) -> ExitCode {
    let mut submitted = Vec::new();
    if input.read_to_end(&mut submitted).is_err() {
        return fail(&mut stderr, "candidate-child-mismatch");
    }
    let mut batch = Vec::new();
    if fs::File::open(batch_file)
        .and_then(|mut file| file.read_to_end(&mut batch))
        .is_err()
    {
        return fail(&mut stderr, "malformed-header");
    }
    let validated = match validate_frames(&submitted, &batch) {
        Ok(validated) => validated,
        Err(reason) => return fail(&mut stderr, reason),
    };
    for path in validated {
        if output.write_all(&path).is_err() || output.write_all(b"\0").is_err() {
            return ExitCode::FAILURE;
        }
    }
    ExitCode::SUCCESS
}

fn fail(stderr: &mut impl Write, reason: &str) -> ExitCode {
    let _ = writeln!(stderr, "{reason}");
    ExitCode::from(75)
}
