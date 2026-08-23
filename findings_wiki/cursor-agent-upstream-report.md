# Upstream Bug Report: Unbounded Debug Session Log Growth & High-Frequency `commitScoring` Loop in Cursor CLI Agent

**Target:** Cursor Community Forum / Cursor Upstream Support  
**Component:** Cursor CLI Agent (`agent` / `cursor-agent`, versions `2026.07.23-e383d2b` through `2026.08.11-e8db854`)  
**Impact:** Unbounded disk consumption (observed **45.4 GB** single session log file growing at **~18.5 GiB/day**), high CPU overhead, and potential disk-fill emergency on developer and worker machines.

---

## 1. Summary

Long-lived or headless Cursor CLI agent sessions continuously write verbose debug events to `$TMPDIR/cursor-agent-logs-<UID>/session-<timestamp>-<pid>-1.log`.

Because:
1. Debug session logging is **enabled by default** with no size limit or log rotation mechanism;
2. Routine success events (such as `ripgrep.configureSuccess`) and background polling routines log full multi-line JavaScript stack traces;
3. The background **`commitScoring`** service repeatedly iterates through the entire Git commit history of open repositories (~100 commits/sec) to attribute AI code authorship, emitting multiple log events (`commitScoring.scored`, `commitScoring.noHashData`, `commitScoring.skip`) for every commit;

a single idle/headless session left running across 2.5 days created a **45.4 GB** log file, exhausting host disk space.

---

## 2. Reproduction & Empirical Evidence

### A. Reproduction
1. Start Cursor CLI agent in any large Git repository (e.g. 5,000+ commits).
2. Leave the session running headless or idle for 24–48 hours.
3. Check `$TMPDIR/cursor-agent-logs-<UID>/`:
   ```bash
   ls -lh $TMPDIR/cursor-agent-logs-*/
   ```

### B. Observed Production Incident
- **Process:** PID 95634 running `~/.local/bin/agent --use-system-ca`
- **File:** `$TMPDIR/cursor-agent-logs-501/session-2026-07-27T03-00-48-477Z-95634-1.log`
- **Growth Rate:** +16.6 GiB in 21.5 hours (**~18.5 GiB/day**, measured via continuous `lsof`/`ls` telemetry)
- **Peak File Size:** **45,519,296,373 bytes (45.4 GB)** before emergency truncation.

### C. Event Mix Analysis
Sampling surviving sibling logs revealed that >90% of logged events originate from `commitScoring`:
```text
  17,412 commitScoring.noHashData
  17,412 commitScoring.scored
     482 ripgrep.configureSuccess (with multi-line Error/Stack trace)
      96 commitScoring.formatDetection.total
```

---

## 3. Technical Root Cause

1. **`commitScoring` Full History Traversal:**
   The `CliCommitScoringService` (`1852.index.js`) invokes `scoreRecentCommits()` / `pollForNewCommits()` which walks commit history via `git show` without bounding the depth or frequency on rewritten/large repository histories.
2. **Verbose Stack Traces on Benign Events:**
   Benign configuration events log full `(new Error).stack` objects into the debug stream.
3. **No File Rotation or Capping:**
   `createWriteStream` is opened in append mode (`flags: "a"`) to a single static file per session without maximum size checks, line count limits, or `copytruncate`/`newsyslog` hooks.

---

## 4. Current Workaround (Undocumented Env Var)

Inspection of the bundled JavaScript revealed an undocumented kill switch:
```bash
export CURSOR_AGENT_DISABLE_DEBUG_LOG=1
```

**Empirical Verification:**
- When running `agent --help` without the variable: a new `session-*.log` file is immediately created in `$TMPDIR/cursor-agent-logs-<UID>/`.
- When running `CURSOR_AGENT_DISABLE_DEBUG_LOG=1 agent --help`: **0** log files are created (`Debug logging is disabled by CURSOR_AGENT_DISABLE_DEBUG_LOG` is acknowledged internally).

---

## 5. Requested Upstream Fixes

1. **Native Log Rotation & Size Capping:** Default-cap session debug logs to a sensible ceiling (e.g. 50 MB) with rolling FIFO truncation (`copytruncate` or fixed chunk rotation).
2. **Document Logging Configuration:** Expose `--no-debug-log` or document `CURSOR_AGENT_DISABLE_DEBUG_LOG` in `agent --help` and official CLI docs.
3. **Throttle `commitScoring` Polling:** Implement backoff or circuit breaking on historical commit scans when no new commits are detected, and eliminate redundant stack trace emission on non-exceptional events.
