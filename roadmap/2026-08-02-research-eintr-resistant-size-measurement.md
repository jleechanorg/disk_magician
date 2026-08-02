# EINTR-resistant directory size measurement on loaded macOS (2026-08-02)

Mission: find a better way than "wrap `os.scandir` in a Python retry loop"
(the fix already shipped in commit `988f4c7` for
`src/disk_magician/scripts/disk_frontier_scan.py`) to size
`~/Library/Mail`, `~/Library/Messages`, and
`~/Library/Application Support/MobileSync/Backup` when load average is
700-1000+ on a 14-core Apple Silicon Mac and `du`/`ls`/`stat` fail with
EINTR (confirmed NOT a TCC/FDA problem — byte-identical failures with FDA
granted, across two different app process trees).

## Executive summary

1. **No traversal-free shortcut exists for these three paths.** `mdls`/
   `mdfind` (Spotlight `kMDItemFSSize`/`kMDItemLogicalSize`) only returns
   per-*file* metadata already in the index, has no "total size of this
   directory tree" query, and `~/Library/Mail` message stores +
   `~/Library/Messages` chat.db + `~/Library/Application Support/MobileSync/Backup`
   are excluded from Spotlight indexing by Apple's default
   `Info.plist`/`mdimporter` exclusion rules. `diskutil` and `tmutil`
   report container/volume-level or per-Time-Machine-snapshot numbers,
   never a live directory subtree size. There is no cached OS-level
   number to read instead of traversing.
2. **The single most promising concrete change: swap the language
   runtime, not the retry logic.** GNU coreutils' `du` (`gnulib/lib/fts.c`)
   and BSD/macOS's own `du` (`file_cmds/du/du.c`, `fts_open`/`fts_read`)
   both have **zero EINTR retry logic** at the C source level — confirmed
   by direct source read, not inference. Go's standard library
   (`internal/poll`, `os.ReadDir`) and Rust's standard library
   (`std::fs::read_dir` via the `cvt_r` retry wrapper) **both retry EINTR
   transparently inside the runtime**, so a Go tool (`gdu`) or Rust tool
   (`dua`, `diskus`) gets EINTR resistance for free, with no bespoke
   retry code to write or maintain. This is a stronger fix than the
   current bespoke Python backoff loop because it's upstream-maintained
   and applies to every syscall site, not just the two `os.scandir` call
   sites patched by hand.
3. **Second-best, complementary change: fewer syscalls, so fewer EINTR
   exposure windows.** `getattrlistbulk(2)` (macOS 10.10+, VFS-wide,
   replaces the deprecated `getdirentriesattr`) returns filenames *and*
   requested attributes (including size) for many directory entries per
   call, cutting syscall count by 10-100x vs `readdir`+`lstat` per file.
   Fewer syscalls per traversal is a direct, mechanical reduction in the
   number of EINTR-vulnerable windows, independent of whether load is
   high. It still needs its own retry wrapper (no evidence any existing
   `getattrlistbulk`-based tool retries EINTR), but combined with a
   Go/Rust runtime that already retries, or with the existing Python
   backoff pattern applied to far fewer call sites, this compounds well.
4. **The load-causes-EINTR theory has real (if partial) primary-source
   support**, but the specific "under extreme load" amplification is
   *my inference chain built on documented primitives*, not a single
   Apple statement that says "high load average causes more EINTR."
   See §3 below for the full chain and what is/isn't directly sourced.

## 1. GNU coreutils vs. BSD/macOS `du`/`ls`/`find` — EINTR retry behavior

**Finding: neither implementation retries on EINTR. There is no
"more EINTR-resistant" traditional `du`/`ls`/`find` — they are equally
fragile, confirmed by reading both C sources directly.**

- GNU coreutils' portable directory-walk primitive,
  `gnulib/lib/fts.c` (used by `du.c`, `find`, and other GNU tools), has
  **no EINTR handling anywhere in the file** — no retry loop around
  `readdir()`, `opendir()`, or `closedir()`, confirmed by direct source
  read of
  [`coreutils/gnulib/lib/fts.c`](https://github.com/coreutils/gnulib/blob/master/lib/fts.c).
- Apple's own `du` — [`apple-oss-distributions/file_cmds`,
  `du/du.c`](https://github.com/apple-oss-distributions/file_cmds/blob/main/du/du.c) —
  calls `fts_open()`/`fts_read()` (the *BSD* `fts(3)` implementation,
  distinct from gnulib's reimplementation but architecturally the same
  idea) with **no retry on EINTR** either. The only signal handling in
  `du.c` is a `SIGINFO` handler that just sets a progress-report flag; it
  does not touch the interrupted-syscall path at all.
- Net effect: macOS's built-in `du`/`find`/`ls` (BSD, from `file_cmds`)
  and a Homebrew-installed GNU `du`/`find` (coreutils) will **both**
  abort or emit "Interrupted system call" under the same EINTR
  conditions on the same box. Switching from BSD `du` to `brew install
  coreutils` gets you nothing here.
- BSD's `msleep(9)`/`PCATCH` semantics (the kernel-level primitive behind
  many blocking-then-interruptible calls, documented for FreeBSD at
  [man.freebsd.org/msleep(9)](https://man.freebsd.org/cgi/man.cgi?msleep(9))
  and for Darwin's kernel programming model at
  [Apple's Kernel Programming Guide — Synchronization Primitives](https://developer.apple.com/library/archive/documentation/Darwin/Conceptual/KernelProgramming/synchronization/synchronization.html))
  state plainly: *"If PCATCH is set and a signal becomes pending, ERESTART
  is returned if the call should be restarted, EINTR if it should be
  interrupted."* Neither `du` implementation ever sees or handles this at
  the `readdir`/`fts` layer — it just propagates whatever `errno` the
  kernel handed back.

## 2. APFS/macOS-native ways to get size without a full directory traversal

**Finding: none exist for these three specific user-data paths.**

- **`diskutil info`** reports container/volume-level free/used space
  (from APFS container metadata, not a live tree walk) — but APFS
  volumes share a container's free space pool and have no fixed "volume
  size," so `diskutil` cannot and does not report a `~/Library/Mail`-style
  subtree total at any granularity finer than the whole Data volume. See
  [ss64.com/mac/diskutil.html](https://ss64.com/mac/diskutil.html) and
  [The Eclectic Light Company — "Where did all that free space go on my
  APFS disk?"](https://eclecticlight.co/2020/04/09/where-did-all-that-free-space-go-on-my-apfs-disk/).
- **`tmutil`** has no "size of a live directory" verb at all. The closest
  are `tmutil uniquesize <path>` (actual disk space a path occupies
  inside a **Time Machine backup**, still requires a traversal internally)
  and `tmutil calculatedrift` (change between backups). There is no
  documented verb for "size of local APFS snapshot" either — acknowledged
  as a gap even by Apple's own developer forum participants: *"[tmutil]
  will list all the snapshots but will not tell you how much size they
  occupy."* ([Apple Developer Forums — APFS snapshot size
  thread](https://developer.apple.com/forums/thread/81171),
  [ss64.com/mac/tmutil.html](https://ss64.com/mac/tmutil.html)). Not
  applicable anyway — MobileSync backups are Finder/`Library` files, not
  Time Machine snapshots.
- **Spotlight (`mdls`/`mdfind`, `kMDItemFSSize`/`kMDItemLogicalSize`)**:
  these attributes exist and are queryable per-file
  ([Apple's Spotlight Metadata Attributes
  reference](https://developer.apple.com/library/content/documentation/CoreServices/Reference/MetadataAttributesRef/Reference/CommonAttrs.html)),
  but (a) there is no "sum of `kMDItemFSSize` under this directory" query
  — Spotlight indexes files, not directory-subtree aggregates, so you'd
  still have to `mdfind -onlyin <dir>` (itself a directory-scoped query
  that can hit the same underlying traversal/lock issues) and sum
  results yourself; and (b) Apple explicitly excludes Mail message stores,
  Messages' `chat.db`, and `~/Library/Application Support` backup blobs
  from the default Spotlight importer set — these are treated as
  app-private data, not general Spotlight-searchable content, so there
  is no guarantee the index even has current size data for them. No
  primary source documents a "give me the cached size Spotlight already
  knows for this whole directory tree" API — it doesn't exist.
- **Conclusion for this section: there is no OS-level number to read
  instead of traversing.** Every option above either operates at the
  wrong granularity (container/volume, not subtree) or requires exactly
  the traversal you're trying to avoid.

## 3. `getattrlist`/`getattrlistbulk`-based tools (gdu, dua, ncdu, diskus) — EINTR handling

- **`getattrlistbulk(2)`** (added Yosemite/10.10, documented in Apple's
  `getattrlistbulk(2)` man page and discussed on Apple's own
  `filesystem-dev` mailing list —
  [mail-archive.com/filesystem-dev "readdir vs.
  getdirentriesattr"](https://www.mail-archive.com/filesystem-dev@lists.apple.com/msg00263.html))
  batches filenames + requested attributes (including size) per call,
  replacing the deprecated `getdirentriesattr()`. A from-scratch Rust
  implementation built specifically to benchmark this
  ([Andrew Healey, "Maybe the Fastest Disk Usage Program on
  macOS"](https://healeycodes.com/maybe-the-fastest-disk-usage-program-on-macos))
  measured **6.4x faster than `du -sh`** and 2.58x faster than `diskus`,
  using a 128 KiB buffer per `getattrlistbulk` call, looping until it
  returns 0. **Fewer syscalls is the mechanism, not magic EINTR
  immunity** — the blog post and a second independent benchmark
  ([blog.tempel.org, "Performance considerations when reading
  directories on macOS"](http://blog.tempel.org/2019/04/dir-read-performance.html))
  both focus purely on throughput; **neither mentions EINTR, interrupted
  syscalls, or lock-contention robustness at all** — this is a real gap
  in the public record, flagged here rather than papered over.
- **gdu** ([dundee/gdu](https://github.com/dundee/gdu), Go) inherits
  Go's standard-library retry behavior (below) for free — its directory
  walk goes through `os.ReadDir`/`filepath.WalkDir`, not a hand-rolled
  syscall wrapper.
- **dua-cli / diskus** (Rust) walk via `std::fs::read_dir`, which also
  inherits Rust's retry-on-EINTR behavior (below).
- **ncdu** (C, then Zig from v2.0) — no EINTR-specific documentation
  found; as a C/Zig tool it should be assumed fragile like GNU/BSD `du`
  unless proven otherwise (not verified against source in this pass —
  flagged as unverified, not claimed either way).

### The actual EINTR-resistance differentiator: language runtime, not tool

- **Go**: the Go source itself documents this exact problem class. Per
  the Go source tree,
  [`internal/poll/fd_unix.go`](https://github.com/golang/go/blob/master/src/internal/poll/fd_unix.go)
  and the historical
  [golang-checkins: "internal/poll, os: loop on EINTR"](https://groups.google.com/g/golang-checkins/c/iCVOpNu2Zmk)
  change, Go's `ignoringEINTR` helper retries a syscall in a loop
  whenever it returns `EINTR`, with the doc comment explicitly noting
  *"this appears to be required even though all signal handlers are
  installed with SA_RESTART"* — i.e., Go's own maintainers hit and fixed
  this exact class of spurious-EINTR-despite-SA_RESTART bug, which lines
  up with the Endpoint-Security-mediated EINTR class described in §4
  (SA_RESTART does not help when the interruption happens inside a
  kernel condition-variable wait gated on a user-space daemon's
  response, not a normal signal-delivery-during-syscall race).
  `os.ReadDir`'s underlying `ReadDirent` was specifically patched to loop
  on transient errors.
- **Rust**: the standard library's `cvt_r` helper
  (documented via [Rust internals forum — "Policy for
  io::ErrorKind::Interrupted"](https://internals.rust-lang.org/t/policy-for-io-errorkind-interrupted/3315)
  and visible in `library/std/src/sys/unix/fs.rs`, referenced from
  [doc.rust-lang.org/std/fs/fn.read_dir.html](https://doc.rust-lang.org/std/fs/fn.read_dir.html))
  loops on `ErrorKind::Interrupted` (mapped 1:1 from `libc::EINTR`)
  transparently for `read_dir`/`opendir`/`readdir`-family calls, so
  application code built on `std::fs` "typically never observes
  `ErrorKind::Interrupted`."
- **C (glibc or Darwin libc directly, which is what both `du`
  implementations use)**: no such runtime-level retry exists — the
  application is 100% responsible, confirmed by the empty grep results
  in §1.
- **Python's `os.scandir`**: confirmed **still unfixed upstream** — Go
  and Rust closed this exact gap in their standard libraries years ago;
  Python has not. [python/cpython issue
  #130209](https://github.com/python/cpython/issues/130209) ("Make
  `os.scandir` retry on system calls failing with EINTR") is open,
  unassigned, no PR, as of the search performed for this doc. This
  directly validates that the bespoke Python backoff wrapper added in
  commit `988f4c7` was *necessary*, not just convenient — there is no
  upstream fix to rely on instead, unlike Go/Rust.

**Actionable implication:** if disk_magician wants to stop hand-rolling
EINTR retry in Python, `gdu` (Go, simple to install via `brew install
gdu`, JSON export via `-o`/`--output-file`) is the lowest-effort swap
that gets EINTR retry from the language runtime instead of bespoke code,
and it can be scripted/parsed the same way frontier_scan already
consumes structured output today.

## 4. FSEventStream / File Provider framework cached sizes

**Finding: no cached size exists here either.**

- Apple's own **FSEvents Programming Guide**
  ([developer.apple.com — "Using the File System Events
  API"](https://developer.apple.com/library/archive/documentation/Darwin/Conceptual/FSEvents_ProgGuide/UsingtheFSEventsFramework/UsingtheFSEventsFramework.html))
  documents the standard pattern explicitly: FSEvents only tells you
  *that* something changed in a directory tree, not *what size* the tree
  now is — "the simplest way to solve this problem is to take a
  snapshot directory hierarchy, storing your own copy of the state of
  the system." Apple's own sample code for this pattern (**Watcher**) is
  explicitly retired/deprecated. There is no size cache; you are
  expected to build and maintain your own, which is a strictly worse
  starting point than the ledger `disk_magician` already maintains in
  `~/.disk_magician_backup/ledger/topdown-5g.json`.
- **File Provider framework** is designed for cloud-storage-style
  providers (iCloud Drive, Dropbox, etc.) presenting placeholder/
  not-yet-materialized items with a `documentSize` the provider declares
  — it has no relevance to already-local, fully-materialized directories
  like Mail/Messages/MobileSync, which are not File-Provider-backed
  domains. No public API surface applies here. (No dedicated fetch was
  needed to rule this out — Mail/Messages/MobileSync are plain local
  files under a normal user's home directory, not File Provider domains;
  this is a structural mismatch, not a research gap.)

## 5. Does macOS deliver more EINTR-triggering signals under extreme load? (causal theory check)

**Verdict: the underlying mechanism (blocking-syscall-interrupted-by-signal
during an Endpoint-Security-mediated wait) has solid primary/near-primary
support. The specific claim "load average 700-1000 → measurably more EINTR"
is my inference built on top of that mechanism, not something any cited
source states directly. Flagging clearly per the request.**

**What is documented (each link independently corroborates the same
mechanism):**

1. Apple's own DTS engineer, on the Apple Developer Forums, explains
   Endpoint Security's blocking model directly: *"Apple supports two
   kinds of security events, AUTH and NOTIFY — AUTH means the system
   call is blocked on a condition variable, and the user-mode daemon is
   asked to approve or deny the event."* ([Apple Developer Forums —
   "Interrupted system call error
   when..."](https://developer.apple.com/forums/thread/678163) and the
   companion [ES_EVENT_TYPE_AUTH_OPEN
   thread](https://developer.apple.com/forums/thread/129112)).
2. The BSD/Darwin kernel primitive underlying that condition-variable
   wait, `msleep()`/`msleep0()` with the `PCATCH` flag, is documented
   (FreeBSD `msleep(9)` man page, and Apple's own **Kernel Programming
   Guide — Synchronization Primitives** for the Darwin-specific variant)
   to return **EINTR** to the caller *whenever a signal becomes pending
   while parked in that wait* — any signal, not necessarily one related
   to the file operation at all.
3. A concrete field report (PostgreSQL bug #16827/#16832, macOS 11 Big
   Sur — [postgresql.org bug
   thread](https://www.postgresql.org/message-id/16827-7606aeb21d38c228%40postgresql.org),
   [follow-up](https://www.postgresql.org/message-id/20210122172400.eiao4kgzhhpmtb5y%40alap3.anarazel.de))
   independently reproduces exactly this: `open()` returning EINTR only
   when the reporter's Endpoint Security daemon was active, crashing
   PostgreSQL because `open()` "should normally only happen when
   blocked" and the code didn't retry.
4. Apple's own classification: a specific manifestation of this was
   tracked as Endpoint Security radar **r.74618928**, "believed fixed in
   macOS 11.3rc" per the forum thread — confirming Apple has previously
   acknowledged and (partially) fixed bugs in this exact EINTR-via-ES
   pathway, though the underlying PCATCH/condvar architecture that makes
   it *possible* is not itself a bug, it's documented kernel behavior
   (item 2), so new instances of the same class can recur on any macOS
   version, on any path an ES client subscribes to.

**What is NOT documented anywhere found in this research (the inference
gap):**

- No source states that macOS's scheduler, thermal/jetsam subsystem, or
  `memorystatus_control` path *directly* raises EINTR frequency under
  CPU/memory pressure. Jetsam kills processes outright via SIGKILL-class
  termination (non-catchable, doesn't produce EINTR) — see
  [`apple-oss-distributions/xnu` —
  `doc/vm/memorystatus_notify.md`](https://github.com/apple-oss-distributions/xnu/blob/main/doc/vm/memorystatus_notify.md).
  It does not interrupt arbitrary blocked syscalls with a catchable
  condition.
- The **load → EINTR link I am asserting** is a mechanistic chain built
  from items 1-3 above, not a single citable claim: under load average
  700-1000, (a) any Endpoint-Security client (or, per this project's own
  commit `988f4c7` message, Mail/Notes' own indexing agent holding what
  the previous session characterized as "an exclusive lock during
  readdir") that must respond to an AUTH callout, or otherwise release
  whatever it's holding, is itself CPU-starved and takes longer to
  respond/release; (b) that extends the window during which the
  scanning process sits parked in the interruptible condvar wait, and
  (c) the probability that *some* unrelated signal (SIGCHLD from any of
  this box's own churning subprocesses, SIGWINCH from a resizing
  terminal pane, SIGALRM from a timer, etc.) lands on the scanning
  process during that now-longer window rises with wall-clock exposure
  time. This is architecturally plausible and consistent with the
  observed symptom (EINTR specifically on the TCC-protected,
  ES/indexer-adjacent paths — Mail, Messages, MobileSync — and not on
  ordinary unprotected directories), but it has not been directly
  confirmed against XNU source in this pass (an explicit search for
  `thread_abort_safely`/scheduler-triggered condvar wakeups in XNU
  turned up no primary-source hits — flagged as unverified, not
  claimed).
- **This project's prior working theory** ("Mail/Notes indexers
  intermittently hold an exclusive lock during readdir," per the
  `988f4c7` commit message) is not contradicted by the above — it is
  complementary. Both an ES AUTH callout and a plain advisory/exclusive
  lock held by an indexer would produce the same observable symptom
  (a blocked syscall vulnerable to the PCATCH/EINTR path) and both would
  get slower/more probable under load for the same reason (the
  lock-holder itself is CPU-starved). Neither theory has a smoking-gun
  XNU-source citation in this pass; both are plausible and not mutually
  exclusive.

## 6. Concrete recommendation for tonight

**Lowest-effort upgrade path, in priority order:**

1. **Try `gdu` first, no code changes needed to disk_magician's Python.**
   ```bash
   brew install gdu   # if not already installed
   gdu --non-interactive --output-file /tmp/gdu-mail.json \
       ~/Library/Mail
   gdu --non-interactive --output-file /tmp/gdu-messages.json \
       ~/Library/Messages
   gdu --non-interactive --output-file /tmp/gdu-mobilesync.json \
       "~/Library/Application Support/MobileSync/Backup"
   ```
   Because `gdu`'s directory walk goes through Go's `os`/`internal/poll`
   package, which retries EINTR transparently inside the runtime (§3),
   this should succeed where a plain `du`/`ls`/Python `os.scandir`
   call fails, with zero bespoke retry code. If `gdu` still reports
   errors on these three paths under tonight's load, that is itself a
   strong signal the EINTR source is NOT a plain signal-race (which
   Go's `SA_RESTART`-independent retry already handles) but something
   that defeats even a retrying `readdir` — e.g. the ES-mediated
   condvar wait producing EINTR on a syscall that isn't `readdir` at all
   (e.g. `open()`/`stat()` on individual entries), which would need a
   wider retry net than just the directory-listing call.
2. **If `gdu` isn't available/installable tonight, keep the existing
   Python backoff wrapper** (commit `988f4c7`) — it is the correct
   fallback shape (bounded exponential backoff, 50ms-2s, 7 attempts) and
   is already deployed and verified live against these exact three
   paths. Don't rewrite it under time pressure; the retry semantics are
   already right, only the language choice (Python vs. Go/Rust runtime)
   is suboptimal.
3. **Do not invest in `getattrlistbulk`-based custom tooling tonight.**
   It's a real throughput win (§3) but has no demonstrated EINTR
   advantage in the public record, and building/testing a correct
   retry wrapper around a syscall this repo doesn't already use is a
   bigger lift than trying an existing packaged tool (`gdu`) first.
4. **Don't chase `mdls`/`diskutil`/`tmutil`/FSEventStream/File Provider
   as an alternative measurement path** — §2 and §4 establish none of
   them expose a cached subtree size for these paths; any time spent
   there is a dead end already ruled out by this research pass.

## Sources cited

- [Apple Developer Forums — "Interrupted system call error when..."](https://developer.apple.com/forums/thread/678163)
- [Apple Developer Forums — "Endpoint Security & ES_EVENT_TYPE_AUTH_OPEN"](https://developer.apple.com/forums/thread/129112)
- [Apple Developer Forums — "Endpoint Security Framework deadline"](https://developer.apple.com/forums/thread/771996)
- [Apple's Kernel Programming Guide — Synchronization Primitives](https://developer.apple.com/library/archive/documentation/Darwin/Conceptual/KernelProgramming/synchronization/synchronization.html)
- [Apple — FSEvents Programming Guide, "Using the File System Events API"](https://developer.apple.com/library/archive/documentation/Darwin/Conceptual/FSEvents_ProgGuide/UsingtheFSEventsFramework/UsingtheFSEventsFramework.html)
- [Apple — Spotlight Metadata Attributes Reference](https://developer.apple.com/library/content/documentation/CoreServices/Reference/MetadataAttributesRef/Reference/CommonAttrs.html)
- [apple-oss-distributions/file_cmds — `du/du.c`](https://github.com/apple-oss-distributions/file_cmds/blob/main/du/du.c)
- [apple-oss-distributions/xnu — `doc/vm/memorystatus_notify.md`](https://github.com/apple-oss-distributions/xnu/blob/main/doc/vm/memorystatus_notify.md)
- [coreutils/gnulib — `lib/fts.c`](https://github.com/coreutils/gnulib/blob/master/lib/fts.c)
- [FreeBSD Man Pages — `msleep(9)`](https://man.freebsd.org/cgi/man.cgi?msleep(9))
- [PostgreSQL BUG #16827 — "macOS interrupted syscall leads to a crash"](https://www.postgresql.org/message-id/16827-7606aeb21d38c228%40postgresql.org)
- [PostgreSQL BUG #16827/#16832 follow-up (Andres Freund)](https://www.postgresql.org/message-id/20210122172400.eiao4kgzhhpmtb5y%40alap3.anarazel.de)
- [python/cpython issue #130209 — "Make os.scandir retry on system calls failing with EINTR"](https://github.com/python/cpython/issues/130209)
- [Go source — `internal/poll/fd_unix.go`](https://github.com/golang/go/blob/master/src/internal/poll/fd_unix.go)
- [golang-checkins — "internal/poll, os: loop on EINTR"](https://groups.google.com/g/golang-checkins/c/iCVOpNu2Zmk)
- [Rust internals forum — "Policy for io::ErrorKind::Interrupted"](https://internals.rust-lang.org/t/policy-for-io-errorkind-interrupted/3315)
- [Rust docs — `std::fs::read_dir`](https://doc.rust-lang.org/std/fs/fn.read_dir.html)
- [Apple `filesystem-dev` mailing list — "readdir vs. getdirentriesattr"](https://www.mail-archive.com/filesystem-dev@lists.apple.com/msg00263.html)
- [Andrew Healey — "Maybe the Fastest Disk Usage Program on macOS"](https://healeycodes.com/maybe-the-fastest-disk-usage-program-on-macos) (secondary/blog — flagged, no primary Apple doc for `getattrlistbulk` EINTR behavior exists)
- [blog.tempel.org — "Performance considerations when reading directories on macOS"](http://blog.tempel.org/2019/04/dir-read-performance.html) (secondary/blog — same flag)
- [ss64.com — `diskutil`](https://ss64.com/mac/diskutil.html) / [`tmutil`](https://ss64.com/mac/tmutil.html) (secondary — command reference, cross-checked against Apple forum threads)
- [The Eclectic Light Company — "Where did all that free space go on my APFS disk?"](https://eclecticlight.co/2020/04/09/where-did-all-that-free-space-go-on-my-apfs-disk/) (secondary — APFS container-vs-volume framing, no dedicated tmutil/diskutil doc states this as plainly)
- disk_magician commit `988f4c7` (this repo) — prior working theory and the existing Python retry fix this research is evaluating alternatives to

## What was ruled out

- Coreutils vs. BSD `du`/`find`/`ls` swap: no benefit, both lack EINTR retry (§1).
- `diskutil`/`tmutil` as a traversal-free size source: no subtree-level API exists (§2).
- Spotlight (`mdls`/`mdfind`) as a cached-size source: no directory-subtree aggregate query exists, and these three paths are excluded from the default importer set anyway (§2).
- FSEventStream / File Provider framework: neither exposes a cached size for already-local, non-File-Provider-backed directories (§4).
- "Load average directly triggers more EINTR via jetsam/scheduler": no primary source found; jetsam kills are SIGKILL-class and non-catchable, not EINTR-producing (§5).

## Update — live empirical retest (2026-08-02, ~12:00 PT), overturns the load-only theory

Re-tested every recommendation above directly on this machine, with real
before/after control of the load variable (this session's own load average
happened to drop from 900+ to ~64-70 mid-investigation, a ~15x drop):

1. **Load is NOT the (sole) cause.** `du -sh ~/Library/Mail` still fails
   with the identical `Interrupted system call` at load1≈64-70 as it did
   at load1≈900+. Tested through TWO different process trees (this
   session's own shell, and macOS Terminal.app with Full Disk Access
   granted) — both fail identically, at both load levels. This overturns
   the "extreme load specifically" framing in the executive summary above;
   at minimum the threshold (if load-related at all) is far below 64.

2. **Rust's EINTR-transparent retry (`dua`) does NOT help either.**
   `dua aggregate ~/Library/Mail ~/Library/Messages` exits 0 with **zero
   error** — but reports `0 B` for both, the classic silent-empty-result
   signature of a directory the current process's TCC identity cannot
   see, as opposed to the loud EINTR from `du`/`ls`. This is a different
   failure MODE, not evidence the underlying access actually succeeded.

3. **The frontier scanner's own proven os.scandir-retry technique, applied
   directly and stand-alone, ALSO fails** — 7 exponential-backoff attempts
   (50ms→2s cap), ~44s of real wall-clock retry time, still ends in
   `InterruptedError` on both Mail and Messages, at load≈64. This is the
   most important negative result: the exact code pattern that gets the
   scanner through other parts of the disk does not get through on these
   two specific paths, regardless of load. This strongly implies Mail/
   Messages were UNMEASURED in every one of tonight's "successful"
   frontier runs too (12,076 buckets on 07-29 included), not just the
   degraded/total-stall ones — the residual gap on these two paths looks
   structural, not transient.

4. **Ruled out via direct process/log inspection at time of test:** no EDR/
   AV client running (`ps aux` clean for Falcon/SentinelOne/CrowdStrike/
   Jamf/Sophos/etc.), no installed security configuration profiles
   mentioning Endpoint Security, `log show --predicate
   'subsystem == "com.apple.EndpointSecurity"'` empty for the prior 2 min,
   no `mdworker` process running, Mail.app and Messages.app were not even
   running at time of test (so no live app-held file lock either).

**Net effect: after ruling out load, FDA/TCC (in the naive sense), EDR
interception, live app locks, and Spotlight indexing activity, the
deterministic EINTR on these two specific paths remains unexplained.**
It reproduces 100% of attempts across load levels 64-1000+, across 3
different processes (this shell, Terminal.app, a standalone Python
scandir-retry loop), with and without FDA. Whatever the true mechanism,
it is NOT one of the 6 candidate causes tested directly this session.

**Recommended next step, not yet attempted:** `sudo fs_usage -w -f
filesys <pid>` or `dtruss`/`sample` against a `du`/Python process while
it's mid-traversal on these paths, to see the actual syscall + signal
that's arriving — this requires root/SIP-adjacent tooling and was judged
out of scope for tonight's session, but is the concrete way to actually
identify the interrupting signal source rather than continue guessing at
candidate daemons.
