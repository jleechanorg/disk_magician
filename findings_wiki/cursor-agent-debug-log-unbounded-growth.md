# cursor-agent debug session logs grow unbounded (45 GB single file)

**Date found:** 2026-07-29 · **Beads:** disk_magician-ax0 (incident, closed),
see follow-up bead for prevention · **Status:** log reclaimed by another
agent 2026-07-29 ~02:30 PDT; recurrence risk ACTIVE (no vendor fix).

## What happened

A single cursor-agent session log —
`$TMPDIR/cursor-agent-logs-501/session-2026-07-27T03-00-48-477Z-95634-1.log`
— reached **45.4 GB**, growing ~18.5 GiB/day, written continuously for 2.5
days by a live headless cursor-agent process (PID 95634,
`~/.local/bin/agent --use-system-ca`, version `2026.07.23-e383d2b`).

## Root cause (mechanism chain, each link verified)

1. **Always-on per-session debug log, no rotation, no size cap.** Every
   cursor-agent session writes `--- Cursor Agent Debug Session ... ---` to
   one file for the session's whole life. Verified from sibling logs in the
   same dir; confirmed by web research: Cursor CLI docs expose **zero**
   logging config (no log-level flag, no rotation, no disable) —
   https://cursor.com/docs/cli/reference/configuration ,
   https://cursor.com/docs/cli/reference/parameters .
2. **Pathological verbosity:** routine success events (e.g.
   `ripgrep.configureSuccess`) are logged WITH multi-line JS stack traces.
3. **High-frequency event loop — `commitScoring`:** in the largest
   surviving sibling log, ~17k of 18k events are
   `commitScoring.scored`/`commitScoring.noHashData`/`commitScoring.skip` —
   the subsystem iterates EVERY commit in the repo history (~100
   commits/sec observed, 1–2 log events per commit) in repeated scan
   cycles. Amplified on this machine by huge/rewritten histories
   (worldarchitect.ai: 9,000+ commits post-rewrite → nearly every commit
   double-logs the `noHashData` + `scored` pair).
4. **Session longevity:** headless sessions parked in a bash shell run for
   days, so the per-session file compounds without bound.

Caveat: the 45-GB file was deleted before content sampling, so its exact
event mix is inferred from sibling logs of the same binary (strong but
indirect). Lesson: **sample a runaway log's event histogram BEFORE
cleanup** — `grep -o '^\[[^]]*\] [a-zA-Z._-]*' log | awk '{print $2}' |
sort | uniq -c | sort -rn | head`.

## Known-issue class (research, 2026-07-29)

No cursor-agent-specific public bug found, but the failure class is
documented and vendor-declined on sibling tools: opencode single log hit
74.8 GB (issue #12934, closed "not planned"); claude-code debug logs hit
20 GB+/file via a recursive slow-op-logging feedback loop (issue #16093,
closed "not planned"). Cursor forum threads confirm CLI logging is
under-documented with no native rotation; a Cursor staffer pointed users at
a third-party tool. Full citations: research report in session
2026-07-29 (main session), summarized here.

## Prevention / remediation (ranked)

1. **Truncate-in-place, never rename-rotate:** `: > <log>` frees space
   immediately for an O_APPEND writer (Node `createWriteStream` default) —
   the `copytruncate` pattern. Verify with `du -h` (NOT `ls -l`: a
   self-offset writer would leave an APFS sparse hole that inflates
   apparent size while real blocks stay freed).
2. **newsyslog default mode is a TRAP here:** rename+recreate rotation
   against a writer that never reopens its fd hides the file while it keeps
   growing until process exit. Use a size-gated truncate-in-place watchdog
   (launchd, per this repo's conventions) over
   `$TMPDIR/cursor-agent-logs-*/session-*.log` above N GB instead.
3. **UNDOCUMENTED KILL SWITCH EXISTS (correction 2026-07-29, found by
   reading the installed binary — absent from all official docs):**
   `CURSOR_AGENT_DISABLE_DEBUG_LOG=<any value>` disables the debug session
   log entirely. Verified in `versions/2026.07.23-e383d2b/index.js`:
   `const m="CURSOR_AGENT_DISABLE_DEBUG_LOG"; ... function _(){return
   !!process.env[m]}` — logging is default-ON for every session and gated
   only by this opt-out. Setting it in `~/.bashrc` is the root-cause fix
   (trade-off: loses cursor-agent debuggability); the truncate watchdog
   remains as belt-and-braces for sessions launched without the var.
   Earlier "no config-level fix" wording here was wrong — docs-absence is
   not code-absence (negative-claim evidence bar).
4. Long-lived headless cursor-agent sessions should be cycled periodically;
   a days-old session is both a log bomb and (per Cursor forum OOM
   reports) an OOM candidate.

## Detection signal for future triage

`$TMPDIR/cursor-agent-logs-<uid>/` — filename embeds the writer PID
(`session-<ts>-<PID>-<n>.log`); `latest.log` symlink marks the active one.
Any file here over ~1 GB means a runaway session; check
`ps -p <PID>` and the event histogram before acting.
