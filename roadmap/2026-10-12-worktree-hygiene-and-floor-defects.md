# Filed defects (2026-10-12): worktree-hygiene + floor methodology

Evidence bundle for the seven beads below. Each section is the bead body verbatim (br show).

## disk_magician-hygiene-wip-secret-false-positive-damk

matcher does not exclude rebuildable vendor dirs. 2026-10-12 3-day run: many worktrees logged
'NEEDS-REVIEW | dirty; preserve-wip skipped:
ignored-secret:node_modules/@firebase/firestore/dist/firestore/src/api/credentials.d.ts' (a vendored
.d.ts, not a secret). Same bug class as the ignored-directory file-pattern bug noted on oyt4. Fix:
exclude rebuildable components (node_modules, venv, .venv, __pycache__, .pytest_cache, .mypy_cache,
.ruff_cache, .next, .turbo, .gradle, .tox, .eggs, htmlcov, test-results) from the secret-like match,
mirroring has_hidden_state/has_ignored_user_data in scripts/worktree_remove_hook.sh. Acceptance: a
worktree whose only secret-like path is under node_modules is preserve-wip eligible; a real
.env/*.pem/*.key at the worktree root still blocks. Tests: fixture node_modules/pkg/credentials.d.ts
-> preserved; fixture .env -> skipped.

## disk_magician-hygiene-wip-ignored-evidence-6frl

'preserve-wip skipped: ignored-file:evidence/after_3_8_dropdown.png' and
'ignored-file:evidence/feat-godmode-leak-9703/checksums.sha256'. The worktree is then preserved
forever with no decision path, so the reclaim never happens. Implement one of: (a) include ignored
evidence files in the WIP commit, (b) an explicit opt-in flag to preserve ignored data into the wip
branch, or (c) a report-only list with a needs_decision route. Acceptance: a worktree whose only
blocker is an ignored evidence/ dir has a defined, tested outcome -- preserved with its data
committed to a wip branch, or listed for a human decision -- never silently stuck.

## disk_magician-hygiene-wip-no-push-43b5

(wip/worktree-hygiene/<date>/<name>) and never pushes. 2026-10-12: the 3-day run created 238 wip
branches + a 238-line manifest, all local-only; the driver pushed them manually (204 ->
jleechanorg/worldarchitect.ai, 1 -> jleechanorg/user_scope) to satisfy the remote-preservation
requirement. A local-only ref does not survive repo loss. Fix: add --push-wip (or push as part of
the lane) using the same non-force policy as the triage push, with the backup/<branch>-<date>
fallback on non-fast-forward, and include pushed refs in the summary/manifest. Acceptance: after a
run with push enabled, 'git ls-remote --heads origin wip/*' shows the refs; a non-FF push falls back
to a backup ref instead of failing.

## disk_magician-hygiene-run-partial-summary-bmtx

timeout. 2026-10-12: a --min-age 3 --execute --preserve-wip run hit a 3000s cap, produced 950 ledger
lines, and ended with no '=== Summary ===', so removed/preserved/pushed counts had to be
reconstructed from the log and the WIP manifest, and it is unknown which discovered repos were never
scanned. Fix: always emit a partial summary on TERM/exit (with a 'partial' marker, like the reaper's
deadline outcome) and record scanned vs skipped repos so a follow-up run resumes. Acceptance: a run
killed mid-scan leaves partial counts plus the scanned/skipped repo list.

## disk_magician-ledger-30d-coverage-gap-egia

so 'diskm history diff --days 7' and '--days 30' both return that same single sample -- the windows
are 1 day wide and neither is a valid floor. Per this repo's methodology a missing/invalid ledger is
itself a finding (the root frontier run must reach mode=complete and publish on schedule).
2026-10-12 fallback used: disk_observer.jsonl{,.1} (df-only), span 2026-10-05..10-12 only -> floor
763.13 GiB on 10-07, current 853.65 GiB, delta +90.5 GiB (typical last-5d daily min ~830.7 -> +23
GiB). Fix: verify the snapshot/frontier publish path commits the ledger daily and alert when its
newest commit is older than 48h. Acceptance: daily ledger commits for 30 days and a --days 30 floor
dated before ledger HEAD.

## disk_magician-sweeper-roots-add-uncovered-tmv8

sweeper owner. Add the reclaimable ones to config/sweeper_roots.txt (54 entries; each with owner
script + note). Evidence + proposals: (1) $HOME/Library/Application Support/Cursor/snapshots --
measured 18 GiB on 2026-10-12, manually reaped, not in the registry and not a needs_decision path.
(2) $HOME/.cache -- parent uncovered (5.1 GiB); only .cache/uv and .cache/pre-commit registered,
while the 2026-05-09 historical cleanup list also targeted
~/.cache/{whisper,memory-backup-repo,cmux,gh,codex-runtimes,huggingface,zig} -- coverage was lost.
(3) $HOME/.gemini/antigravity-cli (6.3 GiB; only .../brain registered). (4)
$HOME/Documents/Codex/2026-10-03 (7.0 GiB). (5)
$HOME/Library/CloudStorage/Dropbox/conversation-backups/codex_conversations/sessions/2026/10 (5.6
GiB). (6) $HOME/Library/Logs/disk-magician-*.log (fsevents.log reached 1.3 GiB unrotated; no
rotation lane). (7) /Library/Developer (system CoreSimulator 5.8 GiB; registry covers only
$HOME/Library/Developer/CoreSimulator/{Temp,Caches}). (8)
$HOME/Library/Developer/CoreSimulator/Devices (2.8 GiB; needs --all-simulators +
SIMULATORS_APPROVED). (9) cache-only needs_decision subpaths: Library/Caches/Google + Application
Support/Google/Chrome/*/{Cache,Code Cache,GPUCache}; Library/Caches/Aside + Application
Support/Aside/*Cache*; Library/Caches/{com.openai.codex,cmux,CodexBar,Codex,com.cmuxterm.app}. Out
of scope (user/system): Photos derivatives/database, /Applications, /opt/homebrew/*, ~/.nvm
node_modules, ~/.codex/thread_history_1.sqlite (live DB, vacuum-only). Acceptance: new entries name
owner+note and no longer appear UNCOVERED.

## disk_magician-snapshot-coverage-below-gate-0c4f

(2026-10-12, last 6 snapshot commits): coverage_pct 24.5, 33.9, 78.1, 78.4, 39.1, 41.9 (raw
31.0/39.3/84.9/85.2/45.6/48.2). Only 375 of 1056 snapshot commits in 30 days pass the gate, so the
30d series has holes (none usable on 2026-09-23 or 09-25..10-01, and none after 10-10). Consequence:
snapshot floors and per-path deltas are mostly unusable and 'diskm history diff --days 7/30' falls
back to a single ledger commit. Investigate the coverage regression (frontier_last.json recorded
mode=partial at 2026-10-11T11:06) and alert when coverage_pct < 70 for N consecutive runs.
Acceptance: coverage >= 70 across the daily series and an alert on consecutive sub-gate runs.

