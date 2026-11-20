use serde_json::Value;
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;
use std::process::{Command, Output};
use std::sync::atomic::{AtomicU64, Ordering};

static NEXT: AtomicU64 = AtomicU64::new(0);

struct Fixture {
    root: PathBuf,
    bin: PathBuf,
    calls: PathBuf,
}

impl Fixture {
    fn new() -> Self {
        let root = std::env::temp_dir().join(format!(
            "worktree-preview-contract-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir(&root).expect("create isolated fixture");
        let bin = root.join("bin");
        fs::create_dir(&bin).expect("create fake binary directory");
        Self {
            calls: root.join("calls"),
            root,
            bin,
        }
    }

    fn diskm(&self, body: &str) {
        let script = self.bin.join("diskm");
        fs::write(
            &script,
            format!("#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"$CALLS\"\n{body}\n"),
        )
        .unwrap();
        let mut mode = fs::metadata(&script).unwrap().permissions();
        mode.set_mode(0o755);
        fs::set_permissions(script, mode).unwrap();
    }

    fn run(&self) -> Output {
        let path = std::env::join_paths(std::iter::once(self.bin.clone()).chain(
            std::env::split_paths(&std::env::var_os("PATH").unwrap_or_default()),
        ))
        .unwrap();
        Command::new(env!("CARGO_BIN_EXE_diskm-rust"))
            .args(["preview", "--scope", "worktrees", "--dry-run"])
            .env("PATH", path)
            .env("CALLS", &self.calls)
            .env("WORKTREE_APPROVED", "1")
            .env("MANUAL_DISCARD", "1")
            .env("MANUAL_INCLUDE_LIVE", "1")
            .env("DISK_MAGICIAN_WORKTREE_FLOOR_HOURS", "12")
            .env("DISK_MAGICIAN_AGE_FLOOR_MINUTES", "360")
            .env(
                "DISK_MAGICIAN_OPERATOR_TARGETS",
                "/Users/test/.worktrees/app/target",
            )
            .output()
            .expect("candidate executable starts")
    }

    fn calls(&self) -> String {
        fs::read_to_string(&self.calls).unwrap_or_default()
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        fs::remove_dir_all(&self.root).expect("remove owned fixture");
    }
}

fn report(output: &Output) -> Value {
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    serde_json::from_slice(&output.stdout).expect("worktree preview emits JSON")
}

#[test]
fn preliminary_row_parses_pipe_in_path_from_canonical_age_suffix() {
    let fixture = Fixture::new();
    fixture.diskm(
        r#"printf 'LEDGER repo-local ELIGIBLE /Users/test/.worktrees/app/branch | name | age=4 days size=2.0G head=12345678 branch=feature/name\n'"#,
    );

    let result = report(&fixture.run());
    assert_eq!(result["command_complete"], true);
    assert_eq!(result["candidates"].as_array().unwrap().len(), 1);
    assert_eq!(result["candidates"][0]["disposition"], "preliminary");
    assert_eq!(
        result["candidates"][0]["path"],
        "/Users/test/.worktrees/app/branch | name"
    );
    assert!(result["candidates"][0]["reason"].is_null());
    assert_eq!(fixture.calls(), "cleanup-worktrees --dry-run\n");
}

#[test]
fn preserve_reason_and_path_pipe_are_parsed_without_truncating_the_path() {
    let fixture = Fixture::new();
    fixture.diskm(
        r#"printf 'LEDGER repo-local PRESERVE /Users/test/.worktrees/app/old | branch | live-cwd | age=4 days size=2.0G head=12345678 branch=main\n'"#,
    );

    let result = report(&fixture.run());
    assert_eq!(result["command_complete"], true);
    assert_eq!(result["candidates"].as_array().unwrap().len(), 1);
    assert_eq!(result["candidates"][0]["disposition"], "preserve");
    assert_eq!(
        result["candidates"][0]["path"],
        "/Users/test/.worktrees/app/old | branch"
    );
    assert_eq!(result["candidates"][0]["reason"], "live-cwd");
}

#[test]
fn other_worktree_scopes_are_not_mislabelled() {
    let fixture = Fixture::new();
    fixture.diskm(
        r#"printf 'LEDGER antigravity PRESERVE /Users/test/.gemini/antigravity/worktrees/old | young | age=4 days size=2.0G head=12345678 branch=main\n'"#,
    );

    let result = report(&fixture.run());
    assert_eq!(result["candidates"].as_array().unwrap().len(), 0);
    assert_eq!(result["command_complete"], true);
}

#[test]
fn malformed_repo_local_row_makes_coverage_incomplete() {
    let fixture = Fixture::new();
    fixture.diskm(r#"printf 'LEDGER repo-local ELIGIBLE relative/path | age=3 days size=1G head=12345678 branch=main\n'"#);

    let result = report(&fixture.run());
    assert_eq!(result["command_complete"], false);
    assert_eq!(result["candidates"].as_array().unwrap().len(), 0);
    assert_eq!(result["unparsed_ledger_rows"].as_array().unwrap().len(), 1);
}

#[test]
fn nonzero_cleaner_result_never_becomes_complete_or_deletion_eligible() {
    let fixture = Fixture::new();
    fixture.diskm(
        r#"printf 'LEDGER repo-local ELIGIBLE /Users/test/.worktrees/app/candidate | age=3 days size=1G head=12345678 branch=main\n'; exit 7"#,
    );

    let result = report(&fixture.run());
    assert_eq!(result["command_complete"], false);
    assert_eq!(result["exit_code"], 7);
    assert_eq!(result["candidates"][0]["disposition"], "preliminary");
    assert!(result["candidates"][0]["reason"].is_null());
}

#[test]
fn mutation_approval_and_lower_age_overrides_are_scrubbed_before_dry_run() {
    let fixture = Fixture::new();
    fixture.diskm(
        r#"for key in WORKTREE_APPROVED MANUAL_DISCARD MANUAL_INCLUDE_LIVE DISK_MAGICIAN_WORKTREE_FLOOR_HOURS DISK_MAGICIAN_AGE_FLOOR_MINUTES DISK_MAGICIAN_OPERATOR_TARGETS; do printf '%s=' "$key"; printenv "$key" || printf 'unset'; printf '|'; done > "$CALLS.env"; printf 'done\n'"#,
    );

    let result = report(&fixture.run());
    assert_eq!(result["command_complete"], true);
    assert_eq!(
        fs::read_to_string(fixture.root.join("calls.env")).unwrap(),
        "WORKTREE_APPROVED=unset|MANUAL_DISCARD=unset|MANUAL_INCLUDE_LIVE=unset|DISK_MAGICIAN_WORKTREE_FLOOR_HOURS=unset|DISK_MAGICIAN_AGE_FLOOR_MINUTES=unset|DISK_MAGICIAN_OPERATOR_TARGETS=unset|"
    );
}
