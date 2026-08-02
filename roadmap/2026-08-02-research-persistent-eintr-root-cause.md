# Root cause of persistent, 100%-reproducible EINTR on Mail/Messages/MobileSync (2026-08-02)

Prior context (do not re-read for background — this doc is standalone): the
retry-tooling research at
`roadmap/2026-08-02-research-eintr-resistant-size-measurement.md` already
established that (a) no traditional `du`/`ls`/`find` implementation (BSD or
GNU) retries on EINTR, (b) there is no OS-level cached-size API that avoids
traversal for these three paths, and (c) Go/Rust runtimes retry EINTR
transparently but a Rust tool (`dua`) still silently returns 0 B here — a
different failure mode. That doc is about *how to survive* EINTR. This doc
is about *why EINTR happens at all, persistently, only on these three paths,
immune to 22 retries over 155s wall-clock*.

## Executive summary

**Leading theory (confidence: medium — mechanically well-supported by
primary sources, but the "why these three paths, why 100%" specificity is
inference, not a single Apple statement):**

Ordinary Full Disk Access / TCC enforcement is **not** the live-round-trip
mechanism that produces EINTR. Apple's own architecture caches the TCC
grant decision after first access, and file-open enforcement below that is
done **synchronously, in-kernel, by Sandbox.kext's MACF hooks** — there is
no daemon round trip, hence no blocking wait, hence no EINTR opportunity, on
the ordinary FDA-gated path. This is why granting FDA to Terminal.app
changed nothing: FDA was never the layer generating the interrupt.

The mechanism that **does** produce EINTR on blocking syscalls is Apple's
**Endpoint Security (ES) `AUTH` event model**, documented and reproduced
independently by both PostgreSQL and git users: when *any* ES client (not
necessarily a third-party EDR — Apple ships first-party ES clients as part
of macOS itself, e.g. for Time Machine exclusion checking, Migration
Assistant, or Messages-in-iCloud/Mail privacy protections) subscribes to an
`AUTH`-class event (`AUTH_OPEN`, `AUTH_READDIR`, etc.) on a path, the kernel
blocks the calling thread on a condition variable pending the client's
verdict. If **any** signal arrives while that thread is parked in
`msleep()`, the kernel unblocks the syscall by returning `EINTR` — **this
happens regardless of what the eventual verdict would have been**, and is
architecturally distinct from a `deny` (which returns `EPERM`/`-1` directly,
never `EINTR`). This is confirmed as a real, reproduced macOS mechanism
(§2), but no primary source enumerates which first-party system component,
if any, holds an `AUTH`-class ES subscription specifically on `~/Library/Mail`,
`~/Library/Messages`, and `~/Library/Application Support/MobileSync/Backup` —
that attribution is this document's inference, not a documented fact.

The "100% reproducible, survives 22 retries over 155s" character is the
strongest piece of evidence *against* pure bad-luck-signal-timing and
*for* some component holding a **near-continuous** stream of AUTH
subscriptions or blocking checks specifically on these three paths — high
enough in volume that essentially every syscall in a bulk traversal, not
just an unlucky one, collides with an interrupting signal. This is plausible
given these three paths are exactly Apple's own documented list of
FDA-protected categories ("Mail, Messages, Safari, Home, and Time Machine")
— i.e., they are already known to be treated specially by macOS, just via
mechanisms (ES AUTH subscriptions, not blanket ACLs) that are undocumented
at the level of "which daemon, which event type."

## Q1 — Is there a TCC category *separate* from blanket FDA specifically for Mail/Messages/iOS-backup data?

**No documented separate `kTCCServiceMail`/`kTCCServiceMessages`/
`kTCCServiceMobileSync` exists.** Full Disk Access
(`kTCCServiceSystemPolicyAllFiles`) is the single umbrella permission Apple
documents as covering "Mail, Messages, Safari, Home, and Time Machine
backups" — these are not literal per-service TCC entries, they're the
*description* of what FDA's blanket grant is understood to cover
([Eclectic Light — "Explainer: Permissions, privacy and
TCC"](https://eclecticlight.co/2025/11/08/explainer-permissions-privacy-and-tcc/),
[NinjaOne — Backup macOS FDA
docs](https://www.ninjaone.com/docs/backup/macos-full-disk-access-backup/)).

Extracting the live `kTCCService*` string table from `TCC.framework` (a
reproducible technique documented in a maintained community gist,
[stuartjash/d26370967cb3070b1533df2da0227dd2](https://gist.github.com/stuartjash/d26370967cb3070b1533df2da0227dd2),
cross-checked against
[AtlasGondal/macos-pentesting-resources](https://github.com/AtlasGondal/macos-pentesting-resources/blob/main/tccd/kTCCService.md))
shows no `Mail`, `Messages`, or `MobileSync`/backup-specific service string
on current macOS. The closest adjacent categories are `kTCCServiceUbiquity`
(iCloud sync generally, not Mail/Messages specifically) and the newer
`FileProviderDomain`/`FileProviderPresence` (File Provider extensions, e.g.
third-party cloud storage — not applicable to first-party Mail/Messages
stores). A separate, unrelated `kTCCServiceSystemPolicyAppData` category
exists (confirmed via [Apple Developer Forums thread
801461](https://developer.apple.com/forums/thread/801461)) but it governs
**App Group container** access (`~/Library/Group Containers/...`), not
Mail/Messages/MobileSync, and was not designed for this case.

**Verdict: ruled out as the mechanism.** No granular TCC category exists to
investigate further here — FDA is confirmed to be the relevant (and only)
TCC gate, consistent with your empirical finding that granting FDA changed
nothing (because FDA isn't the layer producing the EINTR — see Q2).

## Q2 — Does TCC *denial* manifest as EINTR (not EACCES), and can retrying past it ever succeed?

**Answer: TCC/sandbox denial itself does NOT manifest as EINTR — it
manifests as `EPERM`/`-1` directly.** EINTR is a *different, orthogonal*
failure mode: a race between a blocking kernel wait and signal delivery,
not a decision.

Primary-source chain:

1. **Ordinary FDA/TCC enforcement is cached, not a live per-call round
   trip.** TCC permission decisions are mediated by `tccd` via private APIs
   like `TCCAccessRequest`; this "triggers a prompt only if it's the first
   time the application has attempted to access that class of resource;
   otherwise it returns the stored (cached) permission decision" — the
   actual file-open enforcement below that is done in-kernel by
   `Sandbox.kext`'s MACF hooks (`cred_sb_evaluate`), which is synchronous
   and does not block on a daemon round trip
   ([Mark Rowe — "TCC and the macOS Platform Sandbox
   Policy"](https://bdash.net.nz/posts/tcc-and-the-platform-sandbox-policy/),
   [HackTricks — macOS Sandbox
   internals](https://hacktricks.wiki/en/macos-hardening/macos-security-and-privilege-escalation/macos-security-protections/macos-sandbox/index.html)).
   No blocking wait ⇒ no EINTR opportunity on this path.
2. **The mechanism that DOES block-and-can-EINTR is Endpoint Security's
   `AUTH`-class event model**, documented in a real, reproduced,
   Apple-acknowledged bug (fixed target macOS 11.3): when an ES client
   subscribes to an `AUTH` event (e.g. `AUTH_CREATE`, and structurally the
   same for `AUTH_OPEN`), the kernel "blocks [the syscall] waiting for a
   verdict from the usermode [ES client]... if the daemon decides to
   **block** the system call, the return code seen by the target process is
   `-1` (operation not permitted)... [but] the kernel, while waiting on a
   condition variable, if it receives an interrupt, will just pass EINTR
   (error code 4) back to the usermode program" — **independent of what the
   verdict would have been** ([PostgreSQL bug #16827
   thread](https://www.postgresql.org/message-id/16827-7606aeb21d38c228%40postgresql.org),
   cross-confirmed by Apple DTS engineer "Quinn The Eskimo" acknowledging
   this exact class of bug for git/ES interaction, radar r.74618928,
   [Apple Developer Forums thread
   678163](https://developer.apple.com/forums/thread/678163)).
3. Apple's own canonical EINTR explanation (no TCC/ES-specific carve-out)
   states the general mechanism plainly: "If [a thread is] blocked inside
   the kernel waiting for a system call to complete, the system unblocks
   the system call by failing it with an `EINTR` error"
   ([Apple Developer Forums thread
   766168](https://developer.apple.com/forums/thread/766168), the DTS
   engineer's referenced canonical "Understanding EINTR" post).

**So: could retrying past a TCC-denied path ever succeed?** No — but that's
moot, because denial doesn't produce EINTR at all; it produces `EPERM`
directly (matching your Q1 finding that plain `du`/`ls` fail identically
with or without FDA — if it were denial, you'd see `Operation not
permitted`, not `Interrupted system call`, which is exactly the distinction
a widely-cited `parallel-disk-usage` GitHub issue independently reproduces:
protected directories give `EPERM`/"Operation not permitted", a visibly
*different* error class from EINTR
([KSXGitHub/parallel-disk-usage#134](https://github.com/KSXGitHub/parallel-disk-usage/issues/134))).
**Could retrying past a race-condition EINTR (interrupt-during-wait, verdict
pending) ever succeed?** In principle yes, and normally does — this is
exactly the mechanism your `disk_frontier_scan.py` retry loop already
defeats on other paths. The fact that it does **not** clear on these three
specific paths after 22 attempts over 155s is the anomaly requiring its own
explanation (see Executive Summary and Q5) — no primary source explains why
a *specific set of three paths* would be immune to backoff while others
aren't; that gap is explicitly unresolved by any source found.

## Q3 — Is Homebrew Python's own bundle identity (not inheriting parent's FDA) a factor?

**Partial explanation only, and you've already ruled out it being the sole
cause** (plain `du`/`ls`/bash builtins fail identically with no Python
involved at all) — flagging as instructed.

What is documented: TCC/FDA grants are tied to code identity (bundle ID +
Team ID + code-signature hash), and Homebrew's Python (built as a
`Python.app`-style framework, not a stable single-bundle-ID `.app`) is a
known source of TCC friction — subprocess chains through a shared,
frequently-rebuilt binary don't reliably inherit a parent's FDA grant
across Homebrew upgrades because the code identity changes with each
rebuild
([anthropics/claude-code#55661](https://github.com/anthropics/claude-code/issues/55661)
documents this exact "FDA revoked on every Homebrew update" pattern; general
TCC-by-code-identity behavior via
[HackTricks TCC](https://hacktricks.wiki/en/macos-hardening/macos-security-and-privilege-escalation/macos-security-protections/macos-tcc/index.html)).
Separately, subprocess FDA inheritance through direct child processes has
also *regressed* across macOS versions for unrelated reasons (helper tools
stopped inheriting FDA in macOS 11.4 — [Michael Tsai's blog, citing Apple
DTS](https://mjtsai.com/blog/2021/06/01/macos-11-4-breaks-full-disk-access-for-helper-tools/)).

**Verdict: real mechanism, but not applicable here.** Since plain shell
builtins (no Python in the chain at all) show byte-identical EINTR, Python's
bundle identity cannot be the operative cause of *this* symptom — it could
only matter if you were seeing `EPERM`/permission-prompt behavior
specifically on Python-mediated paths and clean behavior on bash-mediated
ones, which is not what's observed.

## Q4 — Are these three paths under a special APFS/kernel-level protection distinct from ordinary TCC (not just FDA)?

**No primary source documents a distinct APFS-level ACL/ownership
protection specific to these three paths beyond TCC/FDA + Sandbox.kext
enforcement.** What is documented is that FDA's blanket description
explicitly *names* these categories ("Mail, Messages, Safari, Home, and Time
Machine") as receiving special treatment relative to ordinary user files —
but every source describing *how* that's implemented points back to
TCC/Sandbox.kext, not a separate APFS extended-attribute/ACL layer or SIP
proper. No source found documents "Migration Assistant protections" or
"Keep Messages in iCloud" applying a distinct filesystem-level lock
(e.g., an APFS clone-on-write freeze, or a `chflags`-style immutable flag)
to these directories during normal (non-migrating, non-syncing) operation.
**This question is not settled by any primary source found — flagging as
explicitly open**, and it's the most likely place a first-party ES `AUTH`
subscription (per the Executive Summary theory) would live if one exists,
since Migration Assistant, Time Machine exclusion, and Messages-in-iCloud
sync are exactly the kind of first-party components that would have a
legitimate reason to intercept opens on these paths continuously.

## Q5 — Prior reports of *persistent* (not intermittent) EINTR on these exact three paths?

**Found one closely-matching, independently-reported case — but not on
these exact three paths, and Apple's response there also stopped short of
root-causing the persistence.** Arq (a commercial macOS backup app) users
reported, on macOS Sequoia, `NSFileManager.contentsOfDirectoryAtPath:error:`
returning `NSFileReadUnknownError` wrapping POSIX `EINTR`, with the
reporter's own characterization: "sometimes waiting and retrying works
fine, [other times] 5 retries still fail," and "happens on different
directories each time" — i.e., *sometimes* persistent past 5 retries, but
not path-specific in the way your case is ([Apple Developer Forums thread
766041](https://developer.apple.com/forums/thread/766041)). Apple's DTS
response there again characterized this as ordinary Unix EINTR needing
retry and did not identify a root cause for the persistence, nor did it
mention TCC, Endpoint Security, or sandboxd as a specific culprit for that
thread.

**No GitHub issue was found in coreutils, gdu, dua, ncdu, rsync, restic, or
borgbackup specifically naming `~/Library/Mail`, `~/Library/Messages`, or
`MobileSync/Backup` as a *persistent* (not intermittent) EINTR source.**
Searches surfaced only the general `EPERM`-on-protected-directories pattern
(`parallel-disk-usage`, `dust`) and general PostgreSQL/git EINTR-from-ES
reports on unrelated paths (`pg_wal`, git's `.git` internals). **This
symptom, on these exact three paths, with 100% reproducibility across 22
retries, does not appear to be a previously-named, documented macOS quirk**
— it may be novel enough (or rare enough in this specific combination) that
nobody has written it up. State this explicitly rather than implying it's
a "known issue with a name" — it is not, based on available sources.

## What would prove (or refute) the leading theory

The theory requires: (a) an Endpoint Security client currently holding an
`AUTH`-class subscription that covers these three paths, and (b) that
subscription's round-trip volume is high enough to make signal-collision
near-certain on every syscall in a bulk traversal, not just occasional
ones.

Concrete tests, cheapest first:

1. **`sudo log stream --predicate 'eventMessage contains "EINTR" OR eventMessage contains "AUTH_OPEN" OR eventMessage contains "AUTH_READDIR"' --info --debug`**
   run *during* a live reproduction of the failure (not just the narrow
   `subsystem == "com.apple.EndpointSecurity"` predicate already tried,
   which would miss first-party ES clients that log under their own
   subsystem, e.g. `com.apple.TimeMachine`, `com.apple.icloud.*`, or don't
   log to unified logging at all). This directly tests whether *any*
   process is generating AUTH-class ES traffic concurrently with the
   failing syscalls.
2. **`sudo fs_usage -w -f filesys <pid-of-your-retry-loop>`** while
   reproducing — `fs_usage` shows per-syscall latency and, critically, will
   show a long-blocked `open`/`getdirentriesattr` call immediately preceding
   the EINTR return if a genuine kernel-level condvar wait is occurring
   (vs. a near-instant EINTR, which would instead suggest something
   returning EINTR synthetically/immediately, a different and more unusual
   mechanism not covered by any source above).
3. **List loaded system extensions with an ES entitlement**:
   `systemextensionsctl list` plus
   `sudo log show --predicate 'process == "endpointsecurityd"' --last 1h`
   to enumerate every ES client currently registered (first- or
   third-party) — the `ps aux` sweep already done would miss ES clients
   that run as system extensions rather than ordinary processes, and would
   miss the case where `endpointsecurityd` itself (not the client) is the
   one you'd see in a process list.
4. **Differential test**: reproduce the same retry loop against a *fourth*
   path that is FDA-protected but NOT in Apple's named FDA category list
   (e.g. `~/Library/Safari` *is* named, so pick something FDA-gated but
   NOT customer-communications-related, such as
   `~/Library/Application Support/com.apple.TCC` itself, which is
   FDA-protected per the `parallel-disk-usage` issue). If EINTR is
   equally persistent there, the "these three are special" framing is
   wrong and the real boundary is something broader (e.g. "any directory
   with restricted read but non-empty contents" or "any directory large
   enough that traversal duration exceeds some system timer interval").
   This test would meaningfully update the theory's confidence level either
   way and is the single highest-value next step.

## Sources cited

- [Apple Developer Forums thread 678163 — Interrupted system call with Endpoint Security](https://developer.apple.com/forums/thread/678163)
- [Apple Developer Forums thread 766041 — NSFileManager contentsOfDirectoryAtPath EINTR](https://developer.apple.com/forums/thread/766041)
- [Apple Developer Forums thread 766168 — Understanding EINTR (canonical DTS explanation)](https://developer.apple.com/forums/thread/766168)
- [Apple Developer Forums thread 801461 — kTCCServiceSystemPolicyAppData](https://developer.apple.com/forums/thread/801461)
- [PostgreSQL BUG #16827 — macOS interrupted syscall leads to a crash](https://www.postgresql.org/message-id/16827-7606aeb21d38c228%40postgresql.org)
- [PostgreSQL BUG #16832 thread](https://www.postgresql.org/message-id/20210122172400.eiao4kgzhhpmtb5y%40alap3.anarazel.de)
- [Mark Rowe — TCC and the macOS Platform Sandbox Policy](https://bdash.net.nz/posts/tcc-and-the-platform-sandbox-policy/)
- [Mark Rowe — Sandboxing on macOS](https://bdash.net.nz/posts/sandboxing-on-macos/)
- [HackTricks — macOS Sandbox internals](https://hacktricks.wiki/en/macos-hardening/macos-security-and-privilege-escalation/macos-security-protections/macos-sandbox/index.html)
- [HackTricks — macOS TCC](https://hacktricks.wiki/en/macos-hardening/macos-security-and-privilege-escalation/macos-security-protections/macos-tcc/index.html)
- [Eclectic Light Company — Explainer: Permissions, privacy and TCC (2025-11-08)](https://eclecticlight.co/2025/11/08/explainer-permissions-privacy-and-tcc/)
- [gist: stuartjash — kTCCService strings within tccd](https://gist.github.com/stuartjash/d26370967cb3070b1533df2da0227dd2)
- [AtlasGondal/macos-pentesting-resources — kTCCService.md](https://github.com/AtlasGondal/macos-pentesting-resources/blob/main/tccd/kTCCService.md)
- [KSXGitHub/parallel-disk-usage#134 — macOS protected-directory errors (EPERM, not EINTR)](https://github.com/KSXGitHub/parallel-disk-usage/issues/134)
- [anthropics/claude-code#55661 — FDA revoked on every Homebrew update](https://github.com/anthropics/claude-code/issues/55661)
- [Michael Tsai — macOS 11.4 Breaks Full Disk Access for Helper Tools](https://mjtsai.com/blog/2021/06/01/macos-11-4-breaks-full-disk-access-for-helper-tools/)
- [Michael Tsai — macOS 15.4 Adds TCC Events to Endpoint Security](https://mjtsai.com/blog/2025/03/28/macos-15-4-adds-tcc-events-to-endpoint-security/)
- [Objective-See — Apple finally adds TCC events to Endpoint Security](https://objective-see.org/blog/blog_0x7F.html)

## Explicitly unresolved (no primary source found)

- Which specific first-party (or, if present, undetected third-party)
  process holds an `AUTH`-class ES subscription on
  `~/Library/Mail`/`~/Library/Messages`/`MobileSync/Backup`, if any —
  Executive Summary theory, not confirmed.
- Why these three paths specifically, vs. other FDA-protected-but-not-
  Apple-named-category paths, would show 100% EINTR persistence — see
  "What would prove this" test 4.
- Whether APFS/SIP applies any protection to these paths distinct from
  TCC/Sandbox.kext (Q4) — no source found either way.

## RESOLVED — cleared by a host reboot (2026-08-02, ~16:26 PT)

After a reboot (`uptime` showed "up 33 mins" vs. 6+ days before), the
identical `du`/`ls` commands that failed 100% of the time across every
load level tested (64, 85, 192, 264, 750-1000+) **succeeded immediately**
at load1≈14-34:

- `~/Library/Mail`: **3.4 GiB**
- `~/Library/Messages`: **1.0 GiB**
- `~/Library/Application Support/MobileSync/Backup`: **0 B** (genuinely
  empty — no device backups currently stored)

This is strong retroactive support for the leading theory in this doc
(an Endpoint Security AUTH-event race, likely tied to a long-lived
first-party subscription/daemon state that a fresh boot resets) over the
alternative "these paths are permanently special" framing — the block
was persistent-but-not-permanent, and cleared with the one intervention
(reboot) never tried this session.

**Major correction to prior assumptions carried through tonight's other
reports:** Mail + Messages + MobileSync sum to only **4.4 GiB total**,
nowhere near the ~75-165 GiB estimate in
`roadmap/research-residual-296gib-20260730.md` that this entire
investigation thread was implicitly chasing. Whatever accounts for the
remaining ~250+ GiB residual, it is NOT primarily these three paths —
that framing should be retired. The residual's real composition remains
open; worth a fresh frontier scan now that both the scanner bug is fixed
AND the box is freshly rebooted (calm load, working directory access).
