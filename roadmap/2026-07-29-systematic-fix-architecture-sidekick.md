# Systematic disk-reclaim prevention architecture — 2026-07-29 sidekick swarm

Mission: `disk_magician-xxv` ("sidekick: save-another-200g-systematic-fix").
Companion doc: `roadmap/2026-07-29-disk-reclaim-plan-sidekick.md`.
Ground truth: `roadmap/2026-07-29-disk-regrowth-rootcause-sidekick.md`
(adversarially verified 2x, same day).

## The question this doc answers

The Mac has 8+ existing prevention layers — a never-delete/protected-path
system, a worktree 14-day-recency rule, ~20 `cleanup_*.sh` sweepers, a
`host-disk-guardian` emergency auto-cleaner, 4 weekly reclaim sweepers, a
daily snapshot job, a frontier-BFS top-down accounting scan, and a
residual-drilldown sweeper — and the disk still sits at 93-97% used. **Why
do 8+ layers still leave the disk this full, and what actually holds the
line?**

## Method

Swarm brainstorm, run as 7 independent parallel subagents (model: sonnet,
no shared context between them), each given the same evidence base and
assigned one distinct architectural angle. Each proposal was then
challenged by a separate, independent adversarial reviewer (also sonnet,
refute-by-default mandate, no visibility into the other 6 challenges).
This doc is the synthesis — written by the sidekick after reading all 14
outputs, not a vote or an average.

## Scorecard — none of the 7 proposals survives unmodified

| # | Proposal | Verdict | Fatal/major flaw found |
|---|---|---|---|
| 1 | Producer-side quota gates (`budget_gate.sh` at AO spawn / `git worktree add` / log rotation) | **Rejected as a standalone fix; viable as a secondary layer only** | Doesn't reclaim a single existing byte (only slows future growth); enforcement is trivially bypassed by any direct tool invocation that doesn't route through the wrapper — the exact gap that caused the 131-worktree burst in the first place |
| 2 | Guardian-candidate clearability reform (self-tagged scratch + "durable elsewhere" quarantine) | **Rejected as written; the core idea is salvageable with fixes below** | "Pushed to origin" does not mean "safe to destroy" — misses `git stash` contents, untracked CI-failure evidence, and a force-push edge case; critically, never intersects with the existing mandatory 14-day recency check, silently overriding it for a whole worktree class |
| 3 | Scratch Lifecycle Registry (manifest-at-creation + owner-reported liveness) | **Rejected as written; the registry concept is the strongest foundation, but self-reported liveness must be replaced** | Owner-writes-its-own-liveness-signal is the exact "telemetry believes itself" trap already seen in this system — a wedged worker (stuck in I/O wait, not dead) never marks itself abandoned and a naive heartbeat cron can report "alive" regardless of whether real work is happening |
| 4 | APFS/snapshot accounting as a first-class monitored subsystem | **Partially survives — genuinely useful, but is observability only** | Reclaims zero bytes by the author's own design (explicitly refuses to pre-approve a deletion heuristic); granting Full Disk Access to any tool is a real, unbounded security/privacy tradeoff on macOS (no metadata-only TCC scope exists) that the proposal doesn't weigh; adding `diskutil` calls to the daily snapshot job risks compounding the documented I/O-wedge failure mode at exactly the worst moment |
| 5 | Heartbeat registry + cross-consistency checker + cheap anomaly probe | **Rejected as sufficient; the anomaly-probe piece survives** | Heartbeats catch process death, not logic bugs that complete "successfully" — the residual-drilldown bug (wrong variable, ran fine, printed "no-op" for 5 days) is *exactly* the failure class this proposal cannot catch; its consistency rules are the two known bugs re-encoded as `if` statements, not a generalizable invariant; the cheap `find -size +5G` probe is still a `stat()`-per-inode walk that can hang the same way `docker system df` hung this pass |
| 6 | Central spool with uniform TTL classes | **Rejected as written — two of its three mechanisms are unsafe or non-functional** | The proposed symlink adapter for AO's `/private/tmp/wa-pr-*` directly violates this repo's own hard rule against aliasing a tool-owned mutable state root; the "hardlink for accounting" alternative reclaims **zero bytes** (deleting one hardlink to an inode that the producer still holds open frees nothing); its own "scratch: 1 day" TTL class collides, unreconciled, with the existing mandatory 14-day worktree floor |
| 7 | Fix the producer tools upstream, not just sweep after them | **Partially survives — 2 of 5 sub-fixes are real and cheap; the rest are honestly labeled as partial or infeasible** | Log rotation for the Cursor CLI doesn't specify a retention cap (risks turning one 42 GiB file into N unbounded files) and may not even work if the process holds the renamed file open without SIGHUP support; the AO/worktree reaper's recency check is not confirmed to call the canonical `worktree_age_days` helper — if it uses `created_at` instead, it reproduces the exact creation-time proxy this repo has already measured wrong (2/30 worktrees, 7.6-day error) |

## The real answer to "why do 8+ layers still leave the disk full"

Reading across all 14 outputs, a single pattern explains almost every
failure in the root-cause evidence, and it is **not** "we lack a cleanup
script for X." It is: **every existing layer trusts a signal that can be
wrong in exactly the situation that matters most, and nothing cross-checks
that signal against an independent source.**

- The guardian trusts "uncommitted = still needed" — wrong for abandoned
  CI scratch, but nothing checks push status independently.
- The weekly sweepers' silence was trusted as "nothing to clean" — wrong
  because they'd simply never fired; nothing checked "did this job run
  recently" against an independent clock.
- The residual-drilldown sweeper trusted its own `residual_delta_gb`
  variable — wrong by orders of magnitude for 5 days; nothing cross-checked
  it against the `residual_gb` field sitting in the same JSON file.
- A heartbeat (if one existed) would have trusted "the process is still
  running" — insufficient, because the process can run and still be wrong
  (exactly the residual-drilldown case) or run and be wedged (I/O-blocked,
  not dead).

This reframes the fix from "add more sweepers" (which is how the system
got to 8+ layers in the first place) to: **add independent cross-checks at
the two or three places that matter most, and make destructive decisions
depend on more than one signal, at least one of which the decision-maker
cannot self-report.**

## Target architecture (synthesized, with fixes applied)

### Layer 1 — Scratch Lifecycle Registry, with externally-verified liveness (fixes proposal 3's fatal flaw)

Keep proposal 3's manifest-at-creation design (a registry entry — path,
owner, task ref, TTL — written when AO/CI create a scratch worktree), but
**liveness is never self-reported by the owner.** The sweeper itself
verifies liveness externally: process-tree/PID-alive check performed BY
the sweeper (same mechanism proposal 7's AO reaper already uses
correctly), cross-checked against whether the owning task's own
orchestration system (AO) independently reports the task as still queued
or running. A registry entry with a dead-and-unconfirmed-elsewhere owner
is the only thing eligible for the next layer. Add a drift-detector
(`find /private/tmp/wa-pr-* -maxdepth 1` diffed against the registry every
sweep) that alerts — doesn't silently degrade — when scratch exists
outside the registry, so the "3 chokepoints undercounts the real producer
surface" gap becomes a visible, tracked signal instead of an invisible
adoption gap.

**Scope correction (found via `/ms` recall of bead `disk_magician-si1`,
added post-scope-change):** this liveness primitive must be shared across
repo boundaries, not disk_magician-only. `host-disk-guardian` and
`cleanup-ao-sessions` are separate launchd jobs living outside this repo
that delete worktrees with **no 14-day recency floor at all** — currently
low blast-radius because `host-disk-guardian`'s glob is scoped to
`/private/tmp/wa-*`, but `HOST_DISK_GUARDIAN_WORKTREE_GLOB` can widen that
to `~/projects/worktree_*`, at which point a worktree edited today whose
PR merged last week becomes deletable with no age check whatsoever. Any
version of Layer 1/2 that only wires this liveness+recency primitive into
disk_magician's own scripts, and leaves the cross-repo sweepers on their
current unaudited or 1-day-floor logic, has not actually closed this gap —
it has only closed disk_magician's slice of it while leaving the
higher-blast-radius sweepers untouched. Porting `worktree_recency.sh` (or
routing those jobs through disk_magician's own gate) is in scope for
Layer 1's build, not a follow-up.

### Layer 2 — Guardian eligibility, hardened (fixes proposal 2's fatal flaws)

The "durable elsewhere" test from proposal 2 is real and correct as ONE
input, but is never sufficient alone. A candidate is eligible for
emergency-tier reclaim only if **all** of: (a) Layer 1 says the owner is
confirmed dead/abandoned, (b) no unpushed commits by object-reachability
(`git cat-file`-based check against the remote, not ref-name ancestry —
closes the force-push blind spot), (c) `refs/stash` is empty and no
known-evidence file patterns (`*.log`, `core.*`, `.pytest_cache/`) are
present without being archived first, and (d) — this is the fix that
proposal 2 explicitly failed to include — **it independently passes the
existing, unmodified `worktree_is_recently_active` / 14-day check.** The
new EMERGENCY tier never overrides the 14-day floor; it only removes the
"uncommitted = automatic veto" rule for candidates that clear all four
gates. Action is quarantine (compressed archive, capped size) with a
mandatory weekly human-visible review report of what's queued for
eviction — not silent LRU deletion — so the archive doesn't become a new,
unreviewed, permanently-growing liability.

### Layer 3 — Cross-derivation checks, not pattern-matched rules (generalizes proposal 5's surviving idea)

Instead of hardcoded `if residual_gb > 50 and outcome == "no-op"`-style
rules (which only catch bugs already found), every sweeper that makes a
threshold decision must log the **raw inputs** it read (e.g., "read
`residual_gb=406.5` from `disk_snapshot.json`, threshold=10, verdict=
drill-down") to a structured log. A separate, cheap, independent checker
re-derives the verdict from the same snapshot file using its own
independent read of the field — not the sweeper's cached value — and
flags a MISMATCH if the sweeper's stated verdict doesn't match what an
independent re-read would produce. This is the generalized version of
"residual + no-op is a contradiction": it would have caught the exact
variable-naming bug (sweeper says it read X, independent check reads a
different field entirely and gets a materially different value) without
needing to know in advance what the bug would look like. Combine with
proposal 5's cheap anomaly probe (`find -size +5G -mtime -2`, inode-only)
for single-file runaway detection, but give it a hard per-invocation
timeout and skip-with-alert (not hang) if the filesystem is unresponsive —
never let a monitoring probe become another thing that can wedge.

### Layer 4 — Sweeper heartbeat + freshness, tightened (uncontested piece of proposal 5)

30-min cadence, staleness threshold = 2× each sweeper's own declared
period (not a blanket 7 days), because this is real and cheap and would
have caught the 4-day snapshot-job outage in under a day instead of after
a human investigation. This layer only catches non-execution — Layer 3
above is what catches wrong-but-completing execution. Both are needed;
neither substitutes for the other.

### Layer 5 — Two real upstream fixes, done now (the uncontested half of proposal 7)

`ez-gh-actions` container memory limit + bounded restart backoff, and a
size-capped rotation wrapper around the Cursor CLI invocation with an
**explicit total retention cap stated in bytes** (not just a rotation
trigger — the critique correctly identified that a trigger without a cap
just spreads one big file into many). Both are cheap, config-only, and
don't depend on any of the harder architectural layers above.

### Layer 6 — APFS/TCC visibility, not deletion (fixes proposal 4's scope, keeps its value)

Fold `diskutil apfs listSnapshots` / `list` into the existing daily
snapshot job as proposed, but every such call gets a short timeout with
skip-and-flag-stale (not block) if it doesn't return quickly, given this
exact system's documented I/O-wedge history. Do **not** grant Full Disk
Access to any *unattended, launchd-scheduled* process — the security
tradeoff (a standing, unattended process with unscoped filesystem-wide
read access, with no way to narrow the TCC grant) is not justified by an
accounting improvement alone for that class of process. Instead, surface
the TCC-blind fraction explicitly as `tcc_blind_spot_gb: unmeasured` in
every report, so residual numbers never silently imply completeness they
don't have. **Snapshot deletion stays a standing needs-operator-decision
item, never auto-executed** — the rollback-safety question this pass's
critique raised (does macOS actually self-clear these, and under what
confirmed condition) is unresolved and should not be worked around by a
downstream heuristic; it is now also confirmed (via `/history` recall)
that a 2026-07-22 attempt to delete these snapshots failed outright for
lack of sudo under the LaunchAgent, which is itself a durable structural
reason this can never become an automated action, not just a temporary
caution.

**Reconciling with the reclaim plan doc's FDA recommendation (added
post-scope-change):** the reclaim plan proposes granting FDA specifically
to **cmux** — an interactive terminal application the operator actively
drives — not to an unattended background daemon. That is a materially
different risk profile than the one this layer rejects: an
operator-present, interactively-used tool is not "a standing, unattended,
launchd-scheduled process." The two documents are not in conflict; this
layer's rejection is scoped to unattended automation specifically, and the
reclaim plan's FDA-to-cmux option remains the recommended lowest-risk path
to shrinking the TCC-blind measurement gap. If FDA is ever considered for
an unattended `disk_magician` sweeper itself, that remains rejected per
this layer.

**FDA status correction (2026-08-27):** The current interactive shell can read
`~/Library/Application Support/MobileSync`, `~/Library/Mail`, and
`~/Library/Messages`; the FDA-to-cmux recommendation above reflects the older
2026-07-29 status. The scanner still needs an in-process access preflight and
must report any remaining denied paths, because FDA availability by itself does
not establish full attribution.

## Explicitly rejected mechanisms (with the rule that kills them)

- **Symlinking a tool-owned mutable scratch root (e.g. `/private/tmp/wa-pr-*`) into a central spool.** This repo's own hard rule: "Never replace a tool-owned mutable state root ... with a whole-directory symlink to another live state root ... Any exception must prove source and destination resolve to distinct physical paths." A symlink redirect has no distinct physical path by construction — disqualified on its face, not by degree.
- **Self-reported liveness/heartbeats as the sole reclaim-eligibility signal.** The evidence base's dominant failure mode (dozens of zero-reclaim guardian firings, a sweeper that ran "successfully" while being wrong for 5 days) is precisely a system trusting its own reporting. Any new mechanism that repeats this pattern — an owner marking itself alive/done/abandoned with no external check — is rejected regardless of which proposal it came from.
- **Any automatic APFS snapshot or TCC-path deletion.** Kept as a standing operator-decision item per the reclaim plan doc; this doc does not propose a pre-approved automation for it, and explicitly recommends against one until the rollback-safety question is answered with real evidence (e.g., a documented case of macOS itself clearing an equivalent snapshot after a confirmed-complete update), not inferred from elapsed time or reboot count.

## What this architecture does NOT solve (stated honestly, not glossed over)

- **The 291-406 GiB unattributed residual.** Layer 6 makes it *visible and
  labeled*, not smaller. Actually shrinking it requires either an operator
  decision to grant FDA (rejected above as not worth the tradeoff) or an
  operator decision to thin APFS snapshots (also rejected as an
  automation, kept as manual operator action). No proposal in this swarm,
  survives-with-fixes or not, closes this gap — it is structurally outside
  what a downstream tool can safely automate.
- **Colima's sparse-disk wedge under host pressure.** Confirmed a genuine
  Lima/QEMU architecture limitation, not fixable from this repo. The
  existing documented recovery recipe (`colima stop && colima start` +
  `fstrim`) remains the ceiling; Layer 5's scope does not include this.
- **AO task *hangs* (not crashes).** Layer 1's externally-verified
  liveness check catches dead-owner scratch; it does not catch a task that
  is alive but stuck forever with no forward progress. That gap requires
  an actual idle-timeout feature inside AO itself — out of scope for a
  disk_magician-owned fix, tracked as a cross-repo follow-up, not solved
  here.
- **Unexplained worktree deletion, root cause unknown (bead
  `disk_magician-y7t`, open, added post-scope-change).** Three worktrees
  vanished on 2026-07-26 despite being classified PRESERVE+young by
  `worktree_hygiene.sh` minutes before they disappeared — an exhaustive
  investigation (every launchd job, crontab, macOS unified log) found no
  script or job with `--execute` + `WORKTREE_APPROVED` set anywhere,
  ruling out every automated path this repo knows about. **This
  architecture's Layer 1/2 externally-verified-liveness design does not
  claim to prevent a recurrence of this specific incident, because the
  mechanism that caused it is still unidentified** — a new layer cannot be
  claimed to close a hole nobody has located yet. Any future sweeper that
  touches worktrees, including ones proposed in this doc, should be
  treated as a suspect class until this bead closes, not assumed safe by
  construction.

## Phased implementation order

1. **Already done this pass:** residual-drilldown gate fix (bead
   `disk_magician-nea`, commit `144845a`) — this is Layer 3's simplest
   possible instance (an independent-value check would have caught it
   immediately) and was fixed directly rather than just documented, since
   it was a <10-line mechanical bug with a verified root cause.
2. **Cheap, config-only, do next (Layer 5):** ez-gh-actions memory/restart
   config; Cursor CLI log rotation wrapper with an explicit byte cap.
3. **Layer 4** (tighten existing `sweeper_health_check.sh` cadence/
   threshold) — smallest code change, reuses existing infrastructure.
4. **Layer 1 + Layer 2** together (they share the externally-verified
   liveness primitive) — the largest build, but the piece that actually
   lets `host-disk-guardian` start reclaiming AO scratch instead of
   reclaiming zero bytes for the fourth day in a row.
5. **Layer 3's cross-derivation checker** — needs Layer 4's structured
   logging as a prerequisite (can't cross-derive from unstructured log
   lines).
6. **Layer 6** — lowest urgency; pure visibility improvement, no reclaim
   dependency on it.

## Publishability gate

- **Redaction sweep:** no secrets, tokens, or credentials appear in this
  doc or its companion; all paths are local filesystem paths already
  documented in this repo's own CLAUDE.md.
- **Numeric consistency:** the 291 GiB and 406.5 GiB residual figures are
  presented as two distinct measurements from two different tools/times
  (frontier scan 2026-07-28T11:23:50Z vs. live snapshot this pass),
  consistent with the "never mix measurement passes" rule — not
  reconciled into a false single number.
- **Policy lens:** every proposed mechanism was checked against the
  never-delete list and the mandatory 14-day worktree rule; two mechanisms
  that violated them (spool symlink adapter, guardian override without a
  14-day intersection) are explicitly rejected above, not softened or
  buried.
