# findings_wiki/ — machine-local findings, tracked in YOUR fork

The upstream disk_magician repo is machine-agnostic: it ships tooling and this
contract, never actual findings. **Fork the repo, and commit your machine's
findings here in the fork** so they are versioned, pushable, and survive the
machine — a gitignored note or agent memory does not.

## What belongs here

One markdown file per durable, machine-specific finding:

- **Hotspots** — directories that repeatedly eat the disk (build caches,
  worktree pools, run outputs) and what governs them now.
- **Traps** — paths that look deletable but are not (live daemon cwd, a
  worktree hosting a running service, clones with unpushed commits).
- **Root causes** — why a pool grows (creation cadence, missing reclamation)
  and where the fix landed.

Enforcement rules live in `safety.local.json` (see the template at repo root)
— scripts obey that file. findings_wiki is the *knowledge* layer: agents and
humans read it at the start of a cleanup/measurement session and record new
findings as they are discovered. When a finding implies a rule, add BOTH: the
finding doc here and the machine rule in `safety.local.json`, cross-linked.

## Format

Copy `TEMPLATE.md`. Required frontmatter: `title`, `hostname`, `date`,
`status` (`active` | `mitigated` | `resolved`), `paths` (list). Keep one
finding per file; update `status` in place rather than adding duplicates.

## Discovery contract

- `scripts/safety_lib.sh` exposes `findings_wiki_docs` (lists finding docs,
  excluding README/TEMPLATE); `scripts/safety_check.sh --findings` prints them.
- Agent instructions (CLAUDE.md) require reading active findings before any
  cleanup session and recording new traps here.

## Keeping upstream machine-agnostic

Only `README.md` and `TEMPLATE.md` exist upstream. Never include your finding
docs in a PR to the upstream repo — keep findings in fork-only commits
(separate from code commits, so code can be cherry-picked upstream cleanly).
`scripts/findings_lint.sh --upstream` asserts purity; plain
`scripts/findings_lint.sh` validates your finding docs' frontmatter.
