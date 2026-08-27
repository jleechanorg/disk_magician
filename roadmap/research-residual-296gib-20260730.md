# 296 GiB residual — three-lane research synthesis (2026-07-30)

Mission: explain why disk_magician ledger sum (538.62 GiB) + 296 GiB residual ≠
df used (835 GiB), AND identify a *measurable* unlock path. Three parallel
lanes, each a Sonnet subagent doing a fresh web research sweep with cited
sources.

## Bottom line

| Lane | Cause class | Survives scrutiny? | Approx mass | Unlock path |
|---|---|---|---|---|
| A | APFS local snapshots pinning container floor | **NO** — live verification: 0 purgeable, 3 OS-update snapshots on *System* (sealed, not Data), no TM localsnapshots | 0 GiB from this Mac | Apply FDA + sudo for visibility; not a reclaim lever |
| B | TCC/SIP-protected dirs (Mail, Messages, MobileSync, Safari, Containers, *Photos library*) | YES — sandboxed; MobileSync = 10–200+ GiB; Mail = 5–150 GiB; **Photos library (if present) = 50–300 GiB alone** | 75–165 GiB documented; **+50–300 GiB swing factor** = potential closure of full residual | Grant **Terminal** Full Disk Access, then `du -sh` the Library buckets + check `~/Pictures/*Photos*Library.photoslibrary/` |
| C | APFS block-accounting gaps (hardlink/clone-shared extents, open-but-deleted FDs, internal purgeable byte total) | YES (qualitatively) — none of stock macOS's user-facing tools enumerate these | Unknown without measurement | Add `du -sA` reconciliation to ledger; one-time `lsof +L1` walk; monitor `df` for spontaneous reclaim-when-needed events as a purgeable proxy |

**Negative finding (Q-C caught a hallucination — keep note):** one upstream
search result referenced a `Purgeable Space` byte field in
`diskutil apfs listSnapshots -plist` output. **It does not exist** — live
verified keys are only `SnapshotUUID`, `SnapshotName`, `SnapshotXID`,
`Purgeable` (boolean), `LimitingContainerShrink`, `RevertTo`, `RootTo`.
Never encode a vendor flag from search-result prose alone.

## Combined unlock path (ranked by leverage × risk)

1. **Photos library check (single biggest swing factor, zero install).**
   Without FDA: `ls -d ~/Pictures/*Photos*Library.photoslibrary 2>/dev/null`.
   With FDA: `du -sh ~/Pictures/*Photos*Library.photoslibrary`.
   If present, residual is likely fully explained by Photos alone — oldest
   item in the Pictures folder is the cheapest test.

2. **MobileSync UDID breakdown (already partially enabled on this Mac —
   sqlite reads work without FDA per Q-B §5).**
   Without FDA: `ls -la ~/Library/Application Support/MobileSync/Backup/`
   + Finder `Get Info → Calculate all sizes` (Finder always has FDA).
   With FDA: `du -sh ~/Library/Application\ Support/MobileSync/Backup/*`
   then per-UDID `du` for the largest 3.

3. **Mail + Messages size via FDA:**
   `du -sh ~/Library/Mail ~/Library/Messages` (gated on FDA grant).

4. **Ledger augmentation (Q-C §3, §4):** add `du -sA --apparent-size`
   rows to the next snapshot cycle so clone-share gap becomes visible
   structurally rather than only at investigative moments.

5. **Open-but-deleted FDs (Q-C §2):** `lsof +L1 /System/Volumes/Data`
   on the load-managed 30-min cron — yields are usually <1 GiB, but
   the surprise value is high when something has been writing into a
   pipe whose read end was lost.

## What was ruled out (negation ledger)

- **APFS local snapshot footprint:** zero on this box. The 3
  OS-update snapshots are on System (sealed), not Data. Even if you
  manage to delete them in Recovery Mode, this disk would not measurably
  recover — so don't take that path.
- **Time Machine local snapshots:** none configured, none orphaned.
  `tmutil destinationinfo -p` = no destinations; `/Volumes/com.apple.TimeMachine.localsnapshots/` absent.
- **`diskutil info ... | grep purgeable`:** `Purgeable: 0 B` (per
  frontier_last.json's purgeable_kb). Container is at its floor or
  near it, nothing in the auto-purge queue.
- **Hardlink/clone over-counting (`du -sk` vs `du -sA`):** not yet
  quantified on this Mac; would need a one-time reconciliation cycle
  added to the snapshot job.

## Files & provenance

- `/tmp/research_residual_296_qA.md` — APFS snapshot mechanisms
- `/tmp/research_residual_296_qB.md` — TCC + MobileSync scale + FDA mechanics
- `/tmp/research_residual_296_qC.md` — APFS block-accounting + clone mechanics
- Earlier other-lane verification (12-refuter workflow) returned
  empty strings (workflow wrapper bypass; void per Swarm Rule 3). This
  direct-subagent path is the binding research output.

## Recommended single operator decision

Grant **Terminal** (or `cmux`/iTerm) **Full Disk Access** in System
Settings → Privacy & Security → Full Disk Access. Reopen the terminal,
then run the post-FDA probe suite from `/tmp/research_residual_296_qB.md`
§"Operationally recommended FDA probe sequence". Cost: 30 seconds of
clicking; enables unlocking ~75–240+ GiB of measurement, most of which
becomes reclaimable (the rest is sealed System + Apple bookkeeping that
cannot move). Until that grant lands, the 296 GiB will keep resisting
ledger closure and any "200 GiB does not exist" conclusion stays
incomplete.

**FDA status correction (2026-08-27):** This recommendation records the
2026-07-30 state. The current interactive shell can read
`~/Library/Application Support/MobileSync`, `~/Library/Mail`, and
`~/Library/Messages`. Re-run the probes through the scanner's own process,
including an access preflight and explicit denied-path report, before treating
the resulting attribution as complete.
