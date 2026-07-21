# Generic tool + auto-managed per-machine state repo — design

Decisions (brainstormed 2026-07-21): gh auto-create offer with local fallback · per-machine state
repos (existing shared repo grandfathered; fleet aggregation = non-goal) · state repo tracks
snapshots + evidence + resolved config with the 5G top-down ledger as canonical artifact ·
distribution via `uv tool install`/`pipx` from GitHub · sandbox-HOME E2E exit bar.
Prior art: etckeeper (auto-committed per-machine state repo), chezmoi (curated config repo),
XDG_STATE_HOME convention.

## Exit criteria (all binary; default is NOT-DONE until evidence exists)

1. **Fresh-user E2E (externally anchored):** on this host with `HOME=$(mktemp -d)` and a clean
   PATH sandbox: `uv tool install git+<repo>@<branch>` succeeds; first `disk-magician audit`
   auto-runs `state init`, offers gh creation, and a REAL throwaway repo
   `disk-magician-state-<sandbox-host>` exists on github.com with ≥1 snapshot commit
   (verified via `gh api`, not tool output). Torn down after.
2. **Ledger contract:** the committed `ledger/topdown-5g.json` from that run reconciles exactly
   (Σ leaves + residual = used) and contains zero nodes ≥5 GiB without child breakdown;
   `tests/test_disk_audit_topdown.sh` extended assertions stay green.
3. **Diff names growth:** inject a ≥6 GiB fixture dir, second snapshot, `disk-magician history diff`
   names that bucket with its delta as the top line; residual delta printed last.
4. **Lifecycle branches contract-tested:** offer-accepted / offer-declined(recorded, not re-nagged) /
   no-gh(local-only) / adopt-existing — all via stubbed `gh`, suites green under `/bin/bash` 3.2.
5. **Grandfathering:** on THIS machine, tool adopts `~/.disk_magician_backup` via
   `state_repo_path` config; existing `backup/jeffreys-macbook-pro/` layout untouched; the live
   35-min launchd job commits through the new path for ≥2 consecutive ticks (verified in that
   repo's `git log`, not tool logs).
6. **No-regression:** all existing suites green at merge head; deployed version == pyproject;
   CI + Evidence Gate required checks pass on every PR in the stack.
7. **Anti-gaming:** no criterion satisfied by weakening its own test, mocking the gh layer in
   criterion 1, or committing an empty/partial ledger.

## Architecture

**Bright line:** main repo = code, tests, docs, launchd templates, packaged defaults. State repo =
everything observed/resolved on a machine (snapshots, ledgers, evidence, resolved config).
New machine-data writes to `roadmap/evidence/` in the main repo stop (existing files remain as
historical record).

### State repo layout (`$XDG_STATE_HOME/disk-magician/`, git)

```
MACHINE                       # hostname, created-at, tool version
config/config.json            # resolved machine config, written back each snapshot
snapshots/disk_snapshot.json  # 35-min series; history = git log
ledger/topdown-5g.json        # canonical frontier ledger (≤5 GiB leaves, exact sums, named residual)
ledger/topdown-5g.md          # human rendering, committed alongside
evidence/…                    # dated measurement artifacts; keep newest N=4 files, rest via history
```

### Lifecycle (`disk-magician state …`)

- `init`: marker present → adopt; else `git init` + first commit. Then if `gh auth status` OK →
  one-time offer to create private `disk-magician-state-<hostname>` and set origin; decline is
  recorded and never re-asked; no gh → silent local-only. Auto-invoked by first snapshot/audit.
- `status` / `remote <url>` / `push`: inspect, rewire, manual push.

### Config chain (first hit wins; env-first preserved)

process env → `$XDG_CONFIG_HOME/disk-magician/config.json` → state-repo `config/config.json` →
packaged `config.json.template`. Resolved config written back to the state repo per snapshot so
tuning history is versioned beside the data it governed.

### Snapshot/commit flow (35-min job)

scan → write snapshot + refresh ledger (renderer fails closed on any opaque ≥5 GiB aggregate —
an unexplained 100G node is uncommittable) → `git commit` → push with pull-rebase retry; on push
failure the commit stays local, one warning line, retry next tick. Pre-push secret scan. Evidence
retention inside the state repo (newest N files) so the state repo cannot itself become a leak.

### Diff UX

`disk-magician history diff [ref]` — python over two committed ledgers → bucket deltas sorted by
growth, residual delta last. No shell pipelines (grep-shim corruption class).

### Grandfathering (this machine)

`state_repo_path: ~/.disk_magician_backup` in XDG config; adopt-in-place; new-layout dirs created
beside `backup/jeffreys-macbook-pro/`; nothing migrated or rewritten.

### Error handling

no gh → local-only; push rejected (secrets/size) → keep local + loud log line; state repo
missing/corrupt → re-init with prior dir preserved as `*.pre-reinit-<ts>`; concurrent snapshot
runs already excluded by the existing snapshot lock.

## Struggle ledger this design answers (provenance: /ms + /history 2026-07-21)

allowlist blindness (90–115 GB/mo unattributed) · coverage collapse (46%, 472 GiB residual) ·
Σbuckets>measured clone/hardlink double-count (df3k) · budget exhaustion before /Users (sdlv, ez97) ·
symlink triple-count · mixed-timestamp false sums · aggregate rows hiding real work (6mu5) ·
coverage-change masquerading as growth · grep-shim pipeline corruption.

## Delivery — three PRs

1. `state` module + subcommands + config chain + lifecycle contract tests.
2. Snapshot/evidence write-path redirection + commit/push flow + grandfather adoption.
3. `history diff` + sandbox E2E harness + docs (README install/quick-start for strangers).

Non-goals: fleet aggregator; Homebrew tap; migrating historical `backup/jeffreys-macbook-pro/`
layout; Linux launchd-equivalent (systemd) wiring.
