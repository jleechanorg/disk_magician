---
title: `--disable-features=MacAppCodeSignClone` — side effects for Chrome / Aside / Codex on macOS
hostname: jeffreys-macbook-pro
date: 2026-08-25
status: active
paths:
  - N/A (behavioral flag, not a path)
safety_rule: none — affects Chrome / Aside / Codex launch only; no filesystem delete path involved
companion: 2026-08-25-code-sign-clone-attribution.md
---

## Verdict

**Conditional go for Chrome. No-go for Aside / Codex without upstream
cooperation.** Disabling `MacAppCodeSignClone` on **Chrome** is safe for
our usage profile: the flag short-circuits the manager constructor,
eliminating the clonefile cost on launch (~10 ms) and the orphan-cleanup
defect tracked in issue 340836884. For **Aside** and **Codex**, no
documented external mechanism passes the kill-switch through to the
embedded Chromium — both are Electron- or Chromium-based but neither
calls `app.commandLine.appendSwitch('disable-features',
'MacAppCodeSignClone')` and arbitrary `open -na "App" --args ...` argv is
not honored by packaged Electron `.app` bundles. The currently documented
Aside/Codex workaround is `rm -rf` of the clone directory, gated by our
existing `cleanup_code_sign_clones.sh`. The only documented downside of
disabling on Chrome is loss of mid-update code-signature continuity
(relevant when Google ships a new Chrome version while an old instance is
still running); we have not observed a Chrome auto-update in this host's
recent behavior.

## Evidence

### 1. Performance (verbatim from Chromium source)

`chrome/browser/mac/code_sign_clone_manager.h` benchmarks in the
class-header design comment:

> "`clonefile` + `link` the main executable: ~10ms / Hard linking the whole
> app tree: best approach ~60ms / `-[NSFileManager
> linkItemAtURL:toURL:error:]`: ~120ms / `base::FileEnumerator`: ~80ms"

`chrome/browser/mac/code_sign_clone_manager.mm` destructor comment:

> "Unlinking M125 takes ~20ms on an M1 Max Mac. … Instead of blocking,
> perform the unlinking from a child helper process."

**Effect when disabled:** the constructor short-circuits at
`if (!base::FeatureList::IsEnabled(kMacAppCodeSignClone) || src_path.empty()
|| main_executable_name.empty()) { return; }` (cscm.mm:513–548). No clone,
no `mkdtemp`, no `clonefile(2)`, no helper child. **Net runtime delta is
slightly positive** (saves the ~10 ms clonefile + 20 ms unlink, plus the
UMA counters `Mac.AppCodeSignCloneCreationTime` / `Mac.AppCodeSignCloneCount`
/ `Mac.AppCodeSignCloneExists` stop recording). No measurable memory delta
beyond the absent 1.4 GiB clone in `/var/folders/.../X/`.

### 2. Security (no documented weakening; one in-flight guarantee is removed)

The feature exists *only* to bridge staged-update signature continuity
(cscm.h):

> "This is intended for use by the browser app to keep in-use files
> available on the filesystem after a staged update. This is in service of
> keeping the app's code signature statically valid and in agreement with its
> dynamic code signature after a staged update."

Disabling removes that bridge. **Implications:**

- **Code-sign xattr preservation**: `clonefile(2)` preserves extended
  attributes on the cloned file (including `com.apple.cs.CodeDirectory`,
  etc.) per the man page: *"The cloned file dst shares its data blocks
  with the src file but has its own copy of attributes, extended
  attributes and ACL's which are identical to those of the named file
  src."* (https://www.manpagez.com/man/2/clonefile/.) Disabling the
  feature just stops creating the clone — it does not strip signatures
  from any on-disk artifact.
- **Hardened Runtime / Library Validation**: Library Validation checks
  *team identifier*, not on-disk path
  (https://support.apple.com/guide/security/library-validation). The
  clone's executable has the same team ID as the source, so a cloned
  executable passes Hardened Runtime equally to the source. Disabling
  removes nothing from this chain.
- **Gatekeeper / notarization**: no relationship to the clone path.
  Gatekeeper validation runs at first launch against the on-disk
  `Chrome.app`, not the per-launch CoW clone.
- **What "mid-update code-signature continuity" actually meant**: while
  Chrome was running, if Google's auto-updater wrote a new
  `Google Chrome.app` over the on-disk bundle, the *running* process
  was already holding the old executable mmapped (and the new executable
  was also signed). The clone's only function was to provide a stable
  filesystem view of the prior version for any code that re-read the
  bundle from disk mid-session (rare). Disabling leaves the live process
  on the old executable; new launches pick up the staged one. Same
  signed binary either way.
- **Apple's stance**: Apple's "strongly discourage using `clonefile` to
  clone directories" (man page LIMITATIONS) is a **kernel-stability**
  warning (per Apple DTS engineer Kevin Elliott on developer.apple.com
  forums thread 784446: a stall on critical paths can panic the
  kernel). It is **not** an advisory about signatures or security.
  The Open Radar FB13814551 entry titled "[Chrome] clonefile
  directories" was filed by Chromium against Apple, not by Apple
  against clonefile — it documents `copyfile`-vs-`clonefile` perf on
  `/Applications/Google Chrome.app`.

**Counter-evidence considered**: no Chromium, Apple, or security-vendor
source was found that calls `MacAppCodeSignClone` a security mitigation.
The closest framing in upstream commentary is "best effort, no
guarantees of success" (cscm.h). Intego's coverage of Electron
vulnerabilities (search hit) names *Chromium itself*, not this clone
mechanism, as the security boundary.

### 3. Stability

- **340836884** (open bug, "stale code_sign_clone dirs accumulate, never
  cleaned at ..."): this is the leak itself, not a disable regression.
  Status unverified — direct fetch required Google sign-in. Verdict above
  relies on HN/Reddit/codex#25667 paraphrasing.
- **350764022** ("CodeSignCloneManager triggering in tests, blocks shutdown
  for ~30s"): this is an *enabled-feature* problem — helpers stuck
  polling `getppid() != 1` in test harnesses where the parent doesn't
  exit normally. Disabling makes this go away. Title from WebSearch.
- **379125944** ("Chrome for Testing ignores this feature"): upstream
  disables the feature for `CHROME_FOR_TESTING` builds via
  `#if !BUILDFLAG(CHROME_FOR_TESTING)` in cscm.mm. Comment in source:
  "Chrome for Testing does not support auto-updates and this feature is
  specific to the update functionality, therefore, we disable this
  feature for Chrome for Testing." Same conclusion: no stability
  regression expected for the disable on regular Chrome.
- **534027924** (newer; same theme): same orphan-accumulation failure
  class. No source-cited fix.
- **No reported crash from the disable direction** in the search corpus
  (HN item 43944642, teamcapybara/capybara#2795, openai/codex#25667, HN
  oefrha comment all describe the *enable* side as the bug).

### 4. macOS compatibility

- Source says: "`DIRHELPER_USER_LOCAL_TRANSLOCATION` (`/var/folders/.../X`)
  is only available on macOS 11 and later through a private interface."
  The flag is unconditionally disabled on macOS < 11 — no manual
  `--disable-features` action required.
- No version-specific regressions documented for Sonoma (14) or Sequoia
  (15). The kill-switch is a no-op on macOS 10.15 since the feature
  already self-disabled.
- The Capybara report explicitly states the leak "is still happening in
  Chrome 133" on a current macOS — i.e., the bug survives on Sequoia.
- One WebSearch result ("macOS 13 Removed MacAppCodeSignClone
  Functionality", blaming BlueStacks) is **not credible**: it
  confuses Chromium's internal feature name with an unrelated Apple
  private API and references BlueStacks and macOS 13 Ventura behavior
  that no Chromium source corroborates. **No source found — do not cite.**

### 5. Electron / Aside / Codex compatibility

- The flag is a standard Chromium `--disable-features=` switch. Three
  open issues in `openai/codex` confirm the same leak fires there
  (#25667 ~965 MB/launch; #27536 62 GB+; #27789 ~1 GB/launch, closed as
  duplicate) and the closed-side `capybara#2795` confirms Playwright
  / Puppeteer are similarly affected.
- **Chrome (real Chromium binary)**: `open -na "Google Chrome" --args
  --disable-features=MacAppCodeSignClone` works because Chrome parses
  argv. Confirmed working for this host's setup; no app change needed.
- **Aside (Electron-based)**: no documentation on `aside.app`, no
  upstream PR adding the flag call, no `ELECTRON_DISABLE_*` env var
  recognized. Arbitrary `open -na "Aside" --args ...` argv is **not
  honored by packaged Electron `.app` bundles** unless the app's
  `main.js` reads it. The only documented workaround is `rm -rf` of
  the clone tree, gated by our `cleanup_code_sign_clones.sh`. To kill
  the leak at the source requires Aside upstream to add
  `app.commandLine.appendSwitch('disable-features',
  'MacAppCodeSignClone')` in their main process.
- **Codex (Chromium-based desktop app)**: same shape as Aside. No PR
  in `openai/codex` adds the kill-switch call; issue #25667 is "Open"
  with no maintainer response and no fix milestone. Reporter
  workaround quoted verbatim from the issue thread: `rm -rf
  /private/var/folders/*/X/com.openai.codex.code_sign_clone/code_sign_clone.*`.
- **Playwright / Puppeteer / Capybara (test harnesses that spawn
  Chromium)**: appending `args: ['--disable-features=MacAppCodeSignClone']`
  works (confirmed by `teamcapybara/capybara#2795` quote:
  `add_argument('--disable-features=MacAppCodeSignClone')` resolves it).
  Not relevant to our interactive Chrome/Aside/Codex launch path.
- **No `ELECTRON_DISABLE_CODE_SIGN_CLONE` environment variable exists.**
  Electron's documented `ELECTRON_*` env vars (`ELECTRON_NO_ASAR`,
  `ELECTRON_RUN_AS_NODE`, `ELECTRON_ENABLE_LOGGING`, etc.) at
  `electronjs.org/docs/latest/api/environment-variables` do not address
  this feature. The Chromium flag is the only supported kill-switch,
  and it requires explicit app-side adoption.

### 6. Cleanup side effects

Killing the active clone while Chrome/Aside/Codex is **closed** is safe
— the next launch simply re-creates the clone (or, with the flag
disabled, doesn't). `cleanup_code_sign_clones.sh` already enforces
`lsof +D <candidate>` + frozen-identity re-check + `CODE_SIGN_CLONES_APPROVED=1`
gates. With the flag enabled, the cloned bundle is rebuilt every launch
(>1 GiB written to `/var/folders/.../X/.../code_sign_clone.XXXXXX/`).
With the flag disabled, no clone is rebuilt at all. **After killing the
active clone while the app is closed, the next launch with the flag
disabled succeeds normally** — the only path that used to consume the
clone is gone.

## Recommendation (operator action this machine)

1. **Chrome only — wrap with `--disable-features=MacAppCodeSignClone`.**
   The simplest mechanism on macOS:
   `open -na "Google Chrome" --args --disable-features=MacAppCodeSignClone`.
   Verify Chrome's update flow over one week: a staged update should
   apply cleanly and the next launch should open normally. If so,
   ship the wrapper as the default. Add the equivalent `argv` for the
   Playwright/Puppeteer/Capybara launch paths if used.
2. **Aside / Codex — flag kill-switch is not externally reachable.**
   Until Aside / Codex upstream call
   `app.commandLine.appendSwitch('disable-features', 'MacAppCodeSignClone')`
   in their main process (file issues at
   `github.com/aside-browser/issues` and `openai/codex#25667`),
   the only working mitigation is `cleanup_code_sign_clones.sh`
   (already in this repo) gated on closing the apps.
3. **Schedule `cleanup_code_sign_clones.sh`** as a low-priority launchd
   weekly job. The script's `lsof` gate already enforces app-quit;
   the new job would close the leak on Aside / Codex without requiring
   upstream cooperation. Until the upstream bug fixes, this is a
   defense-in-depth measure even with the flag enabled on Chrome.
4. **`safety.local.json`** — add `<bundle_id>.code_sign_clone/` subtree
   to `never_delete` when the owning app is running (already enforced
   by `lsof` in the cleanup script; defense in depth).
5. **Do not file a me-too on Chromium issue 340836884** without
   Google's sign-in wall being resolved (cannot attach body text
   without an account). Instead, post a measurement-only reply on
   `openai/codex#25667` (the issue tracker there is open and writable).

## Unverified

- Direct text of Chromium issues **340836884**, **350764022**,
  **379125944**, and **534027924** — all four are gated behind a
  Google sign-in wall on `issues.chromium.org` and
  `issuetracker.google.com`. Verdict above relies on (a) verbatim
  source-file quotes from the `cscm.{h,mm}` files and (b) third-party
  reproductions (HN, capybara#2795, codex#25667/27536/27789). Status
  and milestone fields may be stale; reopen if the upstream picture
  changes.
- Reddit thread `r/MacOS/comments/1hxxpg7` ("Found a Google Chrome clone
  on my Mac") — fetch blocked by reddit anti-bot; web-search snippet
  referenced only.
- Aside browser's `main.js` source — no public mirror found; assumed
  to follow standard Electron conventions (no `disable-features` for
  `MacAppCodeSignClone`). If a future Aside release adds it, the
  verdict for Aside flips from "no-go" to "conditional go."
- `mtime` of the underlying `cscm.{h,mm}` files: not retrieved.
  Header comment says M125 (Chromium 125, May/June 2024); current
  Chrome on this host is 151.x, so file may have evolved. The quoted
  feature names, mode enum values, and kill-switch semantics match
  current behavior on Chrome 151.

## History

- 2026-08-25 — initial findings doc, paired with the attribution
  finding (`2026-08-25-code-sign-clone-attribution.md`).
- 2026-08-25 (later) — refined after Electron research: confirmed
  Aside/Codex do not honor the flag without upstream code change;
  security section expanded with clonefile(2) / Library Validation
  team-ID evidence; recommendation split per-app.
