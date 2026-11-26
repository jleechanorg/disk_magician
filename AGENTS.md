# Disk Magician agent instructions

## Primary goal — find and reclaim disposable agent-generated data

**Find the exact files and folders we can safely delete, show the evidence,
then reclaim the verified set when authorized.** Prioritize build and test
outputs, caches, finished-run logs, and completed scratch artifacts.

- **Find.** Check the whole requested Scratch volume, host temp, managed
  worktrees, and relevant roots from the machine's reclaim ledger and deletion
  history. Follow stale children inside mixed-age trees. Measure file content
  age, ignoring Git metadata as a worktree activity signal.
- **Report.** Give exact paths, age, provenance, safety verdict, and estimated
  allocation. Distinguish allocated bytes from apparent size. Include largest
  files examined, any inaccessible frontier, and every omitted or unchecked
  class. A candidate cap, timeout, or directory-only pass makes that coverage
  partial. Flag stale ledger data separately. An explicit sample must say how
  many verdicts it deferred.
- **Reclaim.** Recheck exact eligible paths through the canonical cleaner and
  measure actual free space before and after with `df`. Record removals through
  the existing deletion log. Keep boundary cases visible with their hold reason.
  If the operator requires `/history`, require positive same-lane evidence of
  completed or abandoned work. Missing or inconclusive history keeps the path.
  A live human operator may authorize deletion of anything they choose by
  saying `DELETION APPROVED`; the approval is not limited to a previously
  qualified scope or paths listed alongside the phrase. This overrides cleaner
  holds. Record the approval in the cleanup receipt and use the canonical
  deletion/logging route. Path, mount, and command-safety validation still apply.
- **Editing policy is not deleting.** An operator request to edit this file, a
  skill, or a PR description authorizes that edit with the requested semantics.
  Make it without asking; the edit performs no cleanup, and any deletion stays
  a separate action under the rules above.

## Operating rules

- Use the shared `diskm` dispatch for all disk operations. The packaged
  `disk-magician` name uses the same implementation. No hand deletion, ad-hoc
  cleaner, or second operational dispatcher. Use the canonical worktree
  cleaners and their existing approval and source-preservation checks.
- Start with parallel zero-`du` triage. Read `df`, fleet health on macOS, the
  existing reclaim ledger, and recent growth history. Read machine findings
  and recent deletion receipts. Check 7- and 30-day floors, bucket deltas,
  ledger freshness, and producer rate before a deeper walk. Use the fallbacks
  in the playbook when ledger coverage is missing. Qualify independent cleanup
  lanes in parallel subject to resource and ownership checks.
- Itemise every real directory at or above **100 MiB**, including equality,
  until each measured leaf is a file or a directory strictly below the limit.
  Measure Git, source, and session trees read-only. Report symlinks as link
  leaves. Name any unfinished path and mark coverage incomplete. Never infer
  that there are zero candidates from parent mtime or aggregate size.
- Default disposable cleanup uses the content-inactivity floor `CONTENT_FLOOR_HOURS` in `rust/src/time_windows.rs`. Every default time window is defined only in that file; scheduler templates, docs and other code refer to it and never restate a value.
  A lower floor must be explicitly selected for the invocation through a
  supported override. Use the canonical worktree recency helpers. Age by
  itself grants neither deletion authority nor proof of safe removal.
- Preserve live or unknown owners, active leases, open files, live working
  directories, AO-owned worktrees, secrets, unmeasurable paths, dirty or
  unpushed work, and evidence still referenced by an open PR. Honor machine
  safety rules, mount identity, and preservation checks. Scoped amendments
  (operator decision 2026-11-22) are in the next bullet. The never-delete
  list includes `~/.codex/sessions*`, `~/.codex/state*.sqlite`,
  `~/.codex/log`, and `~/.claude/projects`. Never replace a mutable tool
  state root with a symlink to another live state root.
- Expired Scratch sweep (operator decision 2026-11-22; scheduled on the
  `EXPIRED_SWEEP_INTERVAL` cadence, `diskm scratch-sweep --expired --clean`):
  idle Scratch content is removed on a schedule, whatever the Scratch fill
  level. A registered-Scratch folder whose newest content is past the content
  floor is removed whole unless a hold applies (live or unknown lease owner,
  evidence, `evidence-holds.json`, open files or working directories,
  unrecoverable Git work, incomplete observation).
  Candidates are only direct children of the Scratch root, run directories
  under `runs/<date>/<repo>/<run>`, and direct children of the shared umbrella
  containers `tmp/` and `worldarchitect.ai/` (operator decision 2026-11-26;
  the umbrella containers themselves are never deleted), each judged whole: a
  fresh candidate, or one containing a protected descendant, is kept whole and
  its stale children are never removed. This is the protection for active
  workspaces.
  - **Dirty-work scope, exactly:** uncommitted working-tree edits inside a
    Scratch candidate that is otherwise unheld (every commit independently
    proven recoverable, stale past the floor) are disposable. Leased runs are
    governed by their lease verdicts first.
  - **Secrets:** the secrets rule covers credential stores outside Scratch's
    disposable namespace. Scratch is declared disposable; the job does no
    keyword or pattern routing for secrets.
  - **Machine-local safety rules:** the native cleaner reads none; protection
    is the verified registered-Scratch-root scope plus the holds above.
  - **Accepted residual risks:** (a) a repository outside Scratch that borrows
    objects from a Scratch clone and needs objects no longer reachable from
    that clone's refs or reflog; (b) a public-address remote that itself
    borrows objects from the clone. Both need the operator to have shared a
    clone's object store deliberately.
- Allocate worktrees via `diskm worktree-new`. Use
  `diskm scratch-new <repo> <purpose> --kind build` for disposable run output
  and retain the returned producer lease until the run finishes. Publish
  evidence that must survive cleanup through the durable evidence route.
  Use `diskm scratch-dir` for ad hoc scratch paths. Keep writes on the
  registered volume and preserve `.diskm-ballast`. Follow the playbook's
  pressure and LRU rules only for the requested scope. A usage target supplies
  neither approval nor an exception to the applicable safety checks.

## Before operating or changing Disk Magician

- Use [diskm](.agents/skills/diskm/SKILL.md) for cleanup and
  [disk-root-cause](skills/disk-root-cause/SKILL.md) for disk attribution.
  Use [scratch-space](.agents/skills/scratch-space/SKILL.md) when allocating
  disposable workspace or evidence.
- Read the applicable sections of the [operator playbook](docs/operator-playbook.md)
  for machine-local safety checks, state and ledger paths, approvals, and the
  lightweight PR, package-sync, and deploy requirements. Check the installed
  entry point and scheduler receipts before claiming a job works. Disk-maintenance
  work may cross repositories under the standing authorization in the playbook.

## Rust migration production LOC budget

The Rust migration's agreed maximum is **14,300 physical production lines** (raised from 14,100 on the operator's 2026-11-26 approval; 14,100 had been raised from 14,000 on 2026-11-25, and 14,000 from 13,500 on 2026-11-23) across tracked Rust source files anywhere under the rust directory. Unit test implementations belong under rust/tests. Other tracked production sources there count toward the existing-code net-growth budget.

- Rust production may not exceed 14,300 lines.
- Existing non-generated production code may grow by at most 250 net lines per pull request compared with the PR base. Production source additions and deletions both count. Unit tests, test fixtures, documentation, `.github` tooling, and the generated `src/disk_magician/` package mirror are excluded.

To change either limit, update the policy and the shared values in `.github/workflows/loc-budget.yml` in the same reviewed change.
