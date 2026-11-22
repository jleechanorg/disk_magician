# Disk Magician legacy removal design

The desired end state is one installed Rust Disk Magician runtime. Rust discovery already exists on main. The current installed package still routes cleanup through Python and Bash. Remove the generic Rust-to-legacy forwarding now. Then remove each remaining explicit adapter together with its legacy implementation once the replacement covers the caller, or the caller has an explicit retirement. The operator's legacy-removal request authorizes deleting obsolete code. Existing cleanup holds and live ownership rules still apply.

## Remaining functionality

| Function | Proposed Rust owner and boundary |
|---|---|
| Exact Scratch cleanup | Extend the current manifest and target coordinator to cover the requested legacy directories. Capture same-volume hierarchy and identity without following symlinks. Apply the explicit six-hour cutoff only to nominated data and preserve active owners and evidence holds. Revalidate the exact selection and finish with recorded outcomes. Current positive verdicts for old directories demonstrate demand for this capability. |
| Quarantine history and recovery | Retain a reader and restore path for existing quarantine entries. Drain in-flight legacy operations before switching writers. The new direct route uses durable per-target intent and completion records, with recovery that distinguishes missing, replaced and unchanged paths. Sync a recorded intent before entry removal, sync the affected directory before committing completion, and publish a receipt only after completion. Reconcile interruption by the bound identity. Hold replaced entries. For a partially removed tree, resume only enumerated entries whose identity still matches. Persist each outcome so replay is idempotent. |
| Leases, protection and reserve | Adopt the existing lease formats and protection rules. Producer resume and cleanup claim coordinate on the same target or overlapping ancestor. Keep the ballast repair contract and verify mount identity. Keep verdict discovery independent from writer coordination. |
| Scheduled Scratch, temp and volume jobs | Point launchd and systemd at the installed Rust cleanup commands. Preserve configured floors, scope, exit codes, and receipts. Transfer one active writer generation at deployment. Disable old launchd and systemd writers, verify their process trees exited, and retire their runnable package entry points before enabling Rust. Check stale scheduler launch and restart behavior. For rollback, disable and drain Rust writers before activating the pinned rollback package. This deployment transition is independent of routine per-target cleanup. |
| Snapshots and auxiliary callers | Port snapshot and publication before transferring their schedules. Compare remaining production entry points against the existing diskm-retained-capabilities-2026-11-20.md register. List the shipped aliases, installer hooks, job definitions, runnable helpers and their transitive runtime dependencies. Explicitly retire obsolete callers and remove their scheduler or installer references in the same change. |

## Assumptions and Recommended Defaults

- Choose one Rust entry point with the existing command aliases. Help and unsupported commands resolve locally. Track each compatibility call by its command rather than forwarding unknown verbs.
- Prioritize age-targeted cleanup and recovery. This removes the operational bottleneck. Keep the read-only age index independently deployable.
- Preserve existing operator holds and the configured policy. Deletion runs against exact nominations after identity and owner rechecks. The age report supplies a candidate set.
- Retain install rollback through an existing pinned package artifact and conservative state readers. Delete superseded source and package wiring after the corresponding command or job is verified at its installed entry point.

## User-story audit

As an operator, I want the installed Rust tool to handle cleanups, so that a six-hour request follows the supported exact-path route.

- I can preview exact old paths, choose a supported directory and see its final verdict.
- When a producer resumes or a selected path is replaced, the path remains and the command explains the hold.
- After an interruption I can inspect the receipt and recover without deleting a replacement.
- Scheduled jobs report the revision that performed the work.

Update the operator playbook and its command index with examples captured against the replacement build.
