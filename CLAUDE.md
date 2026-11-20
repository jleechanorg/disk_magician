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
- Default disposable cleanup uses **48 hours of content inactivity**.
  A lower floor must be explicitly selected for the invocation through a
  supported override. Use the canonical worktree recency helpers. Age by
  itself grants neither deletion authority nor proof of safe removal.
- Preserve live or unknown owners, active leases, open files, live working
  directories, AO-owned worktrees, secrets, unmeasurable paths, dirty or
  unpushed work, and evidence still referenced by an open PR. Honor machine
  safety rules, mount identity, and preservation checks. The never-delete
  list includes `~/.codex/sessions*`, `~/.codex/state*.sqlite`,
  `~/.codex/log`, and `~/.claude/projects`. Never replace a mutable tool
  state root with a symlink to another live state root.
- Allocate worktrees via `diskm worktree-new` and disposable workspaces via
  `diskm scratch-new` or `diskm scratch-dir`. Keep producer leases and use
  the registered volume. Preserve `.diskm-ballast`. Follow the playbook's
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
