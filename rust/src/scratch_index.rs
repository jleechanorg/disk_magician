//! Local, rebuildable index for age-based Scratch path search.
//!
//! The index records observations. It does not authorize filesystem changes.

use crate::scan::{AgeInventoryReport, AgeKind, AgeMeasurement, ScanGap};
use rusqlite::types::Value;
use rusqlite::{
    params, params_from_iter, Connection, OpenFlags, OptionalExtension, Transaction,
    TransactionBehavior,
};
use serde::{Deserialize, Serialize};
use std::error::Error;
use std::fmt;
use std::fs::{self, OpenOptions};
use std::path::{Path, PathBuf};

#[cfg(unix)]
use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};

const SCHEMA_VERSION: i64 = 1;
const MAX_PAGE_ROWS: usize = 4096;

/// Which observed timestamp is used for age filtering and ordering.
#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum AgeTimeField {
    EffectiveModified,
    Created,
}

impl AgeTimeField {
    fn sql_column(self) -> &'static str {
        match self {
            Self::EffectiveModified => "effective_modified_ns",
            Self::Created => "created_ns",
        }
    }
}

/// A continuation token is valid only for the exact query and generation that produced it.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct Cursor {
    pub root_key: String,
    pub generation: i64,
    pub time_field: AgeTimeField,
    pub cutoff_epoch_nanos: i64,
    pub kind: Option<AgeKind>,
    pub path_prefix: Option<Vec<u8>>,
    pub last_epoch_nanos: i64,
    pub last_path_bytes: Vec<u8>,
}

/// One indexed root search. Cutoff uses strict less-than and rows are oldest first.
#[derive(Clone, Debug)]
pub struct Query {
    pub root_key: String,
    pub time_field: AgeTimeField,
    pub cutoff_epoch_nanos: i64,
    pub kind: Option<AgeKind>,
    /// Absolute OS pathname bytes. A match is the exact prefix path or a descendant component.
    pub path_prefix: Option<Vec<u8>>,
    /// Page size requested by the caller. The index caps each page at `MAX_PAGE_ROWS`.
    pub limit: usize,
    pub cursor: Option<Cursor>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct RootSnapshot {
    pub root_key: String,
    pub root_path_bytes: Vec<u8>,
    pub root_device: u64,
    pub root_inode: u64,
    pub generation: i64,
    pub scan_complete: bool,
    pub entry_count: u64,
    pub gap_count: u64,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct IndexGap {
    pub path_bytes: Vec<u8>,
    pub kind: String,
    pub message: String,
}

#[derive(Clone, Debug)]
pub struct Page {
    pub snapshot: RootSnapshot,
    pub rows: Vec<AgeMeasurement>,
    pub gaps: Vec<IndexGap>,
    pub next_cursor: Option<Cursor>,
}

pub struct ScratchIndex {
    connection: Connection,
    path: PathBuf,
}

#[derive(Debug)]
pub enum IndexError {
    Sqlite(rusqlite::Error),
    Io(std::io::Error),
    UnsupportedSchema(i64),
    RootNotIndexed(String),
    InvalidInventory(String),
    StaleGeneration { current: i64, attempted: i64 },
    StaleCursor { expected: i64, actual: i64 },
    CursorQueryMismatch,
    InvalidQuery(String),
    NumericRange(&'static str),
}

impl fmt::Display for IndexError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Sqlite(error) => write!(formatter, "scratch index SQLite error: {error}"),
            Self::Io(error) => write!(formatter, "scratch index I/O error: {error}"),
            Self::UnsupportedSchema(version) => {
                write!(
                    formatter,
                    "unsupported scratch index schema version {version}"
                )
            }
            Self::RootNotIndexed(root) => write!(formatter, "root is not indexed: {root}"),
            Self::InvalidInventory(reason) => write!(formatter, "invalid age inventory: {reason}"),
            Self::StaleGeneration { current, attempted } => write!(
                formatter,
                "scan generation {attempted} is not newer than published generation {current}"
            ),
            Self::StaleCursor { expected, actual } => write!(
                formatter,
                "search generation {expected} is stale because root is now generation {actual}"
            ),
            Self::CursorQueryMismatch => {
                formatter.write_str("search cursor does not match query filters")
            }
            Self::InvalidQuery(reason) => write!(formatter, "invalid age query: {reason}"),
            Self::NumericRange(field) => {
                write!(formatter, "{field} exceeds SQLite integer range")
            }
        }
    }
}

impl Error for IndexError {}

impl From<rusqlite::Error> for IndexError {
    fn from(error: rusqlite::Error) -> Self {
        Self::Sqlite(error)
    }
}

impl From<std::io::Error> for IndexError {
    fn from(error: std::io::Error) -> Self {
        Self::Io(error)
    }
}

impl ScratchIndex {
    /// Open or initialize an index. The containing state directory must be private to the user.
    pub fn open(path: impl AsRef<Path>) -> Result<Self, IndexError> {
        let path = path.as_ref().to_path_buf();
        create_private_database_file(&path)?;
        let connection = Connection::open_with_flags(
            &path,
            OpenFlags::SQLITE_OPEN_READ_WRITE
                | OpenFlags::SQLITE_OPEN_FULL_MUTEX
                | OpenFlags::SQLITE_OPEN_NOFOLLOW,
        )?;
        connection.busy_timeout(std::time::Duration::ZERO)?;
        connection.execute_batch("PRAGMA foreign_keys=ON; PRAGMA synchronous=NORMAL;")?;
        connection.query_row("PRAGMA journal_mode=WAL", [], |row| row.get::<_, String>(0))?;
        let mut index = Self { connection, path };
        index.initialize_schema()?;
        Ok(index)
    }

    /// Open an existing index without creating, migrating, or changing its data.
    pub fn open_read_only(path: impl AsRef<Path>) -> Result<Self, IndexError> {
        let path = path.as_ref().to_path_buf();
        validate_private_database_file(&path)?;
        let connection = Connection::open_with_flags(
            &path,
            OpenFlags::SQLITE_OPEN_READ_ONLY
                | OpenFlags::SQLITE_OPEN_FULL_MUTEX
                | OpenFlags::SQLITE_OPEN_NOFOLLOW,
        )?;
        connection.busy_timeout(std::time::Duration::ZERO)?;
        let version =
            connection.query_row("PRAGMA user_version", [], |row| row.get::<_, i64>(0))?;
        if version != SCHEMA_VERSION {
            return Err(IndexError::UnsupportedSchema(version));
        }
        connection.execute_batch("PRAGMA query_only=ON;")?;
        Ok(Self { connection, path })
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    fn initialize_schema(&mut self) -> Result<(), IndexError> {
        let version = self
            .connection
            .query_row("PRAGMA user_version", [], |row| row.get::<_, i64>(0))?;
        if version == SCHEMA_VERSION {
            return Ok(());
        }
        if version != 0 {
            return Err(IndexError::UnsupportedSchema(version));
        }

        let transaction = self
            .connection
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        transaction.execute_batch(
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
             PRAGMA user_version=1;",
        )?;
        transaction.commit()?;
        Ok(())
    }

    /// Atomically replace the last generation for one root.
    ///
    /// A late scan cannot overwrite a newer completed publication. Any error leaves the
    /// previous root generation visible because all rows and metadata share one transaction.
    pub fn publish(
        &mut self,
        root_key: &str,
        generation: i64,
        report: &AgeInventoryReport,
    ) -> Result<RootSnapshot, IndexError> {
        if root_key.is_empty() {
            return Err(IndexError::InvalidInventory("empty root key".into()));
        }
        let root_row = report
            .entries
            .iter()
            .find(|entry| entry.path_bytes == report.root_path_bytes)
            .ok_or_else(|| IndexError::InvalidInventory("root directory row is missing".into()))?;
        if root_row.kind != AgeKind::Directory
            || root_row.device != report.root_device
            || root_row.inode != report.root_inode
        {
            return Err(IndexError::InvalidInventory(
                "root row identity does not match root identity".into(),
            ));
        }
        let mut paths = std::collections::HashSet::with_capacity(report.entries.len());
        for entry in &report.entries {
            if !is_under_root(&report.root_path_bytes, &entry.path_bytes) {
                return Err(IndexError::InvalidInventory(
                    "entry pathname is outside the indexed root".into(),
                ));
            }
            if !paths.insert(entry.path_bytes.as_slice()) {
                return Err(IndexError::InvalidInventory("duplicate pathname".into()));
            }
        }

        let entry_count = sqlite_count(report.entries.len(), "entry count")?;
        let gap_count = sqlite_count(report.gaps.len(), "gap count")?;
        let transaction = self
            .connection
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        let current = transaction
            .query_row(
                "SELECT generation FROM roots WHERE root_key=?1",
                [root_key],
                |row| row.get::<_, i64>(0),
            )
            .optional()?;
        if let Some(current) = current {
            if generation <= current {
                return Err(IndexError::StaleGeneration {
                    current,
                    attempted: generation,
                });
            }
        }

        transaction.execute(
            "INSERT INTO roots(root_key,generation,root_path,root_device,root_inode,scan_complete,entry_count,gap_count)
             VALUES(?1,?2,?3,?4,?5,?6,?7,?8)
             ON CONFLICT(root_key) DO UPDATE SET
                generation=excluded.generation, root_path=excluded.root_path,
                root_device=excluded.root_device, root_inode=excluded.root_inode,
                scan_complete=excluded.scan_complete, entry_count=excluded.entry_count,
                gap_count=excluded.gap_count",
            params![
                root_key,
                generation,
                report.root_path_bytes,
                u64_blob(report.root_device),
                u64_blob(report.root_inode),
                bool_int(report.complete),
                entry_count,
                gap_count,
            ],
        )?;
        transaction.execute("DELETE FROM entries WHERE root_key=?1", [root_key])?;
        transaction.execute("DELETE FROM gaps WHERE root_key=?1", [root_key])?;
        insert_entries(&transaction, root_key, &report.entries)?;
        insert_gaps(&transaction, root_key, &report.gaps)?;
        transaction.commit()?;
        Ok(RootSnapshot {
            root_key: root_key.to_owned(),
            root_path_bytes: report.root_path_bytes.clone(),
            root_device: report.root_device,
            root_inode: report.root_inode,
            generation,
            scan_complete: report.complete,
            entry_count: u64::try_from(entry_count)
                .map_err(|_| IndexError::InvalidInventory("negative entry count".into()))?,
            gap_count: u64::try_from(gap_count)
                .map_err(|_| IndexError::InvalidInventory("negative gap count".into()))?,
        })
    }

    pub fn snapshot(&self, root_key: &str) -> Result<RootSnapshot, IndexError> {
        read_snapshot(&self.connection, root_key)
    }

    /// Return one read-only, oldest-first page from the current generation.
    pub fn query(&self, query: &Query) -> Result<Page, IndexError> {
        if query.limit == 0 {
            return Err(IndexError::InvalidQuery("limit must be positive".into()));
        }
        let limit = query.limit.min(MAX_PAGE_ROWS);
        // Read metadata, rows, and gaps from one SQLite snapshot. A refresh may commit
        // concurrently, but it cannot mix old rows with new root metadata in this page.
        let transaction = self.connection.unchecked_transaction()?;
        let snapshot = read_snapshot(&transaction, &query.root_key)?;
        if let Some(cursor) = &query.cursor {
            if cursor.generation != snapshot.generation {
                return Err(IndexError::StaleCursor {
                    expected: cursor.generation,
                    actual: snapshot.generation,
                });
            }
            if cursor.root_key != query.root_key
                || cursor.time_field != query.time_field
                || cursor.cutoff_epoch_nanos != query.cutoff_epoch_nanos
                || cursor.kind != query.kind
                || cursor.path_prefix != query.path_prefix
            {
                return Err(IndexError::CursorQueryMismatch);
            }
        }

        let rows = query_rows(&transaction, query, limit)?;
        let has_more = rows.len() > limit;
        let mut rows = rows;
        if has_more {
            rows.pop();
        }
        let next_cursor = if has_more {
            rows.last().map(|last| Cursor {
                root_key: query.root_key.clone(),
                generation: snapshot.generation,
                time_field: query.time_field,
                cutoff_epoch_nanos: query.cutoff_epoch_nanos,
                kind: query.kind,
                path_prefix: query.path_prefix.clone(),
                last_epoch_nanos: sort_epoch(last, query.time_field)
                    .expect("age query excludes unknown timestamps"),
                last_path_bytes: last.path_bytes.clone(),
            })
        } else {
            None
        };
        let gaps = read_gaps(&transaction, &query.root_key)?;
        transaction.commit()?;
        Ok(Page {
            snapshot,
            rows,
            gaps,
            next_cursor,
        })
    }
}

fn insert_entries(
    transaction: &Transaction<'_>,
    root_key: &str,
    entries: &[AgeMeasurement],
) -> Result<(), IndexError> {
    let mut statement = transaction.prepare_cached(
        "INSERT INTO entries(root_key,path,kind,created_ns,modified_ns,changed_ns,effective_modified_ns,
           allocated_bytes,apparent_bytes,device,inode,complete)
         VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12)",
    )?;
    for entry in entries {
        statement.execute(params![
            root_key,
            entry.path_bytes,
            kind_code(entry.kind),
            entry.created_epoch_nanos,
            entry.modified_epoch_nanos,
            entry.changed_epoch_nanos,
            entry.effective_modified_epoch_nanos,
            u64_blob(entry.allocated_bytes),
            u64_blob(entry.apparent_bytes),
            u64_blob(entry.device),
            u64_blob(entry.inode),
            bool_int(entry.complete),
        ])?;
    }
    Ok(())
}

fn insert_gaps(
    transaction: &Transaction<'_>,
    root_key: &str,
    gaps: &[ScanGap],
) -> Result<(), IndexError> {
    let mut statement = transaction.prepare_cached(
        "INSERT INTO gaps(root_key,ordinal,path,kind,message) VALUES(?1,?2,?3,?4,?5)",
    )?;
    for (ordinal, gap) in gaps.iter().enumerate() {
        let path = if let Some(hex) = &gap.path_bytes_hex {
            decode_hex(hex).ok_or_else(|| {
                IndexError::InvalidInventory("scanner returned malformed gap path bytes".into())
            })?
        } else {
            gap.path.as_bytes().to_vec()
        };
        statement.execute(params![
            root_key,
            sqlite_count(ordinal, "gap ordinal")?,
            path,
            format!("{:?}", gap.kind).to_ascii_lowercase(),
            gap.message,
        ])?;
    }
    Ok(())
}

fn query_rows(
    connection: &Connection,
    query: &Query,
    limit: usize,
) -> Result<Vec<AgeMeasurement>, IndexError> {
    let time_column = query.time_field.sql_column();
    let age_index = match (query.kind.is_some(), query.time_field) {
        (true, AgeTimeField::EffectiveModified) => "entries_kind_age",
        (false, AgeTimeField::EffectiveModified) => "entries_age",
        (true, AgeTimeField::Created) => "entries_kind_birth",
        (false, AgeTimeField::Created) => "entries_birth",
    };
    // A literal path range gives narrow subtree searches a path-index plan. The exact
    // directory row is matched separately. Descendant bounds end at the next BLOB prefix.
    let source_index = if query.path_prefix.is_some() {
        "entries_path"
    } else {
        age_index
    };
    let mut values = vec![
        Value::Text(query.root_key.clone()),
        Value::Integer(query.cutoff_epoch_nanos),
    ];
    let mut filters = vec![
        "root_key=?1".to_owned(),
        format!("{time_column} IS NOT NULL AND {time_column}<?2"),
    ];
    if let Some(kind) = query.kind {
        values.push(Value::Integer(kind_code(kind)));
        filters.push(format!("kind=?{}", values.len()));
    }
    if let Some(prefix) = &query.path_prefix {
        let (exact, lower, upper) = component_prefix_bounds(prefix);
        values.push(Value::Blob(exact));
        let exact_bind = values.len();
        values.push(Value::Blob(lower));
        let lower_bind = values.len();
        let descendants = if let Some(upper) = upper {
            values.push(Value::Blob(upper));
            format!(
                "(path=?{exact_bind} OR (path>=?{lower_bind} AND path<?{}))",
                values.len()
            )
        } else {
            format!("(path=?{exact_bind} OR path>=?{lower_bind})")
        };
        filters.push(descendants);
    }
    if let Some(cursor) = &query.cursor {
        values.push(Value::Integer(cursor.last_epoch_nanos));
        let epoch_bind = values.len();
        values.push(Value::Blob(cursor.last_path_bytes.clone()));
        let path_bind = values.len();
        filters.push(format!(
            "({time_column}>?{epoch_bind} OR ({time_column}=?{epoch_bind} AND path>?{path_bind}))"
        ));
    }
    values.push(Value::Integer(sqlite_count(limit + 1, "page limit")?));
    let limit_bind = values.len();
    let sql = format!(
        "SELECT path,kind,created_ns,modified_ns,changed_ns,effective_modified_ns,
                allocated_bytes,apparent_bytes,device,inode,complete
         FROM entries INDEXED BY {source_index}
         WHERE {} ORDER BY {time_column} ASC,path ASC LIMIT ?{limit_bind}",
        filters.join(" AND ")
    );
    let mut statement = connection.prepare(&sql)?;
    let mut output = Vec::new();
    let mut rows = statement.query(params_from_iter(values.iter()))?;
    while let Some(row) = rows.next()? {
        output.push(read_measurement(row)?);
    }
    Ok(output)
}

fn component_prefix_bounds(prefix: &[u8]) -> (Vec<u8>, Vec<u8>, Option<Vec<u8>>) {
    let mut exact = prefix.to_vec();
    while exact.len() > 1 && exact.last() == Some(&b'/') {
        exact.pop();
    }
    let mut lower = exact.clone();
    if lower.last() != Some(&b'/') {
        lower.push(b'/');
    }
    let upper = blob_prefix_successor(&lower);
    (exact, lower, upper)
}

fn blob_prefix_successor(prefix: &[u8]) -> Option<Vec<u8>> {
    let mut result = prefix.to_vec();
    for index in (0..result.len()).rev() {
        if result[index] != u8::MAX {
            result[index] += 1;
            result.truncate(index + 1);
            return Some(result);
        }
    }
    None
}

fn read_measurement(row: &rusqlite::Row<'_>) -> Result<AgeMeasurement, rusqlite::Error> {
    Ok(AgeMeasurement {
        path_bytes: row.get(0)?,
        kind: kind_from_code(row.get(1)?).map_err(to_sql_conversion_error)?,
        created_epoch_nanos: row.get(2)?,
        modified_epoch_nanos: row.get(3)?,
        changed_epoch_nanos: row.get(4)?,
        effective_modified_epoch_nanos: row.get(5)?,
        allocated_bytes: decode_u64_sql(row.get(6)?)?,
        apparent_bytes: decode_u64_sql(row.get(7)?)?,
        device: decode_u64_sql(row.get(8)?)?,
        inode: decode_u64_sql(row.get(9)?)?,
        complete: row.get::<_, i64>(10)? != 0,
    })
}

fn read_gaps(connection: &Connection, root_key: &str) -> Result<Vec<IndexGap>, IndexError> {
    let mut statement = connection
        .prepare("SELECT path,kind,message FROM gaps WHERE root_key=?1 ORDER BY ordinal ASC")?;
    let mut rows = statement.query([root_key])?;
    let mut gaps = Vec::new();
    while let Some(row) = rows.next()? {
        gaps.push(IndexGap {
            path_bytes: row.get(0)?,
            kind: row.get(1)?,
            message: row.get(2)?,
        });
    }
    Ok(gaps)
}

fn read_snapshot(connection: &Connection, root_key: &str) -> Result<RootSnapshot, IndexError> {
    connection
        .query_row(
            "SELECT root_key,root_path,root_device,root_inode,generation,scan_complete,entry_count,gap_count
             FROM roots WHERE root_key=?1",
            [root_key],
            |row| {
                Ok(RootSnapshot {
                    root_key: row.get(0)?,
                    root_path_bytes: row.get(1)?,
                    root_device: decode_u64_sql(row.get(2)?)?,
                    root_inode: decode_u64_sql(row.get(3)?)?,
                    generation: row.get(4)?,
                    scan_complete: row.get::<_, i64>(5)? != 0,
                    entry_count: decode_count_sql(row.get(6)?)?,
                    gap_count: decode_count_sql(row.get(7)?)?,
                })
            },
        )
        .optional()?
        .ok_or_else(|| IndexError::RootNotIndexed(root_key.to_owned()))
}

fn sort_epoch(entry: &AgeMeasurement, field: AgeTimeField) -> Option<i64> {
    match field {
        AgeTimeField::EffectiveModified => entry.effective_modified_epoch_nanos,
        AgeTimeField::Created => entry.created_epoch_nanos,
    }
}

fn is_under_root(root: &[u8], candidate: &[u8]) -> bool {
    candidate == root
        || (candidate.starts_with(root)
            && (root.last() == Some(&b'/') || candidate.get(root.len()) == Some(&b'/')))
}

fn kind_code(kind: AgeKind) -> i64 {
    match kind {
        AgeKind::Directory => 0,
        AgeKind::File => 1,
        AgeKind::Symlink => 2,
        AgeKind::Special => 3,
    }
}

fn kind_from_code(kind: i64) -> Result<AgeKind, &'static str> {
    match kind {
        0 => Ok(AgeKind::Directory),
        1 => Ok(AgeKind::File),
        2 => Ok(AgeKind::Symlink),
        3 => Ok(AgeKind::Special),
        _ => Err("unknown age kind in scratch index"),
    }
}

fn to_sql_conversion_error(error: &'static str) -> rusqlite::Error {
    rusqlite::Error::FromSqlConversionFailure(
        1,
        rusqlite::types::Type::Integer,
        Box::new(std::io::Error::new(std::io::ErrorKind::InvalidData, error)),
    )
}

fn decode_u64_sql(bytes: Vec<u8>) -> Result<u64, rusqlite::Error> {
    let bytes: [u8; 8] = bytes.try_into().map_err(|_| {
        rusqlite::Error::FromSqlConversionFailure(
            8,
            rusqlite::types::Type::Blob,
            Box::new(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                "expected an eight-byte unsigned integer",
            )),
        )
    })?;
    Ok(u64::from_be_bytes(bytes))
}

fn decode_count_sql(value: i64) -> Result<u64, rusqlite::Error> {
    u64::try_from(value).map_err(|_| {
        rusqlite::Error::FromSqlConversionFailure(
            6,
            rusqlite::types::Type::Integer,
            Box::new(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                "expected a non-negative count",
            )),
        )
    })
}

fn sqlite_count(value: usize, field: &'static str) -> Result<i64, IndexError> {
    i64::try_from(value).map_err(|_| IndexError::NumericRange(field))
}

fn create_private_database_file(path: &Path) -> Result<(), IndexError> {
    let mut options = OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    options.mode(0o600);
    match options.open(path) {
        Ok(file) => {
            file.sync_all()?;
            Ok(())
        }
        Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {
            validate_private_database_file(path)
        }
        Err(error) => Err(IndexError::Io(error)),
    }
}

fn validate_private_database_file(path: &Path) -> Result<(), IndexError> {
    let metadata = fs::symlink_metadata(path)?;
    if !metadata.file_type().is_file() {
        return Err(IndexError::InvalidInventory(
            "index path must be a regular non-symlink file".into(),
        ));
    }
    #[cfg(unix)]
    {
        let permissions = metadata.permissions().mode();
        if metadata.uid() != unsafe { libc::geteuid() } || permissions & 0o077 != 0 {
            return Err(IndexError::InvalidInventory(
                "index file must be owned by the current user and inaccessible to group/other"
                    .into(),
            ));
        }
    }
    Ok(())
}

fn u64_blob(value: u64) -> [u8; 8] {
    value.to_be_bytes()
}

fn bool_int(value: bool) -> i64 {
    if value {
        1
    } else {
        0
    }
}

fn decode_hex(hex: &str) -> Option<Vec<u8>> {
    if hex.len() % 2 != 0 {
        return None;
    }
    let mut bytes = Vec::with_capacity(hex.len() / 2);
    for pair in hex.as_bytes().chunks_exact(2) {
        let high = nibble(pair[0])?;
        let low = nibble(pair[1])?;
        bytes.push((high << 4) | low);
    }
    Some(bytes)
}

fn nibble(value: u8) -> Option<u8> {
    match value {
        b'0'..=b'9' => Some(value - b'0'),
        b'a'..=b'f' => Some(value - b'a' + 10),
        b'A'..=b'F' => Some(value - b'A' + 10),
        _ => None,
    }
}
