//! Every default time window, defined once. Callers may override a window per
//! invocation through its documented flag or variable; no other source file,
//! scheduler template or document may restate these values.

use std::time::Duration;

/// Content-inactivity floor for disposable cleanup, in hours
/// (operator decision 2026-11-22). `--min-hours` overrides it per invocation.
pub const CONTENT_FLOOR_HOURS: u32 = 12;

/// Bounded scan budget for `scan`, `scratch-qualify`, `scratch-sweep` and
/// manifest qualification. `--deadline-ms` overrides it.
pub const SCAN_DEADLINE: Duration = Duration::from_secs(30);

/// Budget for `scratch-index refresh`. `--deadline-ms` overrides it.
pub const INDEX_REFRESH_DEADLINE: Duration = Duration::from_secs(120);

/// Upper bound for one subtree verification inside preview.
pub const PREVIEW_CHECK_WINDOW: Duration = Duration::from_secs(12);

/// Open-file probe (`lsof`) timeout during staged removal.
pub const OPEN_FILE_PROBE_TIMEOUT: Duration = Duration::from_secs(3);

/// Scratch volume identity probe (`diskutil`/`blkid`) timeout.
pub const VOLUME_PROBE_TIMEOUT: Duration = Duration::from_secs(30);

/// Poll interval while waiting on any probe subprocess.
pub const PROBE_POLL: Duration = Duration::from_millis(20);

/// Default `history` window in days (7 or 30 are supported).
pub const HISTORY_DAYS: u32 = 7;

/// Age after which the reclaim report is flagged stale, in hours.
/// `DISK_MAGICIAN_LEDGER_STALE_HOURS` overrides it.
pub const LEDGER_STALE_HOURS: f64 = 48.0;
