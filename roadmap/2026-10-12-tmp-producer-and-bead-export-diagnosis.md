# Diagnosis: /private/tmp producer and the bead-export gap (2026-10-12)

Both items below were filed as beads (`disk_magician-tmp-full-clones-still-produced-tjkb`,
`disk_magician-br-export-fallback-db-6ye1`). Bead comments are not readable from
GitHub, so the evidence is recorded here.

## 1. The /private/tmp grower is review-lane scratch, not git clones

`/private/tmp` measured 65 GB. It is NOT a pile of repo clones:

- `/private/tmp/worldarchitect.ai` (32 GB) has no `.git` and holds 431 top-level
  entries of advice/review scratch: `adv-10315`, `advice-10376`,
  `advice-fallback-claude-7pRccj`, `advice-fallback-cursor-3DIThv`,
  `advice-pr10364-621b945c.y99p`, `bq-import-block.hL3dkP`, `auth-login-tests`,
  `_attempt0_archive`. The `mktemp`-style suffixes match the `/advice` workflow,
  which deliberately runs against a private /tmp copy so other sessions cannot
  mutate the shared repo mid-review.
- Largest entries: `split-gates` 9.0 GB, `ironclad-review-src.c8q2q2` 6.1 GB,
  `gm-plan-review-VgaG3r` 5.4 GB, `ironclad-review-src.kUFR6P` 2.3 GB,
  `evidence` 2.3 GB, `gate-prep` 1.7 GB, `pr10391` 995 MB, `pw-browsers` 539 MB.
- The other large entries (`pr10364-clone`, `pr10364-clone-opus`, `worldai_claw`,
  `worldarchitect.ai-schema-acceptance.9xLjk3`) are also not repos at their top
  level -- they are lane working directories.
- Corroborating in-repo call site: `testing_mcp/run_level_up_class_repro_suite.sh:216`
  does `mktemp -d "${TMPDIR:-/tmp}/worldarchitect.ai/level_up_suite_XXXXXX"` --
  a second writer into the same fixed parent.

Consequence: the canonical tmp lane cannot reclaim any of it. `cleanup_tmp.sh`
skips entries active within 24h (a dry run proposed removing only a 3 MB gist),
so the pool sits at 60-65 GB and grows.

Fix belongs in the lane implementations (clone/copy destination plus
cleanup-on-exit): `/ironclad` review source copies, `split-gates`, `gm-plan-review`,
`gate-prep`. A durable guard on the disk_magician side is a detector that flags
any multi-GiB `advice-*`/`*-review*`/`*-gates` entry under /private/tmp with its
owning lane.

## 2. Beads created in a worktree do not reach the tracked issues.jsonl

Probe in a fresh worktree at `origin/main`: the checkout has
`.beads/{config.yaml,issues.jsonl,metadata.json}` and no `*.db`.
`br sync --import-only` succeeded (`Tombstone protected: 12 issues`,
`Rebuilt blocked cache`) but created NO local `.beads/*.db`. A bead created
afterwards still did not appear in the repo's tracked `.beads/issues.jsonl`
(verified by diffing before/after). The main checkout also has no `*.db`; `br`
resolves `~/.beads/beads.db` for every checkout, so the tracked `issues.jsonl`
is not the export target of a normal `br create`.

That is a br-side DB-resolution/export defect, not a disk_magician code fix.
Workaround in use: commit a verbatim evidence bundle into the repo
(`roadmap/2026-10-12-worktree-hygiene-and-floor-defects.md`) so remote lanes can
read bead bodies.
