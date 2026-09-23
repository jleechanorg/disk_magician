---
title: plutil -extract without -o rewrites the plist in place — the launchd fleet "flapping" root cause
hostname: jeffreys-macbook-pro.local
date: 2026-09-11
status: active
paths:
  - ~/Library/LaunchAgents/com.jleechanorg.disk-magician*.plist
  - ~/Library/LaunchAgents/com.disk-magician.*.plist
safety_rule: never run `plutil -extract <key> <fmt> <live-plist>` without `-o -`
---

## What

`plutil -extract <keypath> <json|raw|xml1> <file>` with no `-o` **overwrites `<file>` with the
extracted value**. The plist becomes a bare JSON array / raw string (first byte `[`, `{`, or text),
`plutil -lint` fails with `Unexpected character [ at line 1`, and launchd silently refuses to load
it on the next bootstrap. Reproduced 2026-09-11 on a temp copy of `com.disk-magician.colima-prune.plist`.

Live incident (same day): at 12:32:41 an agent session ran
`plutil -extract StandardOutPath raw <plist>` / `plutil -extract ProgramArguments json <plist>` on
`com.disk-magician.sweeper-health`, `com.jleechanorg.disk-magician-frontier-root`,
`com.jleechanorg.disk-magician-pressure-sweep`, `com.jleechanorg.disk-magician` to read their log
paths. All four were corrupt (same mtime) two hours later; `check-launchd-fleet` had reported 16/16
minutes before. Quarantined copies: `~/.disk_magician_state/quarantine/plists-20260911T172046/`.

## Why it matters

This is the mechanism behind the previously "not pinned down" mass-corruption/flapping events
(2026-08-31 `<dict>` wrapper lost; 2026-09-06 up to 16 jobs unloaded, then flapping within minutes of
a repair): any agent — human-driven or launchd-driven — that *inspects* a live plist with
`plutil -extract` destroys it, and `sweeper-health --auto-repair` (or a manual
`install_launchd_sweepers.sh`) rewrites it, so the fleet oscillates between valid and corrupt with
no error anywhere. The watchdog itself is one of the files most often inspected, so it is the first
job to die.

## Guards / governance

1. Read-only inspection of a live plist: `plutil -extract <key> raw -o - <file>` or
   `plutil -p <file>` / `defaults read <file>`. Never omit `-o -`.
2. `check_launchd_fleet.sh` names this cause when an INVALID PLIST starts with `[` / `{`.
3. Repo call sites audited: `scripts/cleanup_apfs_snapshots.sh:69-70` extract from a temp copy
   (harmless) but should still pass `-o -`; fleet scripts already use `-o -`.
4. Repair: `bash scripts/install_launchd_sweepers.sh` (rewrites every plist from its template).

## History

- 2026-09-11 — reproduced, 4 plists corrupted by the investigating session itself, quarantined, fleet
  repaired 15/16 → see report `roadmap/2026-09-11-disk-recurrence-rootcause-and-automation.md`.
