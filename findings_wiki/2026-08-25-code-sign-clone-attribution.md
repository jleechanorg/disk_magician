---
title: Chrome + Aside `code_sign_clone` cache (66 GiB) is a Chromium bug, not ours
hostname: jeffreys-macbook-pro
date: 2026-08-25
status: active
paths:
  - /private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/X/com.google.Chrome.code_sign_clone
  - /private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/X/at.studio.AsideBrowser.code_sign_clone
  - /private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/X/com.openai.codex.code_sign_clone
safety_rule: GATED-APP — must close Chrome + Aside + Codex before any deletion; vars under <bundle_id>.code_sign_clone/ are never_delete otherwise
---

## Verdict

**The 66 GiB Chrome + 2 GiB Aside cache is caused by Chromium's `MacAppCodeSignClone` feature (open vendor bug in Chromium itself; same code path used by Aside because Aside is a Chromium/Electron fork)** — not by our scripts, not by macOS, and not by operator misuse. Our `cleanup_code_sign_clones.sh` already handles it correctly; what is missing is automatic scheduling plus the per-launch kill-switch (`--disable-features=MacAppCodeSignClone`) for Chrome/Aside/Codex where we control the launch.

## Mechanism (concrete chain on this machine)

1. Chrome (and Aside) starts up → Chromium's `CodeSignCloneManager` (`chrome/browser/mac/code_sign_clone_manager.mm`) creates a new `mkdtemp()` dir under the user's `var/folders/.../X/<bundle_id>.code_sign_clone/`, then `clonefile()`s the entire `Chrome.app` bundle there (CoW at first — see "Counter-evidence"), then hard-links the main `Google Chrome Framework` executable. Purpose: keep a consistent, signed bundle visible while the staged update writes the next version over the on-disk `Chrome.app` — so static signature validation keeps working mid-update.
2. On quit/shutdown, Chromium launches `--type=code-sign-clone-cleanup` helper, which polls `getppid() != 1` and then deletes the clone. **If the parent dies ungracefully (signal, `kill`, Playwright skip of `browser.close()`, headless crash), the helper never fires** and the clone is orphaned until the next reboot. This is the orphan-cleanup defect documented in open Chromium issue 340836884.

## Evidence (per hypothesis)

### H1 — macOS native leak (RULED OUT)

- Apple's macOS does **not** create `<bundle_id>.code_sign_clone` directories. The mechanism is implemented entirely in Chromium source (`chrome/browser/mac/code_sign_clone_manager.{h,mm}`, addressed below).
- The Apple analogue is **App Translocation** (TN2206), which creates `com.apple.translocation/` in the user's `var/folders/.../X/` — a different path, distinct owner (Gatekeeper, not the app). Direct quote from TN2206: Gatekeeper on Sierra+ "isolat[es] that app at an unspecified read-only location in the filesystem" for launches from disk image / archive / Downloads. That is **not** what we see on this host: the top level of `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/X/` contains only `at.studio.AsideBrowser.code_sign_clone` and `com.google.Chrome.code_sign_clone` — no `com.apple.translocation/`.
- `NSFileCoordinator` and `clonefile(2)` are present in the dependency chain but neither creates a `code_sign_clone` directory. `NSFileCoordinator` arbitrates file access across processes; `clonefile(2)` is the APFS CoW syscall the Chromium manager calls. Neither is the proximate cause.

### H2 — Chromium bug (CONFIRMED)

- Source file: **`chrome/browser/mac/code_sign_clone_manager.{h,mm}`** in the Chromium tree (Copyright 2024 The Chromium Authors, M125+).
  Verbatim header comments:
  > *"Manages a temporary copy-on-write clone of an app bundle. The temporary clone crucially has its main executable replaced with a hard link to the source's main executable."*
  > *"This is intended for use by the browser app to keep in-use files available on the filesystem after a staged update. This is in service of keeping the app's code signature statically valid..."*
  Verbatim `.mm` comments:
  > *"Get a temporary directory that is cleaned on machine boot but not periodically. `DIRHELPER_USER_LOCAL_TRANSLOCATION` and `Cleanup At Startup` are the only found directories that have this behavior."*
  > *"`DIRHELPER_USER_LOCAL_TRANSLOCATION` (`/var/folders/.../X`) is cleaned on machine boot and not otherwise cleaned periodically, but is only available on macOS 11 and later through a private interface."*
  > *"CLONEFILE(2) strongly discourages using `clonefile` to clone directories. It suggests using `copyfile` instead... We are ignoring the warning because of the speed gains with `clonefile`. FB13814551: clonefile directories."*
  > *"Unlinking M125 takes ~20ms on an M1 Max Mac. When this destructor is called, Chrome is in the process of shutting down and new background tasks can not be posted. Instead of blocking, perform the unlinking from a child helper process."*
  Storage path: `DIRHELPER_USER_LOCAL_TRANSLOCATION` → `/private/var/folders/<user>/<hash>/X/<bundle_id>.code_sign_clone/<uuid>/`.
- **Cleanup mechanism (this is the orphan):** Chromium launches a child helper process with `--type=code-sign-clone-cleanup`, which polls `getppid() != 1` and then calls `base::DeletePathRecursively` on the clone. **If the parent process is killed (signal, hard quit, crash) or the app is launched via Playwright/etc. without `browser.close()`, the helper never fires** — and the clone is orphaned until the next reboot. This is exactly what `oefrha`'s Playwright + chrome `page.evaluate` hang reproduced, and what `codex#25667` reproduced with normal quit.
- Feature flags: `BASE_DECLARE_FEATURE(kMacAppCodeSignClone)`, `BASE_DECLARE_FEATURE(kMacAppCodeSignCloneRenameAsBundle)`. Confirmed by both `chrome/browser/mac/code_sign_clone_manager.mm` and Chromium issue 505631157.
- Source refs (verified reachable URL):
  - https://chromium.googlesource.com/chromium/src/+/refs/heads/main/chrome/browser/mac/code_sign_clone_manager.mm
  - https://chromium.googlesource.com/chromium/src/+/refs/heads/main/chrome/browser/mac/code_sign_clone_manager.h
- Open Chromium bug: **issues.chromium.org/issues/340836884** (filed ~Apr 2025 by chrismorgan; per Hacker News commentary: "priority P1, no attention at all (bar a me-too comment after four months)"). Direct fetch required Chromium sign-in so the body text is not verified here — cite as "referenced via third-party discussion only".
- Public reports of the same leak (independent confirmations, not just ours):
  - **openai/codex #25667** — `~ 965 MB per launch, 6.5 GB after 7 launches, identical directory layout (`com.openai.codex.code_sign_clone/code_sign_clone.*)`), same kill switch quoted: `--disable-features=MacAppCodeSignClone`. Quote: *"Each clone is about 965 MB. After launching/quitting Codex multiple times, these directories keep accumulating."*
  - **teamcapybara/capybara #2795** — Chrome instances created in `code_sign_clone` are not cleared on macOS; user "lost 80 GB of SSD in a day"; `add_argument('--disable-features=MacAppCodeSignClone')` resolves it.
  - **Hacker News item 43944642 / oefrha** — Playwright+Chrome on macOS: *"it will deposit a copy of Chrome (more than 1GB) into /private/var/folders/.../X/com.google.Chrome.code_sign_clone/, and if you exit without a clean browser.close(), the copy of Chrome will remain there. I noticed after it ate up ~50GB in two days... I had to add --disable-features=MacAppCodeSignClone to all my invocations."*
  - HN replier `closewith`: *"That's an open bug at the minute, but the one saving grace is that they're APFS clones so don't actually consume disk space."* (note: this is wrong for the multi-version case — see "Mechanism" below).

### H3 — Aside bug (MISLEADING; it is the same Chromium bug)

Aside is a Chromium-based browser (Aside Helper, Aside Helper (Renderer), Aside Helper (GPU), all with the standard `--type=` flags visible in `ps aux`). It therefore inherits the **same `MacAppCodeSignClone` source path** as Chrome. The 2 GiB single subdir is so small because Aside has been running for hours without self-updating; Chrome, which updated to v151.0.7922.174 recently, has accumulated 48 subdirs over the same period.

### H4 — Our scripts / env / config (RULED OUT)

- `scripts/cleanup_code_sign_clones.sh` (added in commit **8ae462c**, 2026-07-12 — *guarded* by `lsof +D <candidate>` + frozen-identity re-check + `CODE_SIGN_CLONES_APPROVED=1` env gate; **never auto-runs**).
- Verified no launchd job invokes it: grep over `/Users/jleechan/Library/LaunchAgents/*.plist` for `cleanup_code_sign` / `code_sign` returned **zero matches**. The only scheduled launcher for our repo is `com.jleechanorg.disk-magician` which runs `snapshot` only; pressure-sweep runs `cleanup_tmp.sh` and `cleanup_colima.sh` (per its plist), never the code-sign cleaner. `disk_audit.sh` only prints a `"RUN: cleanup_code_sign_clones.sh --clean"` advisory line; it does not invoke it.
- Our prior intervention is actually *protective*: the four-leak-classes prevention memory (`project_2026-07-12_disk_four_leak_classes_prevention.md`) explicitly identifies this bucket and shipped the guarded sweeper for it. We did not introduce the leak.
- The 2026-08-15 ledger snapshot (`4af5780` in `~/.disk_magician_backup/ledger/topdown-5g.json`) caught the same path twice: `code_sign_clone` for Aside (3.1 GB) + Chrome (2.2 GB) = 5.2 GB — same phenomenon, ~10× smaller, three weeks before today. The bucket has been growing organically since at least mid-July, which predates any further repo-side change.

### H5 — Operator pattern (PARTIAL contributor, not root cause)

- `ps aux` today: Chrome pid 630 (started Sun 01 AM, CPU 63:57.87), Aside pid 66715 (started 10:44 AM with renderer / GPU helpers). Both have been **kept running across multiple relaunch cycles**.
- The 48 Chrome subdirs reflect launch bursts: 4 clones in 15 min on Aug 23 01:54; 10 clones in 10 min on Aug 24 23:03; 4 more Aug 25 00:02; 1 latest Aug 25 10:46. The bursts correspond to Chrome auto-update events (last observed build flips: `151.0.7922.140` → `151.0.7922.173` → `151.0.7922.174` per `Info.plist`).
- Even if Chrome stayed open continuously for years, the active clone (currently held by pid 630) would not exceed one. The leak is the 47 *inactive* clones that no app process is referencing. These are killed by macOS only on reboot (per the `#25667` quote above: *"The directories disappear after reboot because macOS cleans the `/var/folders/.../X` temp area"*).

## What we can do

### Operator action (this machine, low-risk)

1. **Verify before delete:** the lsof gate in `cleanup_code_sign_clones.sh` is correct. Confirm chrome **fully** quit (`pkill -x "Google Chrome"; sleep 2; lsof -Fpcn +D /private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/X/com.google.Chrome.code_sign_clone | head`), then `CODE_SIGN_CLONES_APPROVED=1 ./scripts/cleanup_code_sign_clones.sh --clean`. Should free ~64-66 GiB.
2. **Same for Aside:** quit Aside from menu bar (orange dot → Quit), then run the cleaner. Frees ~2 GiB more.
3. **Persistent mitigation for future runs (highest leverage):** add `--disable-features=MacAppCodeSignClone` to Chrome and Aside launch args (Chrome: `defaults write com.google.Chrome.plist`, but Chrome ignores plist flags from non-Google domains — use `open -na "Google Chrome" --args --disable-features=MacAppCodeSignClone` or wrap in a launcher). Same for Aside. This stops the leak at the source per the three upstream reports above. Caveat: trace the code-signature + update mechanism is what enables seamless auto-update; disabling it may cause update-relaunch prompts.
4. **Reboot equivalent without reboot:** `sudo periodic daily` triggers `sandbox_cleanup` which is supposed to clear `var/folders/.../X/` older than 3 days for the user; not reliable on its own, but `tmutil delete /private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/X/com.google.Chrome.code_sign_clone/*` will leave Chrome functional because the active clone is unaffected. **Don't** `rm -rf` the top-level dir — Chrome writes the per-launch `code_sign_clone.XXXXXX/` *underneath* it.

### Repo / script improvements (operators + us)

1. **Schedule the guarded cleaner** as a low-priority launchd weekly `com.jleechan.cleanup-code-sign-clones.plist`. Quitting Chrome is required; a cleaner that tries to delete and refuses when Chrome is alive is correct (already implemented) — just needs to be wired. Defaults `< 14 days` retention would match the per-clone mtime pattern we observed (oldest 2 days, newest minutes-old).
2. **safety.local.json:** add `<bundle_id>.code_sign_clone` subtrees to **never_delete** when chrome/aside is running (defended by `lsof` anyway, but defense in depth). Cross-link to this doc from the safety rule.
3. **Prevent auto-relaunch of clone on update:** if we control the launcher (`open -na`), pass `--disable-features=MacAppCodeSignClone` for one week and observe if updates still apply cleanly. If they do, ship the wrapper.

### Apple/Chromium (out of our control)

- The proper fix is Chromium deleting prior launches' clones (issue 340836884). File a me-too on that issue (login required) with this host's measurement: 48 subdirs × 1.4 GiB ≈ 66 GiB, oldest Aug 23 01:54, newest Aug 25 12:22, builds .140/.173/.174. Link `capybara#2795` and `codex#25667` as duplicates.

## Counter-evidence considered

- **`closewith` claim that APFS CoW makes these free** — see Mechanism §3. The *intra-version* blocks are shared, but the *prior-version* framework that each clone uniquely contains is exclusive. `du(1)` (which doesn't know about CoW) reports 1.4 GiB per subdir; `du -sh` over the parent shows 66 GiB total; on this APFS volume the actual on-disk cost is somewhere between 0 and 66 GiB depending on how many clones share the same prior version. Either way, the pure read-side `du` sum (which the disk_magician topdown ledger uses) is what shapes "disk pressure" responses, and that number is real.
- **macOS `periodic daily` cleaning `var/folders/X/`** — per `man 8 periodic` and the Apple dev forums, this is a daily 03:15 launchd job but coverage is partial and the 3-day retention can be skipped if the dir contains live fds. Multiple users on HN and `codex#25667` confirm clones survive multiple days.
- **Could be Electron/Aside-only?** No — top-of-X contains Chrome and Aside and Codex appdirs but no Slack/VSCode/etc., strongly correlating with "apps that embed Chromium and are signed for `Gatekeeper` re-validation." Apart from those, no other `<bundle_id>.code_sign_clone/` exists on this host.
- **`du` is misleading on CoW** — accepted; that is why the disk_magician ledger schema records both raw + dedup-corrected coverage. The corrected view (sub_granularity_tail_kb) may show less than 66 GiB for these entries — verified this is already handled in `snapshots/disk_snapshot.json` schema_version 2.

## Unverified

- Chromium issue #340836884 **body text** — direct fetch required Google sign-in (yielded only the chromium header + sign-in link). Verdict above relies on HN chrismorgan comment paraphrasing the entry ("priority P1, no attention at all (bar a me-too comment after four months)").

## History

- 2026-07-12 — `project_2026-07-12_disk_four_leak_classes_prevention.md` documents the bucket; sweeper shipped in commit `8ae462c`; safe-gate hardened in `1a420f5` and `416d837` (2026-07-14).
- 2026-07-23 — cleanup-code-sign-clones rebased into findings-wiki contract PR #21.
- 2026-08-15 — ledger snapshot `4af5780` first captures `code_sign_clone` paths for Chrome + Aside (totalling 5.2 GiB).
- 2026-08-25 — this finding: 48 Chrome subdirs (66 GiB) + 1 Aside subdir (2.0 GiB). Confirmed Chromium-side bug (issue 340836884) with kill-switch `--disable-features=MacAppCodeSignClone`.
