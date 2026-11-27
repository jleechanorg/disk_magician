use diskm_shadow::scan::{self, AgeKind, ScanOptions};
use diskm_shadow::scratch_index::{AgeTimeField, Query, ScratchIndex};
use rusqlite::Connection;
use serde_json::Value;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

struct TempDir(PathBuf);

impl TempDir {
    fn new(label: &str) -> Self {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let path = fs::canonicalize(std::env::temp_dir())
            .unwrap()
            .join(format!(
                "diskm-scratch-index-test-{label}-{}-{nanos}",
                std::process::id()
            ));
        fs::create_dir_all(&path).unwrap();
        Self(path)
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn run_diskm(args: &[&str]) -> Value {
    let out = Command::new(env!("CARGO_BIN_EXE_diskm"))
        .args(args)
        .output()
        .unwrap();
    assert!(
        out.status.success(),
        "diskm {:?} failed: {}",
        args,
        String::from_utf8_lossy(&out.stderr)
    );
    serde_json::from_slice(&out.stdout).unwrap()
}

fn db_total_bytes(db: &Path) -> u64 {
    let main = fs::metadata(db).map(|m| m.len()).unwrap_or(0);
    let wal = fs::metadata(db.with_extension("sqlite3-wal"))
        .map(|m| m.len())
        .unwrap_or(0);
    main + wal
}

#[test]
fn shrink_reclaims_free_pages_and_preserves_search_results() {
    let tmp = TempDir::new("shrink");
    let root = tmp.0.join("root");
    let state = tmp.0.join("state");
    let keep_dir = root.join("keep");
    let prune_dir = root.join("prune");
    fs::create_dir_all(&keep_dir).unwrap();
    fs::create_dir_all(&prune_dir).unwrap();

    for i in 0..20 {
        fs::write(keep_dir.join(format!("keep-{i:04}.txt")), b"k").unwrap();
    }
    for i in 0..2500 {
        fs::write(
            prune_dir.join(format!("prune-entry-with-long-name-{i:05}.log")),
            b"p",
        )
        .unwrap();
    }

    let root_str = root.to_str().unwrap();
    let state_str = state.to_str().unwrap();
    let db_path = state.join("scratch-age.sqlite3");

    let r1 = run_diskm(&[
        "scratch-index",
        "refresh",
        "--root",
        "scratch",
        "--root-path",
        root_str,
        "--state-dir",
        state_str,
    ]);
    assert_eq!(r1["coverage_complete"], true);
    let size_large = db_total_bytes(&db_path);

    let future_epoch = (SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs()
        + 3600)
        .to_string();
    let before_keep = run_diskm(&[
        "scratch-search",
        "--root",
        "scratch",
        "--state-dir",
        state_str,
        "--before-epoch",
        &future_epoch,
        "--prefix",
        "keep",
        "--all",
    ]);
    let before_paths: Vec<&str> = before_keep["entries"]
        .as_array()
        .unwrap()
        .iter()
        .map(|e| e["path"].as_str().unwrap())
        .collect();
    assert_eq!(before_paths.len(), 21);

    // Delete the 2,500 files and refresh again.
    fs::remove_dir_all(&prune_dir).unwrap();
    let r2 = run_diskm(&[
        "scratch-index",
        "refresh",
        "--root",
        "scratch",
        "--root-path",
        root_str,
        "--state-dir",
        state_str,
    ]);
    assert_eq!(r2["coverage_complete"], true);
    let size_shrunk = db_total_bytes(&db_path);

    assert!(
        size_shrunk < size_large / 2,
        "expected SQLite DB size to shrink by >50% after pruning 2500/2520 files: before={size_large}, after={size_shrunk}"
    );

    let con = Connection::open(&db_path).unwrap();
    let auto_vacuum: i64 = con
        .query_row("PRAGMA auto_vacuum", [], |r| r.get(0))
        .unwrap();
    let freelist: i64 = con
        .query_row("PRAGMA freelist_count", [], |r| r.get(0))
        .unwrap();
    assert_eq!(auto_vacuum, 2, "expected incremental auto_vacuum");
    assert_eq!(freelist, 0, "expected zero un-reclaimed freelist pages");

    let table_sql: String = con
        .query_row(
            "SELECT sql FROM sqlite_master WHERE type='table' AND name='entries'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert!(
        table_sql.contains("WITHOUT ROWID"),
        "expected WITHOUT ROWID entries table: {table_sql}"
    );
    let mut stmt = con
        .prepare("SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='entries' ORDER BY name")
        .unwrap();
    let indexes: Vec<String> = stmt
        .query_map([], |r| r.get(0))
        .unwrap()
        .collect::<Result<_, _>>()
        .unwrap();
    assert_eq!(indexes, vec!["entries_age", "entries_birth"]);

    // Verify search results remain identical across time fields, kind filters, prefix, and pagination.
    let after_keep = run_diskm(&[
        "scratch-search",
        "--root",
        "scratch",
        "--state-dir",
        state_str,
        "--before-epoch",
        &future_epoch,
        "--prefix",
        "keep",
        "--all",
    ]);
    let after_paths: Vec<&str> = after_keep["entries"]
        .as_array()
        .unwrap()
        .iter()
        .map(|e| e["path"].as_str().unwrap())
        .collect();
    assert_eq!(before_paths, after_paths);

    let dirs_only = run_diskm(&[
        "scratch-search",
        "--root",
        "scratch",
        "--state-dir",
        state_str,
        "--before-epoch",
        &future_epoch,
        "--type",
        "directory",
        "--time",
        "created",
        "--all",
    ]);
    assert_eq!(dirs_only["entries"].as_array().unwrap().len(), 2);

    let page1 = run_diskm(&[
        "scratch-search",
        "--root",
        "scratch",
        "--state-dir",
        state_str,
        "--before-epoch",
        &future_epoch,
        "--type",
        "file",
        "--limit",
        "7",
    ]);
    let page2 = run_diskm(&[
        "scratch-search",
        "--root",
        "scratch",
        "--state-dir",
        state_str,
        "--cursor",
        page1["next_cursor"].as_str().unwrap(),
        "--type",
        "file",
        "--limit",
        "20",
    ]);
    assert_eq!(page1["entries"].as_array().unwrap().len(), 7);
    assert_eq!(page2["entries"].as_array().unwrap().len(), 13);
}

#[test]
fn migrates_v1_schema_preserves_rows_and_reclaims_bloat() {
    let tmp = TempDir::new("migrate-v1");
    let root = tmp.0.join("root");
    let state = tmp.0.join("state");
    fs::create_dir_all(root.join("sub")).unwrap();
    fs::create_dir_all(&state).unwrap();
    for i in 0..20 {
        fs::write(root.join("sub").join(format!("f-{i:02}.txt")), b"x").unwrap();
    }

    let (_, scan) = scan::scan_with_age_inventory(
        &root,
        ScanOptions {
            deadline: Duration::from_secs(10),
            max_entries: 1000,
        },
    )
    .unwrap();

    let db_path = state.join("scratch-age.sqlite3");
    {
        use std::os::unix::fs::OpenOptionsExt;
        let f = fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&db_path)
            .unwrap();
        drop(f);
        let con = Connection::open(&db_path).unwrap();
        con.execute_batch(
            "CREATE TABLE roots (
                root_key TEXT PRIMARY KEY NOT NULL,
                generation INTEGER NOT NULL,
                root_path BLOB NOT NULL,
                root_device BLOB NOT NULL CHECK(length(root_device)=8),
                root_inode BLOB NOT NULL CHECK(length(root_inode)=8),
                scan_complete INTEGER NOT NULL CHECK(scan_complete IN (0,1)),
                entry_count INTEGER NOT NULL CHECK(entry_count >= 0),
                gap_count INTEGER NOT NULL CHECK(gap_count >= 0)
             );
             CREATE TABLE entries (
                root_key TEXT NOT NULL REFERENCES roots(root_key) ON DELETE CASCADE,
                path BLOB NOT NULL,
                kind INTEGER NOT NULL CHECK(kind BETWEEN 0 AND 3),
                created_ns INTEGER,
                modified_ns INTEGER,
                changed_ns INTEGER,
                effective_modified_ns INTEGER,
                allocated_bytes BLOB NOT NULL CHECK(length(allocated_bytes)=8),
                apparent_bytes BLOB NOT NULL CHECK(length(apparent_bytes)=8),
                device BLOB NOT NULL CHECK(length(device)=8),
                inode BLOB NOT NULL CHECK(length(inode)=8),
                complete INTEGER NOT NULL CHECK(complete IN (0,1)),
                PRIMARY KEY(root_key, path)
             );
             CREATE INDEX entries_age ON entries(root_key, effective_modified_ns, path);
             CREATE INDEX entries_kind_age ON entries(root_key, kind, effective_modified_ns, path);
             CREATE INDEX entries_birth ON entries(root_key, created_ns, path);
             CREATE INDEX entries_kind_birth ON entries(root_key, kind, created_ns, path);
             CREATE INDEX entries_path ON entries(root_key, path);
             CREATE TABLE gaps (
                root_key TEXT NOT NULL REFERENCES roots(root_key) ON DELETE CASCADE,
                ordinal INTEGER NOT NULL,
                path BLOB NOT NULL,
                kind TEXT NOT NULL,
                message TEXT NOT NULL,
                PRIMARY KEY(root_key, ordinal)
             );
             CREATE TABLE temp_bloat (x BLOB);
             PRAGMA user_version=1;",
        )
        .unwrap();
        for _ in 0..300 {
            con.execute("INSERT INTO temp_bloat VALUES(zeroblob(2048))", [])
                .unwrap();
        }
        con.execute("DROP TABLE temp_bloat;", []).unwrap();
        con.execute(
            "INSERT INTO roots VALUES('scratch', 42, ?1, ?2, ?3, 1, ?4, 1)",
            rusqlite::params![
                scan.root_path_bytes,
                scan.root_device.to_be_bytes(),
                scan.root_inode.to_be_bytes(),
                scan.entries.len() as i64,
            ],
        )
        .unwrap();
        con.execute(
            "INSERT INTO gaps VALUES('scratch', 0, ?1, 'readdirectory', 'perm')",
            [&scan.root_path_bytes],
        )
        .unwrap();
        for e in &scan.entries {
            con.execute(
                "INSERT INTO entries VALUES('scratch', ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)",
                rusqlite::params![
                    e.path_bytes,
                    match e.kind {
                        AgeKind::Directory => 0,
                        AgeKind::File => 1,
                        AgeKind::Symlink => 2,
                        AgeKind::Special => 3,
                    },
                    e.created_epoch_nanos,
                    e.modified_epoch_nanos,
                    e.changed_epoch_nanos,
                    e.effective_modified_epoch_nanos,
                    e.allocated_bytes.to_be_bytes(),
                    e.apparent_bytes.to_be_bytes(),
                    e.device.to_be_bytes(),
                    e.inode.to_be_bytes(),
                    i64::from(e.complete),
                ],
            )
            .unwrap();
        }
    }
    let size_v1 = fs::metadata(&db_path).unwrap().len();

    let index = ScratchIndex::open(&db_path).unwrap();
    let snap = index.snapshot("scratch").unwrap();
    assert_eq!(snap.generation, 42);
    assert_eq!(snap.entry_count as usize, scan.entries.len());

    let page = index
        .query(&Query {
            root_key: "scratch".into(),
            time_field: AgeTimeField::EffectiveModified,
            cutoff_epoch_nanos: i64::MAX,
            kind: Some(AgeKind::File),
            path_prefix: Some(scan.root_path_bytes.clone()),
            limit: 100,
            cursor: None,
        })
        .unwrap();
    assert_eq!(page.rows.len(), 20);
    assert_eq!(page.gaps.len(), 1);
    assert_eq!(page.gaps[0].kind, "readdirectory");
    drop(index);

    let size_v2 = db_total_bytes(&db_path);
    assert!(
        size_v2 < size_v1 / 2,
        "expected v1->v2 migration to reclaim bloat: v1={size_v1}, v2={size_v2}"
    );

    let ro = ScratchIndex::open_read_only(&db_path).unwrap();
    assert_eq!(ro.snapshot("scratch").unwrap().generation, 42);
}
