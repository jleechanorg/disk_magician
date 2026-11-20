use diskm_shadow::preview_scopes::{
    canonical_temp_scopes, read_ledger, temp_policy_preview_command, RootScope, RootSource,
};
use serde_json::json;
use std::fs;
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

static FIXTURE_ID: AtomicU64 = AtomicU64::new(0);

struct Fixture(PathBuf);

impl Fixture {
    fn new() -> Self {
        let path = std::env::temp_dir().join(format!(
            "diskm-preview-scopes-{}-{}",
            std::process::id(),
            FIXTURE_ID.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir(&path).unwrap();
        Self(fs::canonicalize(path).unwrap())
    }

    fn ledger(&self, value: serde_json::Value) -> PathBuf {
        let state = self.0.join("state");
        let ledger = state.join("reclaim/directory-ledger.json");
        fs::create_dir_all(ledger.parent().unwrap()).unwrap();
        fs::write(&ledger, serde_json::to_vec(&value).unwrap()).unwrap();
        state
    }

    fn executable(&self, name: &str, script: &str) -> PathBuf {
        let path = self.0.join(name);
        fs::write(&path, script).unwrap();
        let mut permissions = fs::metadata(&path).unwrap().permissions();
        permissions.set_mode(0o755);
        fs::set_permissions(&path, permissions).unwrap();
        path
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        fs::remove_dir_all(&self.0).unwrap();
    }
}

#[test]
fn host_temp_roots_are_canonical_deduplicated_and_scratch_device_excluded() {
    let fixture = Fixture::new();
    let target = fixture.0.join("tmp-root");
    fs::create_dir(&target).unwrap();
    let alias = fixture.0.join("tmp-alias");
    std::os::unix::fs::symlink(&target, &alias).unwrap();
    let scratch_device = fs::metadata(&fixture.0).unwrap().dev();

    let roots = canonical_temp_scopes(
        vec![
            RootScope {
                path: alias,
                source: RootSource::PrivateTmp,
            },
            RootScope {
                path: target.clone(),
                source: RootSource::Tmp,
            },
            RootScope {
                path: fixture.0.join("missing"),
                source: RootSource::UserTmp,
            },
            RootScope {
                path: PathBuf::from("/"),
                source: RootSource::Tmp,
            },
        ],
        Some(scratch_device.wrapping_add(1)),
    )
    .unwrap();

    assert_eq!(
        roots.len(),
        1,
        "symlink aliases and invalid roots are excluded"
    );
    assert_eq!(roots[0].path, fs::canonicalize(target).unwrap());
    assert_eq!(roots[0].source, RootSource::PrivateTmp);

    let excluded = canonical_temp_scopes(roots, Some(scratch_device)).unwrap();
    assert!(
        excluded.is_empty(),
        "roots on Scratch's device are excluded"
    );
}

#[test]
fn ledger_summary_preserves_exact_paths_and_patterns_as_non_authoritative_hints() {
    let fixture = Fixture::new();
    let state = fixture.ledger(json!({
        "rows": [
            {"row_type":"cleanup_event","canonical_path":"/tmp/old-file.cache"},
            {"row_type":"cleanup_root","canonical_path":"/tmp/agent-scratch"},
            {"row_type":"pattern","canonical_path":"/Users/jlee/worktree_*"},
            {"row_type":"directory","canonical_path":"/tmp/observed-only"}
        ]
    }));

    let summary = read_ledger(&state).unwrap();
    assert_eq!(summary.rows.len(), 3);
    assert_eq!(summary.rows[0].row_type, "cleanup_event");
    assert_eq!(
        summary.rows[0].canonical_path.as_deref(),
        Some(Path::new("/tmp/old-file.cache"))
    );
    assert_eq!(summary.rows[1].row_type, "cleanup_root");
    assert_eq!(summary.rows[2].row_type, "pattern");
    assert_eq!(
        summary.rows[2].canonical_path.as_deref(),
        Some(Path::new("/Users/jlee/worktree_*"))
    );
}

#[test]
fn ledger_summary_fails_closed_for_malformed_json() {
    let fixture = Fixture::new();
    let state = fixture.ledger(json!({"rows":[]}));
    fs::write(state.join("reclaim/directory-ledger.json"), b"{invalid").unwrap();
    assert!(read_ledger(&state).is_err());
}

#[test]
fn temp_policy_preview_runs_only_the_canonical_dry_run_and_bounds_output() {
    let fixture = Fixture::new();
    let log = fixture.0.join("argv.log");
    let executable = fixture.executable(
        "diskm",
        &format!(
            "#!/usr/bin/env python3\nimport os,sys\nopen({:?},'w').write('|'.join(sys.argv[1:])+'|'+os.environ.get('DISK_MAGICIAN_AGE_FLOOR_MINUTES','unset')+'|'+os.environ.get('DISK_MAGICIAN_RECEIPT_TRIGGER','unset'))\nsys.stdout.write('x'*300000)\n",
            log.display().to_string()
        ),
    );
    let report = temp_policy_preview_command(&executable).unwrap();

    assert_eq!(
        report.command,
        vec![
            executable.to_string_lossy().into_owned(),
            "cleanup-tmp".to_owned(),
            "--dry-run".to_owned()
        ]
    );
    assert_eq!(report.status, Some(0));
    assert!(!report.timed_out);
    assert!(report.truncated);
    assert!(report.output.len() <= 256 * 1024);
    assert_eq!(
        fs::read_to_string(log).unwrap(),
        "cleanup-tmp|--dry-run||rust-preview"
    );
    assert!(report.may_write_job_receipt);
    assert_eq!(report.receipt_trigger, "rust-preview");
}
