---
name: diskm
description: Use for any disk space request — "clean disk", "reclaim N GiB", "free space", "disk is full", or /diskm. One-prompt playbook distilled from the 2026-11-13 session that recovered ~250 GiB across macOS and jeff-ubuntu. Drive every action through the `diskm` binary; order matters more than tool choice.
---

# diskm — reclaim disk, in the order that actually works

**Canonical owner of this procedure.** `/diskm` resolves here. Cross-references:
`~/.claude/skills/disk-root-cause/SKILL.md` (measurement rule),
`../../AGENTS.md` (tool contract), `~/.claude/skills/scratch-space/SKILL.md`.

Everything below was measured on 2026-11-13 on macOS + jeff-ubuntu. Steps 1–2
produced ~108 of ~250 GiB and are the only **structural** wins (they stop regrowth).
The diskm binary is the primary interface; a direct command appears only where no
diskm subcommand exists yet, and that gap is named explicitly.

---

## Step 0 — Find the producer before reclaiming anything

Most "cleanup doesn't work" reports are a producer outrunning the cleaner. Four
diskm checks, then three things diskm does **not** alert on:

```bash
diskm status                           # free/used per volume, fleet health
diskm check-launchd-fleet              # macOS: is the sweeper fleet even loaded?
diskm reclaim-ledger --read-existing   # precomputed per-host reclaim list
diskm history growth-top10 --days 7    # floor + top growing buckets
# NOTE: `tmp-scratch-sweep`, `volume`, and `measure` do not implement --help
# (they run, or print nothing). Verify with a real invocation, not a help probe.

# (a) a zero-yield full-disk scan freezes I/O and frees nothing
pgrep -f 'disk_frontier_scan\.py' | wc -l

# (b) out of processes — fork failures masquerade as unrelated tool bugs
ps -e | wc -l; sysctl -n kern.maxprocperuid      # macOS: maxprocperuid
ps -eo comm | sort | uniq -c | sort -rn | head -5

# (c) a live build refilling faster than any sweep
top -l 2 -n 0 -s 2 | grep 'CPU usage' | tail -1
```

**Measured:** a stray 21-hour `git-upload-pack` chain held **8,142 processes
against an 8,000 per-user limit** (load 695). Forks failed with
`Resource temporarily unavailable` and every cleanup looked broken. Killing it:
8,142 → 2,125 procs, load 695 → 19. **Nothing surfaced this** — not diskm, not
the sweepers, not any alert. Always run step 0.

If (a) is running with no output for hours, stop it. If (b) is >90% of the limit,
find the duplicated `comm` and trace its root parent before killing (never
`pkill -f` with multi-token patterns).

---

## Step 1 — Sparse exclusion of a tracked data directory (biggest win)

**A tracked data directory is cloned into every worktree.** Here `~/roadmap`
tracked 289 telemetry files (7,338 MB) and each of 23 worktrees held a **physical
copy** (different inodes, not hardlinks): each worktree measured 10,079 MB, 82 GB total.

It **cannot be deleted** — `prw_metrics.py:543 export_published_telemetry()` reads
it from `origin/main` via `git ls-tree`. Exclude, never remove:

**Preview the exact command you will apply, with the same roots and exclusions.**
`cleanup-worktrees` and `slim_worktree_checkouts.sh` are different tools with
different default roots, so previewing one and applying the other shows you a
target list that is not the one that will change.

```bash
# preview — same script, same explicit scope, dry-run
WORKTREE_APPROVED=1 bash scripts/slim_worktree_checkouts.sh --dry-run \
  --exclude 'docs,dashboards/prw/telemetry'

# apply — identical arguments, only --dry-run -> --clean
WORKTREE_APPROVED=1 bash scripts/slim_worktree_checkouts.sh --clean \
  --exclude 'docs,dashboards/prw/telemetry'
```

Those two commands do **not** pass `--roots`, so they cover the helper's **default
scope**, not a reviewed list. If you need a narrower or explicitly reviewed set,
pass `--roots` to *both* invocations identically. Never describe a default-scope run
as explicit.

`--exclude` is **comma-separated** and refuses automatically when uncommitted work
sits under an excluded path. Measured: 10,079 MB → 2,741 MB per worktree,
**~7.3 GB each / 55 GB total**; branches and clean status survive; all 289 files
stay in git.

**Find your own equivalent first** — never hardcode this machine's paths:

```bash
du -sm ~/.worktrees/*/ | sort -rn | head -5      # which repo dominates
diskm measure --only <path>                     # confirm the child breakdown
```

---

## Step 2 — On Linux, delete inside Scratch AND trim (98% is the trim)

`~/Scratch` on jeff-ubuntu is a **sparse 200 GiB ext4 image** loop-mounted from
`~/.local/share/disk-magician/volumes/scratch.ext4`. Measured:

```
deleted 57 GB inside Scratch     ->  host gained  1.1 GB   (2%)
fstrim -v /home/jleechan/Scratch ->  56.2 GiB trimmed, host +53.5 GB   (98%)
```

`diskm` owns this: `tmp-scratch-sweep --scratch-only` runs the prune **and** the
FITRIM ioctl (`scripts/volume.py` issues a raw `FITRIM` ioctl — do not grep for an
`fstrim` binary to prove it exists). Use diskm first:

```bash
diskm tmp-scratch-sweep --scratch-only --clean
diskm volume status --json --snapshot          # confirm trim + free
```

When `sudo` has no cached credential, use the **approved administrative route** —
`diskm volume trim` — not a hand-rolled privileged container:

```bash
losetup -a | grep scratch
diskm volume trim scratch --admin-transport docker \
  --admin-image-id sha256:<64-hex-digest> --execute
```

`scripts/volume.py:1520 linux_trim_cmd` pins that image by **digest**
(`^sha256:[0-9a-f]{64}$`) and confines the mount and capabilities. Never
substitute `docker run --privileged -v /:/host --pid=host` plus a mutable image
tag: that escalates to uncontrolled host root and is strictly weaker than the
route the tool already provides. If no pinned `trim_admin_image_id` is configured,
report the missing configuration rather than improvising one.

`sudo /usr/sbin/fstrim -v <mountpoint>` remains correct when you already hold an
approved credential. It is not permitted as a password-bypass step.

**macOS** `/Volumes/diskm-scratch` is a real APFS volume, not an image: deletion
returns host bytes directly and there is no trim step. **Never** `fstrim --all`
while Colima is wedged (qcow2 diffdisk — use `diskm cleanup-colima`).

Any Scratch plan not ending in a trim is 98% wasted, and `df /` read straight
after deleting inside the image is a **false** reading.

---

## Step 3 — Lock discipline (the #1 self-inflicted failure)

`scratch_cleanup.lock` is shared by the tmp cleaner, the scratch cleaner **and**
the scheduled sweeper. Default wait is **20 s**, after which the run prints
`skipped, scratch lock held` and **exits 0**.

Measured: five of my own background runs held it, so `diskm-scratch-reclaim` emitted

```json
"outcome": "skipped_lock", "exit": 0, "freed_bytes": null,
"reason": "scratch lock held by another cleanup; no Scratch child ran"
```

and `volume_reclaim` — the only FITRIM path — never ran. Several turns were spent
diagnosing downstream "gate defects" caused by my own concurrency.

```bash
pgrep -af 'cleanup_scratch_top_level|cleanup_tmp\.sh'   # BEFORE theorising
lsof ~/.disk_magician_locks/scratch_cleanup.lock
DISK_MAGICIAN_SCRATCH_LOCK_WAIT_SECONDS=1800 diskm ...  # queue instead of losing
```

**One scratch cleaner at a time. Never restart a budget-mode run mid-flight** —
budget mode completes a full LRU ordering pass before the first eviction, so a
restart discards all progress (observed 9.9 → 36 → 44 → 154 GiB with long
plateaus then cliffs).

---

## Step 4 — The diskm stack, serially

They contend on the same lock; run one at a time.

```bash
diskm cleanup-xcode --clean                 # macOS: DerivedData + simulator caches
diskm prune-aside-sessions --clean          # see trap: dry-run overstates
WORKTREE_APPROVED=1 diskm cleanup-worktree-deps --clean
WORKTREE_APPROVED=1 diskm cleanup-worktree-venvs --clean --roots ~/.worktrees
WORKTREE_APPROVED=1 diskm cleanup-worktrees --clean --repos <repo>
diskm cleanup-tmp --clean
diskm vacuum-hermes-state --clean
diskm cleanup-codex-db --clean
diskm cleanup-dev-caches --clean
diskm cleanup-colima --clean
```

**macOS simulators** have no diskm subcommand — use `xcrun` directly, and never
delete a Booted device:

```bash
xcrun simctl list devices | grep -c Booted     # must be preserved
xcrun simctl delete <UDID>                     # only non-Booted, non-unavailable
```

Measured: 39.5 GB → 6.2 GB (17 devices removed, 2 Booted kept).

---

## Step 5 — When a gate refuses: FAIL CLOSED

**A cleaner's refusal is the answer, not an obstacle to route around.** The C14
verdict encodes lease, secret, content-preservation and ownership reasoning that
four ad-hoc probes cannot reproduce. `lsof -D | wc -l` in particular prints `0`
when `lsof` itself fails, so it can manufacture false confidence.

When a gate returns `kept:*`, do this in order:

1. **Resolve the reason** — `grep -oE 'kept:[a-z-]+' | sort | uniq -c`, then reason
   about each one (see the table at the end of this step).
2. **Fix the classifier if the reason is wrong** — that is a code change with tests,
   not a deletion. That is how the grpc `_credentials` case was solved.
3. **Report and stop** when the reason is correct.

Deleting past a refusal requires an **explicit, scoped operator decision for that
named path** — a human saying yes to that path. It is never implied by a general
"clean disk" instruction, by the agent's own judgement, or by a prior approval for
a different target. Do not perform it on your own initiative.

If an operator does authorize a specific path, the mechanical form is a **literal
path** — both cc-safety-net and destructive_path_guard.py reject a variable-target
delete and any loop over a computed target.

**Do not hand-roll a substitute safety proof** (ad-hoc lsof, find, stat pipelines).
The canonical result is the authority: `bash scripts/safety_check.sh <path>` plus
the C14 verdict itself. Bespoke probes add a second, weaker opinion and they fail
in ways that read as "safe":

- `lsof -D` is not a supported option (recursive is `+D`); piped to `wc -l` its
  error becomes `0 open files`.
- `lsof +D` returns exit 1 for *nothing open*, for *found something*, and for a
  *bad path* alike (measured, lsof 4.91) — exit status cannot discriminate.
- Piping any of them discards the status entirely.

If a human needs an audit trail for an authorized deletion, record the
`safety_check.sh` output and the C14 verdict for that exact path. Never present a
bespoke command as proof of safety.

**`kept:` reasons are not all bugs.** Resolve each one before believing a number:

```bash
grep -oE 'kept:[a-z-]+' <cleaner-log> | sort | uniq -c | sort -rn
```

Same verdict string, opposite meanings (all measured):
- `kept:not-pushed` on a worktree **2,205 commits ahead, 0 origin refs** → **correct**;
  real unpushed work. Never discard without explicit operator authorization.
- `kept:secret-like` on `grpc/.../_credentials/roots.pem` → **bug** (public CA bundle).
- `kept:secret-like` on the **directory** `_credentials/` → **bug** in the filename
  rule; fixed via `exempt_name`'s `_private_dep_dir` rule.
- `kept:secret-like` on a **directory** named `*.pem` → **correct**; a masquerade
  that must stay protected (`tests/test_artifact_verdict.sh`).
- `kept:unproven-content` on a whole venv → **policy** question: a venv is
  dictionary-rebuildable and arguably needs no per-file proof.

---

## Traps (all measured; each cost real time)

| Trap | Reality |
|---|---|
| `prune-aside-sessions --dry-run` → 2.00 GB | `--clean` reclaimed **0**; the preview counts bytes *before* the C14 verdict (bead `sth8`) |
| `cleanup-worktree-venvs` default `--roots` | `$HOME/projects`, **not** `~/.worktrees`. A bare run succeeds and reclaims zero — pass `--roots` explicitly |
| `DISK_MAGICIAN_SCRATCH_MIN_KB` | **Inverts**: descends into a big dir and keeps its 16 KB children, so the 8.1 GiB parent stays ineligible. Never use it to accelerate |
| Parallel worktree lanes | Three concurrent lanes → **37/37 LEASE-KEEP**, zero bytes. Serial only |
| `cleanup-worktrees --targets-file` | Rejects targets outside `--repos` ("not a recognized linked worktree"). Scope per owner repo |
| Symlinked venvs | 297 of 404 "venvs" were **symlinks** to one shared store; `find -type d` overcounts 6×. Check `[ -L "$v" ]` |
| Worktree age via `stat .git` / `stat <dir>` | Banned proxies — they measure creation, not activity. Use `worktree_is_recently_active` |
| `~/roadmap` telemetry | Required in git by `prw_metrics.py`. Exclude it, never delete it |

---

## Floors — the only honest scorecard

Report `current − floor`; never a raw "freed" number.

```bash
diskm history diff --days 7        # canonical; falls back to partial when stale
diskm history growth-top10 --days 7
```

If the ledger reports no valid floor, fall back and **label the source**: the daily
minimum of `host_disk.used_kb` in `~/.disk_magician_state/disk_observer.jsonl{,.1,.2}`
(df-only), and say how many days it actually covers. A 30-day floor needs 30 days of
data — if coverage is 11 days, say so; never substitute a proxy.

2026-11-13 baselines: Mac 7d floor **612.5 GiB used** @ 11-07; Linux 7d floor
**705 GiB used** @ 11-02. Linux finished **7 GiB below** its floor; Mac finished
**30.5 GiB above**, because `~/.worktrees` regrew mid-session (bead `qxc7`).

---

## The one-prompt form

> "Clean disk on both hosts, target N GiB. Run /diskm."

Expected honest yield from a cold start on this machine: **60–130 GiB per host**,
dominated by steps 1–2. Anything claiming much more without a floor comparison is
measuring the wrong thing.

## Known-unfixed (do not rediscover)

- `diskm-scratch-reclaim` loses to any concurrent cleaner and **exits 0** with
  `freed_bytes: null` — should be non-zero. Bead `mgg2`.
- Worktree automation never deletes (`reap` has no `--execute`). Bead `qxc7` — the
  structural grower that keeps Mac above its floor.
- New roadmap worktrees still pull the full 7.3 GB; the sparse exclusion is applied
  per-worktree, so make it the default in the worktree-creation path.
- No `diskm emergency` subcommand — this playbook is the manual equivalent. Bead `kyo9`.
