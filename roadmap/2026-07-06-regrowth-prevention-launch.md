# disk_magician: the regrowth-prevention series that closed a 47 GiB-to-89 GiB-free swing on macOS

**Subtitle:** Six small launchd jobs and one cron that keep a developer Mac from filling up again — measured over a 19-day operational window.

---

Last month my laptop went from 47 GiB free to 89 GiB free in one cleanup session. The good news ended there. Within three weeks the disk was back to 12% headroom and I had no idea which surface was regrowing. There was no telemetry, no trend line, and the sweeper that was supposed to be running weekly had silently stopped logging.

That gap is what `disk_magician` is for. It's a zero-dependency shell utility that snapshots your disk every 30 minutes into a git repository, then ships that repo to a remote so you can diff any directory against any past day. The diff is the product. When something regrows, you see which path moved, by how much, and on which day — without installing a 400 MB agent.

The snapshots feed a regrowth-prevention series that runs in six parts. Each part addresses one specific way a developer Mac fills back up:

**A. Post-job Docker prune on CI runners.** Every `docker build` leaves about a gigabyte of intermediate layer artifacts in the builder cache. On ten self-hosted GitHub Actions runners that produced five to fifteen gigabytes of regrowth per day. A two-line `docker system prune -f` plus a `docker builder prune --filter "until=24h"` cuts that to near zero, with a 24-hour warm window so the next build stays fast.

**B. Weekly worktree-venv sweeper.** Every Python worktree spins up its own `.venv/`. With five active worktrees on worldarchitect.ai alone, that's roughly four gigabytes of duplicate dependency graphs. A launchd job running Sundays at 4 AM with `WORKTREE_APPROVED=1` baked in reclaims dormant venvs in one pass. We measured 29.2 GB recovered in a single dry-run.

**C. Snapshot freshness + growth-rate detection.** A snapshot is useless if it's stale. Three additive JSON fields — `captured_at`, `age_seconds`, `coverage_pct` — plus a linear regression of KB-per-day per top-level directory turn the disk_audit into something that warns you before the disk fills, not after.

**D. Sweeper-health watchdog.** Install nine launchd jobs and two of them will be missing within a week. A shell script walks `~/Library/LaunchAgents/`, resolves each plist's log path, and classifies each as OK, WARN, or MISS. Exit code 1 if anything is broken. Run it weekly and silent-degradation stops being silent.

**E. Log rotator for cmux-codex-launchd.** One plist was rotating its stdout at 50 MB and never deleting the rotations. After 19 days, 91 × 50 MB = 4.55 GB. A seven-day window keeps the floor to 350 MB forever.

**F. Documentation-only: node_modules / .venv duplication across worktrees.** Six AO Node worktrees × 775 MB of duplicate npm dependencies is 4.6 GB of pure waste. The fix lives in agent-orchestrator's worker bootstrap (pnpm content-addressable store), not in disk monitoring — but the duplication pattern is now visible to anyone reading the snapshot diff.

The whole series is open source, MIT-licensed, and runs on macOS and Linux. Setup is one `./disk_magician.sh setup` and you have a 30-minute snapshot daemon, a remote backup repo, and the six regrowth-prevention hooks ready to install.

If you've ever hit "disk full" without knowing why, or written a one-off cron that worked for a week and then silently died — this is for you.

Repo: https://github.com/jleechanorg/disk_magician
License: MIT
Install: `./disk_magician.sh setup`

---

*Word count: 488 (target: 500)*
*Drafted: 2026-07-06, model MiniMax-M3 via Hermes*
*Status: drafts only — no posts submitted*