# Disk-audit bead execution goal

Goal bead: `jleechan-qlo5.1`

## Literal goal

Revalidate every bead from the 2026-07-14 disk audit against live state, then execute every still-needed item in parallel.

## Ironclad exit criteria

| Criterion | Executable check | External anchor | Independent verification |
|---|---|---|---|
| Revalidate the complete audit set | `br show <id> --json` for every ID, plus fresh `df`, allocated `du`, Docker, process, launchd, and duplicate probes | Current host and bead database | A non-author lane checks the ledger against live outputs |
| Remove obsolete or duplicate work | `br lint`, `br dep cycles`, and explicit close/supersede comments | Canonical bead graph | Verifier confirms no needed scope was silently dropped |
| Execute independent work concurrently | Lane registry shows non-overlapping write/service scopes and requested/resolved model tier | Actual worker metadata and working trees | Parent checks for overlap and silent model inheritance |
| Complete changes end to end | Targeted tests plus deployment checks appropriate to each changed path | Deployed package/tree or live owning service | Non-author reproduces behavior at the same revision/state |
| Preserve disk and service safety | Dry-run first; exact approval gates for destructive actions; before/after allocated bytes and service probes | Host filesystem, Docker/Colima, Hermes, and launchd | Verifier checks never-delete paths and protected services |
| Exit with no hidden work | Every still-needed bead is closed with evidence or names an exact external blocker after safe work is exhausted | Final bead database state | Fresh final audit; any regression reopens the goal |

Unit-only, mock-only, artifact-existence-only, or implementer-self-report evidence cannot satisfy a production behavior claim.

## Revalidation ledger

| Bead | Initial subject | Live verdict | Evidence / next action |
|---|---|---|---|
| `jleechan-etjw` | Colima growth under runner recycling | Needed | 161 live samples: host free -30.17 GiB and datadisk +18.98 GiB; fix runner lifecycle plus active-backend trim mismatch |
| `jleechan-qlo5` | Corrected audit parent | Needed | Reconcile children and replace false uncommitted roadmap claims before closure |
| `jleechan-tbe3` | Tight-cadence logger | Needed | Ad-hoc monitor lacks lifecycle events, writable sizes, launchd/process/open-file signals, rotation, and parser |
| `jleechan-w5is` | Swing root cause | Needed, depends on logger | Growth is explained; recovery actor remains unproven and needs the durable logger |
| `jleechan-3umv` | Fast recovery incident | Closed as superseded | `jleechan-w5is` is the explicit superset; incident evidence retained in comments |
| `jleechan-ia86` | Gated reclaim decisions | Needed after rescope | Unique work is Simulator inventory plus `.lvl-lanes`/`.agent-*` attribution; other lanes routed to canonical beads |
| `jleechan-igr8` | Frontier coverage integration | Blocked on operational run | Code and uv deploy match at 0.2.9; loaded nightly has `runs=0`; verify first 03:41 cycle or authorized kick |
| `jleechan-mf2b` | Projects/worktrees attribution | Needed | Existing cleanup lacks 95% byte attribution, artifact classes, process/AO ownership, and fresh remote proof |
| `jleechan-vrp3` | Hermes retention and FTS | Closed as superseded | Hermes already implements retention/FTS/VACUUM; remaining step is an explicit product retention choice |
| `jleechan-cga6` | Aside code-sign clone | Needed, cleanup gated | Existing script mislabels active clones in dry-run and lacks race/symlink/per-owner coverage |
| `jleechan-k8gc` | Library caches | Needed | Existing scripts cover only a subset and lack 95% classification plus active/unknown-owner refusal |
| `jleechan-cxg7` | Read-only lane enforcement | Externally blocked | Collaboration spawn schema exposes neither sandbox selection nor immutable write attribution |
| `jleechan-1m1d` | Subagent model-tier audit | Externally blocked | Collaboration and AO user surfaces do not expose requested/resolved model metadata |

## Live revalidation summary

- At `2026-07-14T23:51Z`, `/System/Volumes/Data` had roughly 30 GiB available and Colima occupied roughly 44.5 GiB allocated.
- The active 45-second monitor observed the datadisk grow 18.98 GiB while host free space fell 30.17 GiB; growth stopped after the six runner containers disappeared.
- Runner refill is currently broken by an expired GitHub App token plus stale slot assignments. Ambient GitHub CLI auth is healthy; the token-refresh job is the failing credential path.
- The latest snapshot is schema v2 with 72.5% coverage, one timeout, 234.0 GiB residual, and a partial 219-entry frontier.
- All three delegated revalidation lanes reported `resolved_model=unknown`, directly confirming the model-metadata blocker.

## Safety boundary

`/e` authorizes routine implementation and reversible verification. It does not imply exact destructive gates such as `WORKTREE_APPROVED=1` or `CODE_SIGN_CLONES_APPROVED=1`, does not authorize direct deletion of protected session/state paths, and does not authorize stopping active CI without first proving it is drained.
