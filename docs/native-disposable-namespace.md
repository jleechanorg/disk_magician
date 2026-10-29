# Opt-in Linux native disposable namespace (PR288 follow-up)

This is a separate, explicitly configured **new disposable-data contract**, not
another remover for existing Scratch, worktrees, caches, or leased C14 objects.
It does not change the Mac/Linux 20-minute Scratch job or its strictly-below
50 GiB actual-availability trigger. It does not reclaim the Scratch capacity
domain unless an operator independently provisions an appropriate separate
namespace; no XDG path or capacity relationship is guessed.

## Explicit entry point; installation is separately gated

Use the existing `diskm` entry point, with an absolute user-selected path:

```
diskm disposable init --root /absolute/private/disposable       # plan only
diskm disposable init --root /absolute/private/disposable --execute
diskm disposable run --root /absolute/private/disposable -- producer-command args
diskm disposable clean --root /absolute/private/disposable      # plan only
diskm disposable clean --root /absolute/private/disposable --execute
diskm disposable reconcile --root /absolute/private/disposable --execute
diskm disposable schedule --root /absolute/private/disposable --diskm-bin /absolute/installed/bin/diskm
```

The parent must already exist; init refuses to adopt **any existing root**.
`schedule` renders JSON containing user service/timer text only. It requires an
initialized, currently unprotected namespace and an explicit trusted installed
shared CLI launcher; it records launcher SHA256 and namespace identity. It quotes
paths and refuses unsupported executable characters (including `$`, `%`, quotes,
backslashes and template markers), uses a20-minute OnCalendar timer,
Persistent=false,90-second service timeout and KillMode=control-group. The native
child retains admission across controller death; a killed/failed native attempt
keeps pending intent until explicit reconciliation. `schedule --execute` refuses:
this command cannot install, enable, start or operate a host service. Rendered
units are source artifacts, **not evidence that periodic cleanup is scheduled**.
An authorized operator must verify the reviewed installed launcher and apply the
units separately. Launcher updates are outside the cooperative identity boundary.
The service binds the winning absolute config/safety files, HOME, state directory
and supported shared protection/sandbox overrides, including empty resets. Missing
bound files fail closed; later holds in those files are read on each invocation.
Safety path expansion supports HOME only; unknown environment variables fail
closed instead of silently changing policy in a fresh service environment.
Re-render units after an intentional policy-source/path change; the renderer
does not silently switch existing units to newly selected fallback files.
Initialization fsyncs control inodes and namespace/parent directory entries before
publishing its identity admission record; a durability error prevents admission.

No host installation or activation was performed while developing or testing
this source. The explicit installation path below is for a separately authorized
operator; source approval alone is not permission to activate it. Linux systemd-tmpfiles >=255 is
required for execution. The default binary is `/usr/bin/systemd-tmpfiles`; an
explicit `--tmpfiles-bin` must be a trusted absolute, non-symlink executable.

## Explicit user-unit install/enable and recovery

`diskm disposable schedule-install --root /absolute/private/disposable
--diskm-bin /absolute/installed/bin/diskm --accept-cooperative-producers` is
plan-only. Adding `--execute` explicitly installs the reviewed unit text into
`$XDG_CONFIG_HOME/systemd/user` (default `~/.config/systemd/user`), reloads the
user manager, enables and starts **the timer**, and verifies its manager state.
It does not run an immediate cleanup or claim that a cleanup has executed.
The acknowledgement means every producer/consumer follows the inherited-lock
contract below; it is not a claim that arbitrary existing data became safe.

Installation requires exclusive namespace admission, idle native audit, valid
registered payloads, a trusted shared launcher, and private/non-symlink user
configuration ancestry. An additional installation flock serializes this path.
Manager subprocesses inherit both locks. Existing unit bytes must match exactly;
drift, another resolved fragment, unsupported timer state or a running service
refuses rather than replacing another writer's files. Changing an installed
launcher/policy binding requires deliberate operator reconciliation, not an
implicit overwrite. Manager calls have an8-second bound each and a120-second transaction deadline;
exhaustion leaves pending state if rollback cannot finish. The same shared sandbox
guard covers both user-unit directory and user-manager runtime before writes or
bus access. The manager environment preserves the validated XDG config directory
but drops arbitrary bus/host selectors. Both loaded fragments must resolve to
the expected files; any drop-ins/transient units, foreign timer association or
unexpected effective ExecStart, Environment, environment-file/pass/unset lists,
NoNewPrivileges, UMask or KillMode fail closed before mutation/recovery and after
reload. Install currently requires a simple ASCII launcher path without spaces
or expansion characters; rendering alone supports quoted spaces.

A fsynced transaction records original unit presence, enabled/active state,
new file identities and desired bytes before activation. Ordinary failures stop
and disable only newly activated state, remove only exact identity-bound files
created by this transaction, reload, restore prior state and verify it. Failed
rollback or controller interruption retains an independent admission marker;
ordinary producer and cleanup admission refuses while it is pending, regardless
of whether an installed-journal rename is already visible. The marker binds a
unique transaction ID and namespace identity; mismatches are not adopted. `diskm disposable schedule-recover --root
/absolute/private/disposable --accept-cooperative-producers --execute` explicitly
attempts the same bounded rollback under both locks. It does not claim successful
installation. Unexpected file replacement, drift, corrupt journal or an unbound
file from a crash before identity journaling requires operator reconciliation;
those files are preserved. Exact expected bytes and inode identity are checked
around reload/enable/start and immediately before rollback unlink, including
in-place edits that retain the same inode. No automatic adoption or broad removal
is permitted. This remains cooperative same-user coordination: other policy/unit
writers must honor the installation lock, not race the final check/unlink syscall.
The durable commit point is a successful fsync of the terminal transaction
journal. Only afterward is the admission marker changed to the matching terminal
phase. If this last marker write fails, the command reports incomplete with
`committed: true`: a remaining pending marker blocks and recovery rolls back; a
visible terminal marker proves the prior durable commit and recovery verifies
manager/source state and re-fsyncs finalization without stop/enable operations.
A crash can conservatively restore an older pending marker, never admit an
ambiguous journal-only commit. A recorded predecessor marker permits recovery
of interruption between a new intent and marker advance, before any file/manager
mutation. Verified already-absent/inactive/disabled units are no-op rollback,
not an attempt to stop a nonexistent timer.

Tests intercept live-manager operations in synthetic namespaces. A real
`systemctl --user --no-reload enable` test uses only fixture HOME/config/runtime
(no bus socket) to verify custom-XDG file lookup and enablement symlinks; removing
XDG_CONFIG_HOME genuinely fails lookup. This is not live user-manager, launchd,
or systemd activation evidence.

## Producer/consumer contract and threat boundary

All data is newly allocated as a unique registered `data/<job>` directory by
`disposable run`. The wrapper and producer inherit **both** a shared namespace
admission flock and a BSD flock on that job directory. Environment variables
`DISKM_DISPOSABLE_GATE_FD` and `DISKM_DISPOSABLE_LOCK_FD` identify those FDs.
The process and every descendant/consumer MUST retain both open descriptors for
its entire use of the data. A detached descendant must explicitly inherit them;
programs that close inherited FDs, daemonize without preserving them, pass data
to unregistered consumers, or write data after releasing them are **unsupported**.
Do not put their output here. Their existing C14/lease path remains mandatory.

This is cooperative producer synchronization, **not a hostile same-UID security
boundary**. Mode0700 prevents access by other users but cannot prevent the owner
from replacing files, closing locks, or issuing a native command outside this
entry point. Ancestors must stay stable, owned by root/current UID, and not be
non-sticky group/world-writable. Namespace/control/data/gate identities are
bound to initialization. Repository markers (including bare repositories),
unknown job entries, symlinks, hardlinks, special files, nested mounts (including
same-device bind mounts), foreign ownership/device and Scratch overlaps refuse
cleanup. Shared `safety.local.json`/`DISK_MAGICIAN_SAFETY_FILE` rules
(never_delete, protected_live_paths, needs_decision) and shared protected temp-root
resolution are consulted at admission and every cleanup/reconciliation; payloads
are checked against the existing cross-validated safety matcher. Missing explicit,
unreadable or malformed safety rules fail closed. A root-wide `/` hold in any
category blocks all operations. The existing safe baseline template ships in
the wheel; a clean HOME never falls back to allow-all. Shared fixture sandbox guards
are mandatory when test context is set. Existing Scratch exclusion paths are
resolved before overlap checks. No old registry objects or data are adopted.
Safety-policy writers must not race an active native batch; use the same admission
lock before changing protection of this namespace. Each batch revalidates policy
before native invocation, but no global policy-writer lock is claimed.

## Native deletion and audit semantics

Cleanup takes exclusive namespace admission. It writes and fsyncs a complete
bounded pre-manifest and pending intent before invoking native tmpfiles. The
native child inherits admission, so controller death cannot admit a producer or
reconciler while native deletion continues. Native receives an FD-bound root and
one explicit ephemeral rule: `e / - - - 3d -`. It gets only PATH/LANG/LC_ALL,
not `CREDENTIALS_DIRECTORY` or loader/environment overrides. This matters because
systemd255 reads credential-provided extra rules even with a positional config.

Native systemd255 checks child directory/file BSD locks, **not** the configured
root's flock. Per-job locks are necessary; a root lock alone is insufficient.
The explicitly requested separate disposable age is native `3d`, not the
legacy C14/worktree seven-day floor; that override does not apply to existing
Scratch or repositories. It includes native access/modification/change-time rules;
manifest enumeration uses O_NOATIME and never rewrites timestamps to force aging.
The native process is bounded to30seconds. A complete quiescent post-manifest,
removed paths, remaining count, changes, native return code and diagnostics are
persisted. `observed` means an audited observation, **not** that every old item
was deleted; native exit0 can conceal individual cleanup failures. Timeout or
nonzero returns `incomplete` and CLI75 and retains pending intent until explicit
reconciliation, even when the observed manifest is unchanged. Added entries or changed file/inode/type
are anomalies: incomplete with pending intent retained for explicit reconciliation. Directory metadata changes are reported.

**Native unlink bypasses C14's deletion core and normal deletion log by design.**
This exception applies only to this newly created explicit namespace. Its own
`control/runs/*.before.json`, `*.after.json` and fsynced `control/audit.jsonl` are
the audit mechanism, outside native's data root. Corrupt/truncated audit, missing
identity, bounded-manifest overflow or an incomplete prior intent fails closed.
After interruption, explicit `reconcile --execute` records the new quiescent
manifest and missing paths with `unknown-attribution`; it does not invent a
successful deletion receipt. It then allows subsequent attempts. It cannot heal
corrupt audit history automatically. Control receipts are not native-cleaned;
operator review is required if their bounded limits are reached.

## Hermetic verification and limitations

Tests use temporary synthetic data only. Ubuntu systemd255.4-1ubuntu8.18 packages
were downloaded and extracted under `/tmp/dm-systemd255`, not installed:

- systemd.deb SHA256 `ba37e7dc1e33690d94a1063543d27f9b17c013a20791c3315b2423fbf9e7ae7b`
- libsystemd-shared.deb SHA256 `20210e06618cfc824b19ebc0e2163d72cd57509d947fa71aad8d53d78b808caa`
- Official source: `https://archive.ubuntu.com/ubuntu/pool/main/s/systemd/`

A test-only interposer advances the native process wall clock four days while
leaving the actual3d rule and filesystem timestamps intact. A second test pauses
real native unlink, SIGKILLs the controller, verifies admission remains locked,
then permits completion and verifies unknown-attribution reconciliation. Tests
also demonstrate child-lock preservation versus root-lock bypass, hostile extra
credential rule exclusion, and detached cooperative producer lock inheritance.
The strengthened credential regression first deliberately passes an injected
age0 rule to real255 and observes fresh-data deletion, then verifies the filtered
environment preserves fresh data with the same hostile parent environment.
The cloud sandbox's injected empty `/tmp/.git` marker is masked only in the
fixture harness; production repository protection is unchanged, and a genuine
fixture repository/bare repository is explicitly rejected.

These are isolated native/process/audit proofs, not live-host acceptance,
performance proof, protection for noncooperative consumers, a C14 replacement,
or deployment/merge approval. Privileged Docker FITRIM lifecycle work remains
separately held and is not included in this native namespace change.
