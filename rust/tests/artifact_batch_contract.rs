use std::ffi::{OsStr, OsString};
use std::fs;
use std::io::Write;
use std::os::unix::ffi::{OsStrExt, OsStringExt};
use std::os::unix::fs::symlink;
use std::path::PathBuf;
use std::process::{Command, Output, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};

static NEXT: AtomicU64 = AtomicU64::new(0);
const HEADER: &[u8] = b"diskm-artifact-children-v1";

struct Fixture {
    root: PathBuf,
    batch: PathBuf,
}

impl Fixture {
    fn new() -> Self {
        let sequence = NEXT.fetch_add(1, Ordering::Relaxed);
        let scratch = std::env::var_os("DISKM_SCRATCH_TEST_DIR")
            .map(PathBuf::from)
            .expect("tests require DISKM_SCRATCH_TEST_DIR on registered Scratch");
        let root = scratch.join(format!(
            "diskm-artifact-batch-{}-{sequence}",
            std::process::id()
        ));
        fs::create_dir(&root).expect("create owned artifact-batch fixture");
        Self {
            batch: root.join("batch.frame"),
            root,
        }
    }

    fn parent(&self, name: &str) -> PathBuf {
        let path = self.root.join(name);
        fs::create_dir_all(&path).unwrap();
        path
    }

    fn frame(&self, fields: &[&[u8]]) -> Vec<u8> {
        let mut bytes = Vec::new();
        for field in fields {
            bytes.extend_from_slice(field);
            bytes.push(0);
        }
        bytes
    }

    fn valid_frame(&self, rows: &[(&OsStr, &OsStr)]) -> Vec<u8> {
        let mut fields = vec![HEADER.to_vec(), rows.len().to_string().into_bytes()];
        for (parent, child) in rows {
            fields.push(parent.as_bytes().to_vec());
            fields.push(child.as_bytes().to_vec());
        }
        let refs = fields.iter().map(Vec::as_slice).collect::<Vec<_>>();
        self.frame(&refs)
    }

    fn invoke(&self, parents: &[OsString], frame: &[u8]) -> Output {
        let mut input = Vec::new();
        for parent in parents {
            input.extend_from_slice(parent.as_os_str().as_bytes());
            input.push(0);
        }
        self.invoke_raw(&input, frame)
    }

    fn invoke_raw(&self, input: &[u8], frame: &[u8]) -> Output {
        fs::write(&self.batch, frame).unwrap();
        let mut command = Command::new(env!("CARGO_BIN_EXE_diskm"));
        command.args(["scratch-artifact-validate"]).arg(&self.batch);
        let mut child = command
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .expect("native validator starts");
        child.stdin.take().unwrap().write_all(input).unwrap();
        child.wait_with_output().unwrap()
    }

    fn expect_rejected(&self, parents: &[OsString], frame: &[u8], reason: &str) {
        let output = self.invoke(parents, frame);
        assert_eq!(output.status.code(), Some(75));
        assert_eq!(output.stderr, format!("{reason}\n").as_bytes());
        assert!(
            output.stdout.is_empty(),
            "invalid frame emitted partial stdout"
        );
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        fs::remove_dir_all(&self.root).expect("remove only owned artifact-batch fixture");
    }
}

fn split_paths(output: &[u8]) -> Vec<&[u8]> {
    assert!(output.is_empty() || output.ends_with(b"\0"));
    output
        .split(|byte| *byte == 0)
        .filter(|part| !part.is_empty())
        .collect()
}

#[test]
fn preserves_order_and_repeated_rows() {
    let fixture = Fixture::new();
    let first = fixture.parent("parent with spaces");
    let second = fixture.parent("second parent");
    let first_child = first.join("child-a");
    let second_child = second.join("child-b");
    fs::create_dir(&first_child).unwrap();
    fs::create_dir(&second_child).unwrap();
    let submitted = [
        first.clone().into_os_string(),
        second.clone().into_os_string(),
    ];
    let frame = fixture.valid_frame(&[
        (first.as_os_str(), first_child.as_os_str()),
        (first.as_os_str(), first_child.as_os_str()),
        (second.as_os_str(), second_child.as_os_str()),
        (first.as_os_str(), first_child.as_os_str()),
    ]);
    let result = fixture.invoke(&submitted, &frame);
    assert!(
        result.status.success(),
        "{}",
        String::from_utf8_lossy(&result.stderr)
    );
    assert_eq!(
        split_paths(&result.stdout),
        vec![
            first_child.as_os_str().as_bytes(),
            first_child.as_os_str().as_bytes(),
            second_child.as_os_str().as_bytes(),
            first_child.as_os_str().as_bytes(),
        ]
    );
}

#[cfg(target_os = "linux")]
#[test]
fn preserves_non_utf8_parent_and_child_path_bytes() {
    let fixture = Fixture::new();
    let raw_parent = fixture
        .root
        .join(OsString::from_vec(b"raw-parent-\xfe".to_vec()));
    assert!(raw_parent.as_os_str().as_bytes().ends_with(&[0xfe]));
    fs::create_dir(&raw_parent).unwrap();
    let raw_child = raw_parent.join(OsString::from_vec(b"child-\xff".to_vec()));
    assert!(raw_child.as_os_str().as_bytes().ends_with(&[0xff]));
    fs::create_dir(&raw_child).unwrap();
    let frame = fixture.valid_frame(&[(raw_parent.as_os_str(), raw_child.as_os_str())]);
    let result = fixture.invoke(&[raw_parent.clone().into_os_string()], &frame);
    assert!(
        result.status.success(),
        "{}",
        String::from_utf8_lossy(&result.stderr)
    );
    assert_eq!(
        split_paths(&result.stdout),
        vec![raw_child.as_os_str().as_bytes()]
    );
}

#[test]
fn omits_vanished_children_and_rejects_wrong_types_and_symlinks() {
    let fixture = Fixture::new();
    let parent = fixture.parent("parent");
    let missing = parent.join("vanished");
    let file = parent.join("ordinary-file");
    fs::write(&file, b"file").unwrap();
    let linked = parent.join("linked-child");
    symlink(&file, &linked).unwrap();
    let submitted = [parent.clone().into_os_string()];

    let missing_output = fixture.invoke(
        &submitted,
        &fixture.valid_frame(&[(parent.as_os_str(), missing.as_os_str())]),
    );
    assert!(missing_output.status.success());
    assert!(missing_output.stdout.is_empty());

    fixture.expect_rejected(
        &submitted,
        &fixture.valid_frame(&[(parent.as_os_str(), file.as_os_str())]),
        "path-changed",
    );
    fixture.expect_rejected(
        &submitted,
        &fixture.valid_frame(&[(parent.as_os_str(), linked.as_os_str())]),
        "symlink-component",
    );
}

#[test]
fn rejects_bad_frames_and_paths_atomically() {
    let fixture = Fixture::new();
    let parent = fixture.parent("submitted");
    let child = parent.join("valid");
    fs::create_dir(&child).unwrap();
    let foreign = fixture.parent("foreign");
    let foreign_child = foreign.join("valid");
    fs::create_dir(&foreign_child).unwrap();
    let submitted = [parent.clone().into_os_string()];

    let invalid_frames: Vec<(Vec<u8>, &str)> = vec![
        (
            b"wrong-header\0".iter().chain(b"0\0").copied().collect(),
            "malformed-header",
        ),
        (
            b"diskm-artifact-children-v1\0"
                .iter()
                .chain(b"01\0")
                .copied()
                .collect(),
            "malformed-header",
        ),
        (
            b"diskm-artifact-children-v1\0"
                .iter()
                .chain(b"2\0")
                .copied()
                .collect(),
            "pair-count-mismatch",
        ),
        (
            b"diskm-artifact-children-v1\0"
                .iter()
                .chain(b"1\0parent".iter())
                .copied()
                .collect(),
            "malformed-header",
        ),
    ];
    for (frame, reason) in invalid_frames {
        fixture.expect_rejected(&submitted, &frame, reason);
    }

    let unterminated_parents =
        fixture.invoke_raw(parent.as_os_str().as_bytes(), &fixture.valid_frame(&[]));
    assert_eq!(unterminated_parents.status.code(), Some(75));
    assert_eq!(unterminated_parents.stderr, b"candidate-child-mismatch\n");
    assert!(unterminated_parents.stdout.is_empty());

    let foreign_frame = fixture.valid_frame(&[(foreign.as_os_str(), foreign_child.as_os_str())]);
    fixture.expect_rejected(&submitted, &foreign_frame, "candidate-child-mismatch");

    for (bad, reason) in [
        (parent.join("bad//component"), "invalid-child-path"),
        (parent.join("bad/../component"), "invalid-child-component"),
        (parent.join("bad/./component"), "invalid-child-component"),
        (parent.join("trailing/"), "invalid-child-path"),
    ] {
        fixture.expect_rejected(
            &submitted,
            &fixture.valid_frame(&[(parent.as_os_str(), bad.as_os_str())]),
            reason,
        );
    }

    let all_or_nothing = fixture.valid_frame(&[
        (parent.as_os_str(), child.as_os_str()),
        (foreign.as_os_str(), foreign_child.as_os_str()),
    ]);
    fixture.expect_rejected(&submitted, &all_or_nothing, "candidate-child-mismatch");
}

#[test]
fn accepts_empty_batch_and_empty_parent_stream() {
    let fixture = Fixture::new();
    let result = fixture.invoke(&[], &fixture.frame(&[HEADER, b"0"]));
    assert!(result.status.success());
    assert!(result.stdout.is_empty());
}
