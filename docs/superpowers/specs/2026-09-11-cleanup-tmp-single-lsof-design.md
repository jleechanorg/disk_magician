# cleanup_tmp.sh: single lsof scan + one tmp tree — design

Bead: `disk_magician-dcz` (component I, roadmap
`2026-09-11-disk-recurrence-rootcause-and-automation.md` §3.4, §5).

## Goal

Stop `pressure_sweep.sh`'s step 1 (`cleanup_tmp.sh --clean --large`) from
timing out at `STEP_TIMEOUT=600` (observed `rc=124`, 2026-09-11T18:32:04Z,
78 timeout events across 45 days) by replacing per-candidate `lsof +w +D
<dir>` calls with one upfront system-wide scan, filtered in memory —
without weakening the existing fail-closed open-file guarantee. Also
collapse `TMP_DIRS` from `("/private/tmp" "/tmp")` to `("/private/tmp")`
since `/tmp` is a bare symlink to `/private/tmp` (`readlink /tmp` →
`private/tmp`), so the main scan loop (git-clone / agent-prompt /
cli-validation / worktree-pointer passes) currently walks the identical
tree twice.

## Measured evidence (this session, `timeout 120`, same host)

| Approach | Command | Wall time | Result |
|---|---|---|---|
| A — current per-candidate check | `/usr/sbin/lsof +w +D /private/tmp` (single invocation, not even the full per-candidate loop) | **did not finish in 120s** (`rc=124`) | 15 `WARNING: can't opendir(/private/tmp/tmp-mount-*): Permission denied` lines emitted before the timeout killed it |
| B — proposed single scan | `/usr/sbin/lsof -n -P -F n` (no reverse-DNS/port-name lookup, no directory target) piped through `awk`/`sed` filtering for `/private/tmp` prefix | **2.77s**, `rc=0` | 151 matching open-file paths under `/private/tmp` out of 94,270 total `n`-lines system-wide |

**Root cause of A's pathology**: `+D <dir>` makes lsof `opendir()`-walk
every subdirectory under `<dir>` to canonicalize and match symlinked
targets. This box has synthetic/FUSE mountpoints directly under
`/private/tmp` (`tmp-mount-*`, from sandboxed browser/Docker sessions)
that `opendir()` cannot enter (`Permission denied`), and lsof's retry/
diagnostic path around each one is what stalls the scan past the 10-minute
budget — confirmed live: a single `+D /private/tmp` call alone exceeded
120s, while `has_open_files()` in production calls the equivalent of this
once **per top-level candidate directory** inside the `--large` loop (see
the 2026-09-11T11:22–11:31 log excerpt below, where each "Skipping
recently active" line is preceded by an unlogged `has_open_files` call
that runs to completion first).

`-n -P` never touches the directory tree — it lists what processes
currently have open, sourced from the kernel's per-process fd tables — so
it is structurally immune to the `tmp-mount-*` opendir pathology. This is
not a tuning difference; it is a different, much cheaper syscall path.

Live log evidence of the timeout (`~/Library/Logs/disk-magician-pressure-sweep.log`):
```
[2026-09-11T18:22:04Z] pressure_sweep: step 1/2 cleanup_tmp.sh --clean --large — free before: 17 GB
[2026-09-11T11:22:07] cleanup_tmp.sh starting
[2026-09-11T11:22:07] Scanning /private/tmp ...
...
[2026-09-11T11:22:35] Scanning /tmp ...                         <- duplicate tree
[2026-09-11T11:22:38] Scanning /private/tmp for large top-level dirs ...
[2026-09-11T11:22:38] Skipping recently active dir ...
[2026-09-11T11:31:36] Skipping recently active dir ...          <- 9m29s in, still scanning candidates
[2026-09-11T18:32:04Z] pressure_sweep: step 1/2 cleanup_tmp.sh FAILED or timed out (rc=124) — continuing to step 2.
```

## Call sites (unchanged conditions, changed internals)

`has_open_files()` (`scripts/cleanup_tmp.sh:243-285`) has exactly two
callers today:

1. `purge_aged_archives()` line 360 — unconditional (`if has_open_files
   "$d"; then`), runs even in `--dry-run` because dry-run must still
   report what it *would* skip.
2. The `--large` top-level scan, line 629 — gated on
   `[[ "$DRY_RUN" != true ]] && has_open_files "$d"`.

**This design changes only the body of `has_open_files()` and adds one
new helper (`init_lsof_snapshot`). It does not touch either call
condition** — the dry-run asymmetry between the two sites is pre-existing
behavior, out of scope for this bead.

## Assumptions and Recommended Defaults

- **Q: single eager scan at script start, or lazy on first
  `has_open_files` call?**
  Recommended: **lazy**, memoized on first call. `purge_aged_archives()`
  runs on every invocation (even without `--large`) whenever the archive
  root has aged entries, so an eager unconditional scan would tax runs
  that never need it (e.g. a bare `cleanup_tmp.sh --clean` with an empty
  archive). Lazy costs nothing extra when the scan is skippable and still
  memoizes across both call sites within one run.
- **Q: scope the scan to `/private/tmp` (`+D`) or fully global (`-n -P`,
  no target)?**
  Recommended: **fully global**, because (a) it is what was measured as
  fast (2.77s) — `-n -P` with a `+D` target reintroduces the directory-walk
  cost this design exists to remove; (b) it transparently covers
  `DISK_MAGICIAN_ARCHIVE_ROOT` overrides that point outside `/private/tmp`
  (the existing archive-purge test suite does this — see
  `tests/test_cleanup_tmp_large_protections.sh` GREEN 6, which sets
  `DISK_MAGICIAN_ARCHIVE_ROOT="$TMP_ROOT/g6-archive"`, a path under the
  *test's* `$TMP_ROOT`, not `/private/tmp`); a `/private/tmp`-scoped scan
  would silently go blind on that fixture and any future non-default
  archive root.
- **Q: how to fail closed?**
  Recommended: **any non-zero `lsof` exit code, missing binary, or scan
  timeout fails the whole run's checks**, not just the current candidate.
  This is a strictly *stronger* fail-closed than today's implementation
  (which fails closed per-directory on a per-directory lsof failure).
  Rationale: once the one snapshot attempt has failed, there is no cheaper
  fallback to retry per-candidate — retrying per-candidate would resurrect
  exactly the slow path this bead removes. The bead's acceptance criterion
  ("fail closed if lsof itself fails") is satisfied more simply this way:
  no rc==1-vs-stdout-content heuristic is needed (that heuristic existed
  in the old code specifically to work around `+D`'s documented quirk of
  returning 1 with real hits on stdout; a targetless `-n -P` scan does not
  carry that quirk — verified live: `rc=0` with 226,465 lines of `-F`
  output and empty stderr).
- **Q: bound the scan's own wall time?**
  Recommended: **yes**, default 90s via `DISK_MAGICIAN_LSOF_SCAN_TIMEOUT_SEC`
  (reuses the `timeout`/`gtimeout` resolution pattern already in
  `pressure_sweep.sh:94-96`, duplicated locally in `cleanup_tmp.sh` since
  it does not source that file). A timeout is treated identically to a
  non-zero exit: fail closed globally. 90s leaves ample margin under the
  measured 2.77s baseline while still bounding worst case (e.g. an
  overloaded host) well inside the 600s `STEP_TIMEOUT`.
- **Q: parse `lsof` output with `awk` column-splitting or `-F n` field
  mode?**
  Recommended: **`-F n`** (lsof's machine-parseable field-output mode).
  Verified live: `lsof -n -P -F n` emits one `n<path>` line per open file
  with no ambiguity from variable-width `COMMAND`/`TYPE` columns or paths
  containing spaces — `awk '{print $9}'`-style parsing (used ad hoc in
  the measurement above) is not safe for the real implementation.
- **Q: how does `has_open_files(dir)` match the snapshot?**
  Recommended: a path is "open under `dir`" iff the snapshot contains a
  line exactly equal to `dir`, or a line with the literal prefix `dir/`
  (fixed-string `grep -F`, trailing slash required on the prefix form to
  avoid `/private/tmp/foo` false-matching an unrelated sibling
  `/private/tmp/foobar/...`).
- **Q: temp-file cleanup — `trap ... EXIT` or explicit `rm` at end of
  script?**
  Recommended: **explicit `rm -f` right before the final "Done." log
  line** (`scripts/cleanup_tmp.sh:655`), not a trap. The script already
  sets a **non-additive** `trap '...' EXIT` inline for the OpenCode-dylib
  candidate file (line 534); a second `trap ... EXIT` for the lsof
  snapshot file would silently clobber whichever one runs last (bash traps
  replace, not accumulate, unless explicitly composed). Rather than fix
  that pre-existing hazard as a drive-by (out of scope here), sidestep it:
  the snapshot file's lifetime is naturally bounded by the script's own
  runtime, so an explicit cleanup at the end of `main` is simpler and
  correct without touching the existing trap.
- **Q: does collapsing `TMP_DIRS` to one entry break any existing test?**
  Verified: no. Every test in `tests/test_cleanup_tmp_large_protections.sh`
  defines a `G*_TMP` fixture dir purely so the redirected `find /tmp ...`
  call has *something* to stat (`mkdir -p "$G*_PRIVATE_TMP" "$G*_TMP"`);
  grepping the file for any `$G*_TMP/<content>` path (i.e. a test placing
  actual candidate content under the fake `/tmp` tree, expecting the `/tmp`
  scan pass to find it) returns zero matches. `make_find_shim`'s `/tmp`
  branch becomes dead/inert scaffolding, not a load-bearing path.

## Options Considered

1. **Cache `lsof +D <dir>` results per top-level dir, one call per
   candidate but memoized across `purge_aged_archives` + `--large`.**
   Rejected: the archive-purge and large-dir candidate sets are disjoint
   directories (one is under `$ARCHIVE_ROOT`, one is direct
   `/private/tmp` children being considered *for* archiving), so
   memoization by directory buys nothing — the cost is `O(candidates)`
   regardless, and each individual `+D` call is already the thing that
   fails to complete in 120s.
2. **One upfront `lsof -n -P +D /private/tmp` scan** (global process
   listing, but still directory-targeted). Rejected: still invokes the
   same `opendir()` traversal machinery that stalls on `tmp-mount-*`; the
   `+D` target is exactly the slow part, independent of `+w`/`-n`/`-P`
   flags layered on top of it.
3. **One upfront fully-global `lsof -n -P -F n` scan, filtered in-memory
   by path prefix.** Selected — measured 2.77s, immune to the directory-
   traversal pathology, and (per the assumption above) transparently
   covers non-default archive roots used by tests.

## Design

### New state (script-scope, initialized once)

```bash
LSOF_SNAPSHOT_INITIALIZED=false
LSOF_SNAPSHOT_OK=false
LSOF_SNAPSHOT_FILE=""
```

### `init_lsof_snapshot()` — new function, called only from `has_open_files()`

1. No-op if `LSOF_SNAPSHOT_INITIALIZED` is already `true`; set it `true`
   immediately (guards re-entry even on failure paths).
2. Resolve `lsof_bin` with the **same precedence `has_open_files()` uses
   today** (`DISK_MAGICIAN_LSOF_BIN` env override → `/usr/sbin/lsof` if
   executable → `command -v lsof`). If none resolves: log `"Open-file
   snapshot unavailable (no usable lsof binary) — fail-closed: treating
   all candidates as open for this run."`, leave `LSOF_SNAPSHOT_OK=false`,
   return.
3. `out_file=$(mktemp -t disk-magician-lsof-snapshot.XXXXXX)`,
   `err_file=$(mktemp -t disk-magician-lsof-snapshot-err.XXXXXX)`.
4. Resolve a timeout wrapper locally (mirrors
   `pressure_sweep.sh:94-96`): `TIMEOUT_CMD` = `timeout`, else `gtimeout`,
   else empty. `scan_timeout="${DISK_MAGICIAN_LSOF_SCAN_TIMEOUT_SEC:-90}"`.
5. Run (wrapped in `$TIMEOUT_CMD "$scan_timeout"` if available):
   `"$lsof_bin" -n -P -F n >"$out_file" 2>"$err_file"`; capture `rc`.
6. If `rc != 0`: `diagnostic=$(head -n1 "$err_file" 2>/dev/null ||
   echo "no diagnostic")`; log `"Open-file snapshot scan failed (lsof
   rc=${rc}: ${diagnostic}) — fail-closed: treating all candidates as
   open for this run."`; `rm -f "$out_file" "$err_file"`;
   `LSOF_SNAPSHOT_OK=false`; return.
7. On success: `sed -n 's/^n//p' "$out_file" > "${out_file}.paths"`
   (keep only field-mode name lines, strip the `n` marker),
   `mv "${out_file}.paths" "$out_file"`, `rm -f "$err_file"`.
   `LSOF_SNAPSHOT_FILE="$out_file"`; log `"Open-file snapshot: $(wc -l <
   "$out_file" | tr -d ' ') open paths captured in one lsof -n -P scan."`;
   `LSOF_SNAPSHOT_OK=true`.

### `has_open_files()` — replace body, keep signature

```bash
has_open_files() {
  local dir="$1"
  init_lsof_snapshot
  if [[ "$LSOF_SNAPSHOT_OK" != true ]]; then
    return 0   # fail closed: whole-run scan failure/unavailable
  fi
  if grep -qxF -- "$dir" "$LSOF_SNAPSHOT_FILE" 2>/dev/null \
     || grep -qF -- "$dir/" "$LSOF_SNAPSHOT_FILE" 2>/dev/null; then
    return 0   # open: an exact or nested path is held open
  fi
  return 1     # closed
}
```

Both call sites (`purge_aged_archives` line 360, `--large` branch line
629) call `has_open_files "$d"` exactly as they do today — no change at
either call site.

### `TMP_DIRS` collapse

Line 145: `TMP_DIRS=("/private/tmp" "/tmp")` → `TMP_DIRS=("/private/tmp")`.
`USER_TMP` append logic (lines 146-151) is unchanged.

### End-of-script cleanup

Immediately before the final `log "$(dry_prefix)Done. ..."` line (656),
add: `[[ -n "$LSOF_SNAPSHOT_FILE" ]] && rm -f "$LSOF_SNAPSHOT_FILE"
2>/dev/null || true`.

## Error Handling and Evidence

- **Fail-closed proof (new test)**: point `DISK_MAGICIAN_LSOF_BIN` at a
  stub that exits 1 with a stderr diagnostic; assert the run still exits
  0, both a fresh `--large` candidate and an aged archive entry survive
  (files still present), and the log contains the new fail-closed
  diagnostic string. This supersedes GREEN 6 in
  `tests/test_cleanup_tmp_large_protections.sh` — its assertion string
  `"Open-file check failed"` must be updated to
  `"Open-file snapshot scan failed"` (the check moved from per-directory
  to whole-run).
- **Open-fd-still-skipped proof (updated test)**: GREEN 5f already holds a
  real fd open (via `nohup tail -f`) on a payload inside an aged archive
  entry and asserts `"Skipping in-use aged archive"` appears — this
  assertion text is unchanged by this design (only the *mechanism*
  producing the true/false result changes), so GREEN 5f is expected to
  keep passing unmodified and serves as the regression proof for "a dir
  with an open fd is still skipped."
- **New test — single scan, not per-candidate**: assert the log contains
  exactly one `"Open-file snapshot: "` line for a run with ≥2 `--large`
  candidates plus ≥1 aged-archive entry (proves memoization across both
  call sites within one invocation).
- **New test — `TMP_DIRS` collapse**: assert the log contains exactly one
  `"Scanning /private/tmp ..."` line and zero `"Scanning /tmp ..."` lines.
- **Production verification (not a unit test)**: after deploy, `grep -c
  "rc=124" ~/Library/Logs/disk-magician-pressure-sweep.log` must not
  increase across 3 consecutive launchd firings of `pressure_sweep.sh`
  (bead `disk_magician-dcz` acceptance criterion 1).

## Appendix — bead J (worldarchitect.ai, cross-repo, NOT implemented here)

Per the roadmap's component J and this bead's acceptance criterion 3, file
in `jleechanorg/worldarchitect.ai`:

> **Title**: Trap-kill child processes on exit in `run_local_server.sh` /
> `mcp_dual_background.sh`; keep raw study captures out of `~/roadmap`
>
> **Body**: These two scripts are the producer side of the `/private/tmp`
> and `~/roadmap` growth this disk_magician investigation keeps having to
> clean up after (roadmap `2026-09-11-disk-recurrence-rootcause-and-automation.md`
> §5, component J; one-time 166 GiB event self-collapsed 161.5→2.5 GiB in
> `~/roadmap/.../gemini-memory` once the study run ended, but two orphaned
> `run_local_server.sh` MCP servers — ports 8104/8108 — were still alive
> hours after their parent session ended, PIDs 3842/47420).
>
> Fix, two parts:
> 1. Add `trap 'pkill -P $$' EXIT` (or equivalent process-group cleanup)
>    to `run_local_server.sh` and `mcp_dual_background.sh` so a killed or
>    exited parent does not leave orphaned MCP server children running
>    indefinitely.
> 2. Redirect raw study/session output to `$TMPDIR` (ephemeral, OS-owned
>    lifecycle) instead of `~/roadmap`; copy only human-authored summaries
>    into `~/roadmap` at the end of a run.
>
> **Acceptance**: killing the parent process (SIGTERM and normal exit)
> leaves zero child MCP server processes running; a full study run leaves
> only summary files under `~/roadmap`, with raw captures confined to
> `$TMPDIR`.
>
> **Out of scope for disk_magician**: this repo has no write access to
> worldarchitect.ai's runtime scripts; link the created bead ID back into
> `disk_magician-dcz` once filed.
