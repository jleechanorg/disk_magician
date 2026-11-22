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

/// A snapshot older than this is reported stale by `status`.
pub const SNAPSHOT_STALE_AFTER: Duration = Duration::from_secs(36 * 60 * 60);

/// Scheduler cadences and run budgets. Templates in `launchd/` and `systemd/`
/// carry `@<NAME>_SECONDS@` placeholders that `scripts/render_template.py`
/// fills from `diskm time-windows`.
pub const SNAPSHOT_INTERVAL: Duration = Duration::from_secs(4 * 60 * 60);
pub const SCRATCH_PRESSURE_INTERVAL: Duration = Duration::from_secs(20 * 60);
pub const TEMP_SWEEP_INTERVAL: Duration = Duration::from_secs(60 * 60);
pub const STATE_COMMIT_INTERVAL: Duration = Duration::from_secs(30 * 60);
pub const EVIDENCE_HOLDS_INTERVAL: Duration = Duration::from_secs(60 * 60);
pub const SCRATCH_RECLAIM_TIMEOUT: Duration = Duration::from_secs(950);

/// Every window above, by placeholder name.
pub fn listing() -> Vec<(&'static str, Duration)> {
    vec![
        (
            "CONTENT_FLOOR",
            Duration::from_secs(u64::from(CONTENT_FLOOR_HOURS) * 3600),
        ),
        ("SCAN_DEADLINE", SCAN_DEADLINE),
        ("INDEX_REFRESH_DEADLINE", INDEX_REFRESH_DEADLINE),
        ("PREVIEW_CHECK_WINDOW", PREVIEW_CHECK_WINDOW),
        ("OPEN_FILE_PROBE_TIMEOUT", OPEN_FILE_PROBE_TIMEOUT),
        ("VOLUME_PROBE_TIMEOUT", VOLUME_PROBE_TIMEOUT),
        ("PROBE_POLL", PROBE_POLL),
        (
            "HISTORY",
            Duration::from_secs(u64::from(HISTORY_DAYS) * 86_400),
        ),
        (
            "LEDGER_STALE",
            Duration::from_secs_f64(LEDGER_STALE_HOURS * 3600.0),
        ),
        ("SNAPSHOT_STALE_AFTER", SNAPSHOT_STALE_AFTER),
        ("SNAPSHOT_INTERVAL", SNAPSHOT_INTERVAL),
        ("SCRATCH_PRESSURE_INTERVAL", SCRATCH_PRESSURE_INTERVAL),
        ("TEMP_SWEEP_INTERVAL", TEMP_SWEEP_INTERVAL),
        ("STATE_COMMIT_INTERVAL", STATE_COMMIT_INTERVAL),
        ("EVIDENCE_HOLDS_INTERVAL", EVIDENCE_HOLDS_INTERVAL),
        ("SCRATCH_RECLAIM_TIMEOUT", SCRATCH_RECLAIM_TIMEOUT),
    ]
}
