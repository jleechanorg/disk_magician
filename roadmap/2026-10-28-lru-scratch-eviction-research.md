# Research: bounded/quota scratch volume reclamation — is LRU eviction the right model?

**Research date:** 2026-10-28
**Host examined:** Linux, `Linux version 6.17.0-29-generic` (`/proc/version`), repo `disk-magician` v0.2.322 (`pyproject.toml`)
**Scope:** verify (a) what the current scratch reclamation model actually is, (b) what trim/discard, age-based cleanup, LRU caches, atime, APFS, and scratch-pool designs actually do, (c) whether LRU is the right model here.

---

## 0. Evidence status — read this before trusting anything below

**No live web access on this run.** This invocation had only file-read/write tools: `web_search` and `source_check` were unavailable, so **no external source was fetched or fetched-again for 2026-10-28**. Every claim about an external project (util-linux, the kernel, systemd, ccache, APFS, Kubernetes) is therefore marked:

- **[U] UNVERIFIED this run** — stated from prior knowledge, *not* re-checked against the owning source today. The canonical source is named so it can be settled in one pass; §10 lists what each one needs.

Claims marked **[V]** were verified on this machine today against a primary artifact (kernel-provided file, mount table, or the repo's own implementing code), and the artifact path/function is cited. Line numbers are deliberately omitted where they were not counted exactly; function and file are cited instead.

This split matters for the verdict: the *local* half of the question (what diskm does, what signals exist on this volume) is verified; the *literature* half is not. The verdict below rests mainly on the verified half plus the parts of the literature that are architecturally forced (e.g. trimming cannot free blocks that no deletion freed).

---

## 1. Current verified findings (this host)

### 1.1 The volume itself

| Fact | Evidence | Class |
|---|---|---|
| `/home/jleechan/Scratch` is `/dev/loop24`, ext4, mounted `rw,nosuid,nodev,noatime` — **no `discard`** | `/proc/mounts` | [V] |
| fstab entry: `/home/jleechan/.local/share/disk-magician/volumes/scratch.ext4 /home/jleechan/Scratch ext4 loop,user,noauto,nosuid,nodev,noatime,exec 0 0` | `/etc/fstab` (diskm-managed block, tagged `diskm-scratch:<sha>:begin/end`) | [V] |
| Loop backing file is exactly that image | `/sys/block/loop24/loop/backing_file` | [V] |
| Image is sparse: created with `os.ftruncate(fd, quota)` — apparent size = quota, blocks allocated on write | `scripts/volume.py`, `linux_create_cmd` | [V] |
| Formatted `mke2fs -F -t ext4 -m 0 … -L diskm-scratch` → **no root reserve**; the 64 MiB `.diskm-ballast` is the substitute for ext4's 5% reserve | `scripts/volume.py`, `linux_create_cmd`; `BALLAST_BYTES = 64 * MIB` (module constant) | [V] |
| Quota is 200 GiB, backend `native`, mount at `~/Scratch` | `~/.config/disk-magician/config.json` → `volumes.classes.scratch` | [V] |
| Creating a scratch volume above **200 GiB is refused** (`if quota > 200 * GIB: return 2`) | `scripts/volume.py`, `linux_create_cmd` | [V] |
| The host root `/` is `ext4 rw,relatime` — i.e. the image and `/` share one physical disk and one free-space pool | `/proc/mounts` | [V] |

### 1.2 The reclamation job

| Fact | Evidence | Class |
|---|---|---|
| Installed cadence is hourly: `OnCalendar=hourly`, `Persistent=true`, unit runs `bash disk_magician.sh volume reclaim --clean` | `systemd/diskm-scratch-reclaim.timer.in`; `scripts/volume.py`, `linux_scheduler_install_cmd` (`cadence = "OnCalendar=hourly\nPersistent=true"`) | [V] |
| The hourly entry point also drives reclaim from the tmp-scratch sweep, under a **300 s** bound, and restores ballast on timeout | `scripts/tmp_scratch_sweep.sh` (`VOLUME_TIMEOUT_SEC=300`, `volume reclaim`) | [V] |
| **Trigger:** skip entirely while `used * 100 < quota * 90` → outcome `success_noop`, reason `below-trigger` | `scripts/volume_reclaim.sh` (`if (( used * 100 < quota * 90 ))`) | [V] |
| **Target:** delete until `now_used * 100 <= now_quota * 80`; otherwise report `partial` with `trim_target_not_reached` | `scripts/volume_reclaim.sh` | [V] |
| **Candidate filter:** only directories at exactly depth 3 matching `^[^./][^/]*/(evidence|build)/[^./][^/]*$`, **and only if newest content mtime is older than 172800 s (48 h)** | `scripts/volume_reclaim.sh` (`-mindepth 3 -maxdepth 3`, `(( $(date +%s) - newest > 172800 ))`) | [V] |
| **Ordering:** candidates sorted by `newest` content-mtime ascending — i.e. *oldest-first / LRU-by-mtime* — but only within the 48 h-eligible set | `scripts/volume_reclaim.sh` (`sort -n -k1,1`) | [V] |
| Per-item gates: `scratch_budget_content_mtime --strict` (refuses symlinks, requires ≥1 regular file), lsof recheck inside `scratch_budget_quarantine_remove`, C14 quarantine removal, `safety_gate` | `scripts/volume_reclaim.sh`; `scripts/lib/scratch_budget.sh` | [V] |
| Ballast protocol: on `ENOSPC` during intent write, release `.diskm-ballast`, retry once; every clean pass ends with idempotent `volume ballast ensure`; a failed restore downgrades the run to `partial` | `scripts/volume_reclaim.sh`; `scripts/volume.py`, `ballast_cmd` | [V] |
| Status raises `volume_high` alarm at ≥90 % of quota, `volume_full` at 100 % | `scripts/volume.py`, `linux_status` | [V] |
| Recency is derived from **content mtime**, never atime: `stat -c %Y` / `stat -f %m` over files, max, "cannot measure → preserve" | `scripts/lib/scratch_budget.sh`, `scratch_budget_content_mtime` | [V] |

### 1.3 What the repo already has, but does not use here

`scripts/lib/scratch_budget.sh` implements a **size-budget, oldest-first evictor** (`scratch_budget_evict_root <root> <budget_kb> <floor_minutes>`) with: a hard minimum floor clamped to ≥60 min, per-candidate `lsof` recheck immediately before every deletion, `safety_gate` immediately before every deletion, repository-container preservation, and cursor discipline for interrupted passes. [V]

Its own header states the motivating pathology verbatim — bead `disk_magician-d45`: *"age-only sweepers never touch 0-24h scratch, which is where ~15 GiB/day of growth lives."* [V]

That evictor is wired to `/tmp` scratch only, via `scripts/pressure_sweep.sh` (`--budget-gb`, `DISK_MAGICIAN_PRESSURE_SCRATCH_BUDGET_GB`, default `0` = disabled). **It is not wired to the quota scratch volume at all**; `volume_reclaim.sh` only calls `scratch_budget_quarantine_remove` per pre-filtered candidate. [V]

### 1.4 Consequence chain (researcher inference, high confidence — from the code above, not measured)

1. Everything under `~/Scratch` today is younger than 48 h (task premise, and consistent with agent churn).
2. The candidate loop therefore yields **zero** candidates. `AGED=0`, `REMOVED=0`, `TOP_REASON=below-trigger` (below 90 %) or, above 90 %, a pass that deletes nothing and ends `partial` / `trim_target_not_reached`.
3. The volume can sit at 61–81 % — or climb to 100 % — indefinitely, because the only reclamation gate is an age threshold that the workload never crosses.
4. Even in the case where items *are* deleted, **nothing is returned to `/`**: there is no `discard` mount option, and `fstrim` appears nowhere in the volume path — its only use in this codebase is Colima's in-VM `fstrim -av` (`scripts/pressure_sweep.sh`, `colima_trim_only`; `scripts/cleanup_colima.sh --trim-only`). [V for absence; the "therefore host blocks are not freed" step is §2]
5. Ballast (64 MiB) buys one ENOSPC retry, not headroom. Since the image is sparse and shares the physical disk with `/`, a 200 GiB quota is **not** protection for `/`; it only bounds the guest. [V for the mechanics; inference for the risk framing]

So: the current model is **quota-pressure-triggered, age-gated, oldest-first deletion — with no trim step.** It is *not* pure "age-based cleanup" (ordering is already mtime-LRU), and it is *not* LRU-triggered (the trigger is 90 % of quota).

---

## 2. Q1 — What trim/discard actually does, and why it is not a reclamation policy

**Claim (mechanism).** `fstrim` issues the filesystem-level `FITRIM` ioctl; the filesystem walks **extents it already considers free** and discards them. On a loop-mounted sparse image, the loop driver forwards those discards to the backing file as hole punches, so the host filesystem releases the blocks and the image's *allocated* size falls while its *apparent* size stays 200 GiB. ([U] — util-linux `fstrim(8)`; `loop(4)`; kernel `Documentation/block/` discard docs; `fs/ext4` `FITRIM` ioctl path. **Not fetched this run.**)

**Why it cannot be a reclamation policy** — this is architectural, not empirical: trim consumes a set of free extents produced by *someone else's* deletion. If nothing was deleted, the free-extent set is unchanged and `fstrim` returns ~0 bytes. Trimming is the *second half* of a deletion; used alone it is a no-op that also costs a full block-device scan. ([U] for the wording of the docs; the logic is definitional given FITRIM's contract.)

**ext4 `discard` mount option** does the same thing synchronously at free time, at a documented performance cost; the usual recommendation is periodic `fstrim` (or `fstrim.timer`) instead of `discard`. ([U] — `man 8 mount` ext4 section; `Documentation/filesystems/ext4`.)

**Verified local consequence [V]:** this volume has *neither* online discard (no `discard` in `/proc/mounts` or `/etc/fstab`) *nor* any `fstrim` invocation in the reclaim path. Therefore, today, deleting artifacts inside `~/Scratch` frees guest-visible space but **does not return a byte to `/`** until someone runs `fstrim` on that mount.

*Settling check (one command pair, needs a shell):* `du -h --apparent-size` vs `du -h` on `~/.local/share/disk-magician/volumes/scratch.ext4` before and after `fstrim -v ~/Scratch`. If allocated size does not drop, the loop/backing combination is not honoring discard and hole-punching needs a different route.

---

## 3. Q2 — Age-based reclamation as implemented in the OS

- **`systemd-tmpfiles`** entries in `tmpfiles.d(5)` take an *age* field (`d /path - - - 10d`), and `systemd-tmpfiles --clean` removes only entries whose age is exceeded; `-` in the age field means "never age out", which is the documented way to exclude a tree. "Age" is computed from file timestamps (modification/access/change), i.e. **age since last touch, not age since last *use*** — a file read every day has a fresh atime under `relatime` only if the read is >1 day after the last atime update, and no freshness at all under `noatime`. ([U] — `man 5 tmpfiles.d`, `man 8 systemd-tmpfiles`. Not fetched this run.)
- **`tmpwatch` / `tmpreaper`** are the same model (mtime/atime/ctime older than N), with `tmpreaper`'s documented caveat being exactly the atime dependence: on `noatime` mounts it silently degrades to mtime. ([U] — `man 8 tmpwatch`, `tmpreaper(8)`.)
- **Documented limitations of the age model**, as a class: (i) it cannot separate "written once and abandoned" from "written once and still being read", because both look old; (ii) it must therefore use an age long enough to be safe, which makes it structurally blind to high-churn classes whose useful life is shorter than the floor; (iii) it is insensitive to *volume* — 1 GiB or 190 GiB of young data produce the same (zero) action. ([U] for the general statement; [V] for this repo having independently recorded the same limitation in `scripts/lib/scratch_budget.sh`'s header, bead d45.)

---

## 4. Q3 — LRU-style eviction in real caches and tools

| Tool | Cap mechanism | Eviction order | Recency signal | True access-recency? |
|---|---|---|---|---|
| ccache | `max_size` in config | LRU | timestamp bookkeeping ("last used"), not atime | close — but owner-maintained metadata, not the fs ([U]) |
| sccache | `SCCACHE_CACHE_SIZE` | LRU | internal last-use tracking | as above ([U]) |
| Bazel `--disk_cache` | **none** | none — operator wipes it | n/a | no eviction at all ([U]) |
| Nix GC | `--max-freed` / roots | **root reachability**, then oldest gen | gc-roots, not use | no — reachability ([U]) |
| Docker / BuildKit | `--keep-storage`, `--filter until=` | age + size policy, priority classes | creation/use age | age/size, not access ([U]) |
| apt / `pkg` | `apt-get clean` (all-or-nothing), autoclean (unreachable) | none | n/a | no LRU ([U]) |
| pnpm store | content-addressable | `pnpm store prune` = remove **unreferenced** packages | reachability | no LRU ([U]) |
| npm cacache | index + content files | `npm cache verify` GCs content unreferenced by the index | reachability | no LRU ([U]) |
| kernel `fscache`/`cachefiles` | culling thresholds (`bcull`/`bstop`) | **true LRU list** maintained in-kernel | kernel-maintained use order | **yes — the one real LRU here** ([U]) |
| ZFS quota / btrfs qgroup | hard quota | none — `ENOSPC` | n/a | no eviction ([U]) |
| k8s `emptyDir.sizeLimit` | kubelet eviction | evicts / kills the **pod** | pod-level resource accounting | no per-file LRU ([U]) |

**Pattern (researcher inference).** Genuine access-recency LRU appears only where the *owner of the cache also owns the index and the entries are cheaply re-creatable and keyed* (cachefiles, ccache, sccache). Filesystems, package managers, and container runtimes choose reachability, age, or size-with-oldest-first instead — because on a general filesystem the access signal is either unavailable (`noatime`), expensive (per-read metadata write), or unreliable (relatime's one-day granularity). ([U] for each tool claim; the synthesis is inference.)

**No first-party specification for an "LRU scratch volume manager" was found or is known to me.** ([U] — see §10 for what would settle this.)

---

## 5. Q4 — What a reliable access-recency signal costs

- **`noatime`** suppresses atime updates entirely. **This volume is mounted `noatime`** [V: `/proc/mounts`, `/etc/fstab`], and `scripts/volume.py`'s fuse2fs path passes `-o noatime` explicitly. So *an atime-based LRU is impossible on this volume as configured* — the signal does not exist. ([U] for `mount(8)` semantics.)
- **`relatime`** (the default on `/` here [V]) updates atime only if the previous atime is older than mtime/ctime or older than ~1 day. That yields **day-granularity, monotone-ish** data — useless for distinguishing a 10-minute-old build from a 12-hour-old one, which is the exact resolution a churn-volume evictor needs. ([U] — `man 8 mount`, `Documentation/filesystems/ext4`.)
- **`statx` `STATX_ATIME`** can report atime plus flags (e.g. `STATX_ATTR_NOATIME`, `STATX_ATTR_RELATIME`, and whether the value is coarse/uncached), which is enough to *detect* that the signal is untrustworthy — not to make it trustworthy. ([U] — `man 2 statx`.)
- **`du` / `find -mmin`** read mtime = **last write**, not last read. In the canonical agent workflow (clone → build → read) all writes land during the build; if an artifact is then read for the next six hours, `find -mmin` reports it as old the entire time. Conversely a build that finished and was abandoned reports *identically*. This is the precise reason "age-based cleanup frees nothing" is not a tuning bug but a signal-class error: **mtime answers "when did this change", and the question is "is anyone still using this".** ([U] for the syscall semantics — `man 2 stat`; the workflow argument is inference from [V] the repo's own use of `scratch_budget_content_mtime`.)
- **ctime** moves on any inode metadata change (chmod, chown, link count), never on reads, and cannot be set forward/back — noisier than mtime and strictly worse as a use signal. ([U] — `man 2 stat`.)
- **Cost of enabling atime:** each read becomes a metadata write on ext4. On a loop-backed image that write is a page write into the sparse image file, i.e. real host I/O amplification for a signal that `relatime` degrades to one-day resolution anyway. Assessment: **not worth it.** (Inference, resting on [U] mount semantics + [V] the loop-backed sparse layout.)
- **The sound alternative already exists in this repo:** leases and open handles. `diskm scratch-new` admits and registers a producer lease [V: `AGENTS.md` § "Agent Scratch placement", `disk_magician.sh` `scratch-new` → `DISK_MAGICIAN_SCRATCH_PRODUCER_PIDS`], and the evictor re-runs `lsof` immediately before every deletion [V: `scratch_budget_quarantine_remove`]. A live lease/open FD is a *positive* statement of "in use"; mtime is only a proxy for its absence.

---

## 6. Q5 — macOS / APFS (first-party only)

- **Space sharing:** volumes in an APFS container share the container's free space; there is no fixed partition per volume, so one volume growing starves the others. `diskutil apfs list -plist` exposes each container's reference/UUID and free space, and `diskutil info -plist` per mount. **Verified structurally [V]:** `scripts/volume.py` (`load_container`, `Container.ceiling` / `Container.free`, `Volume.quota`) parses exactly this, which confirms the container-free + per-volume-quota model is what the API surfaces.
- **Per-volume quota/reserve:** set at creation (`diskutil apfs addVolume <container> APFS <name> -quota <size>` / `-reserve <size>`). A quota caps that volume's allocation; a reserve guarantees it a floor. ([U] — `man 8 diskutil`, APFS Guide. Not fetched this run.)
- **Purgeable space:** APFS accounts data marked purgeable (`F_PURGEABLE` / `F_NOPURGE`) — the mechanism behind Time Machine local snapshots and cloud-offload — as reclaimable under pressure. It applies **only to data whose owner marked it purgeable**; it does not make arbitrary user files evictable, and it is not an LRU. ([U] — Apple's APFS/purgeable documentation. Not fetched this run.)
- **Does APFS offer built-in LRU eviction?** No. APFS gives you quota, reserve, sharing, and purgeable accounting; **the owner of the data must delete it.** ([U] — no such feature is documented in `diskutil(8)`/APFS docs; absence-of-feature claims are inherently weaker, see §10.)
- Local APFS snapshot reclamation exists in this repo as a separate, explicit job (`cleanup-apfs-snapshots`), which is consistent with "the OS does not evict for you" [V: `disk_magician.sh` usage text].

---

## 7. Q6 — Published designs for self-managing scratch pools

- **Kubernetes `emptyDir` + `sizeLimit`:** the kubelet measures the volume and, on exceeding the limit (or the node's ephemeral-storage eviction threshold), **evicts the pod** — the unit of reclamation is the pod, not the file. ([U] — Kubernetes docs, "Ephemeral Volumes" / node-pressure eviction.)
- **CI runner workspaces:** the common documented model is **lifecycle-scoped** cleanup (clean the workspace at job start/end, or recreate the runner), with age sweeps as a backstop. ([U] — GitHub Actions self-hosted runner docs; GitLab Runner docs.)
- **Cloud ephemeral disks:** AWS instance-store and GCE local SSD are reclaimed by **instance lifecycle** (stop/terminate destroys them), never by policy. ([U] — AWS EC2 instance-store docs; GCE local SSD docs.)
- **A first-party spec for an LRU scratch manager: none found / none known.** The nearest normative artifacts are `tmpfiles.d(5)` age semantics, kubelet eviction, and the cachefiles LRU — three different models, none of which is "LRU over a user scratch volume". ([U] — flagged explicitly as an absence claim.)

---

## 8. Verdict

**LRU is the right *ordering*. It is the wrong *trigger*, and atime is the wrong *signal*.** Concretely:

1. **Trigger — replace 90 %-of-quota with a size budget.** A 90 % trigger on a 200 GiB volume means the guest is already ~20 GiB from ENOSPC before anything happens [V], and on a *sparse, host-shared* image the guest number is not even the number that protects `/` [V]. The repo's own house pattern is the fix: `budgets.classes.*` with `budget_gb`/`trigger: overage` already exists in `config.json` [V], and `scratch_budget_evict_root` already implements budget-triggered eviction [V] — it is simply not wired to this volume.
2. **Trigger — also gate on host free space, not only guest quota.** Because the image lives on the same physical disk as `/`, the evictor must be able to fire on host pressure even while the guest sits at 40 %. (Colima's in-VM trim already follows this reasoning [V: `pressure_sweep.sh` comments on sparse-disk re-inflation.])
3. **Ordering — keep oldest-first by newest-content-mtime.** That is already what `volume_reclaim.sh`'s `sort -n -k1,1` and `scratch_budget_content_mtime` do [V]. It is the strongest cheap signal available, and it is the same signal ccache/sccache effectively use ([U]).
4. **Age — demote 48 h from "gate" to "safety floor" of ~2 h** (the value `scratch_budget_evict_root` already clamps to, ≥60 min [V]). 48 h is not a safety margin on a volume whose entire contents are younger than 48 h; it is an off switch.
5. **Authority — leases and open handles, not recency.** Recency decides *order*; a live lease or an open FD decides *eligibility* (already implemented [V]).
6. **Trim — must follow deletion.** Without `fstrim ~/Scratch` after a deletion batch (or `discard` in the mount options), spec §2 says the host gains nothing [V for absence, U for mechanism]. Adding the evictor without adding the trim converts "volume fills up" into "volume looks fine and `/` still fills up".
7. **Do not enable atime.** `noatime` is set deliberately [V], and `relatime` would only give day-granularity [U]. If a genuine "last used" record is needed, write a heartbeat/stamp file inside the unit at lease release — a positive record, no mount-option change.
8. **LRU's real failure mode must be handled:** if the live working set exceeds the budget, an evictor will delete live data every hour (thrash) and still miss target. Keep the existing `trim_target_not_reached` / `partial` outcome and escalate to "relief required" instead of hammering [V: `volume_reclaim.sh` already distinguishes `partial`].

### Minimum viable policy

```
Volume: ~/Scratch (ext4 loop image, 200 GiB quota, noatime, no discard)
Every hour, bounded (300 s), plus on host free-space pressure:

1. MEASURE   guest used/quota  AND  host: allocated blocks of scratch.ext4 vs free on /
2. TRIGGER   evict if guest_used >= 80% of quota            (was: 90%)
             OR if host_free < pressure threshold            (new; same signal pressure_sweep uses)
             OR if allocated image size >= image budget      (new)
3. ENUMERATE units at depth 3: <id>/(build|evidence)/<id>
4. EXCLUDE   leased (producer lease live), any open FD (lsof, re-checked
             immediately before each unlink), repo/worktree containers,
             safety_gate hits, unmeasurable mtime  — all fail closed
5. ORDER     oldest-first by max(content mtime); hard floor 2 h (never < 60 min)
6. DELETE    via C14 quarantine only; stop at 80% of quota, or on deadline
7. TRIM      fstrim ~/Scratch after any deletion batch; verify allocated size fell
8. RECORD    receipt: before/after pct, removed count, top kept reason,
             target_reached, trimmed_bytes
9. ESCALATE  if target not reached and the only remaining units are younger than
             the floor: report relief-required; do not loop
```

Everything in steps 1–6 and 8 already exists in this repo [V]; the deltas are **step 2's trigger, step 5's floor value, step 7 (new), and wiring `scratch_budget_evict_root` to the volume root.**

---

## 9. Contradictions and disputed points

1. **"The current reclamation model is quota-pressure-triggered trim, not usage-recency eviction."** Half right. Verified: the *trigger* is quota pressure (≥90 %) and there is **no trim step at all** [V]. But the *ordering* inside a pass is already usage-recency (oldest content-mtime first) [V]. So the accurate statement is: *quota-triggered, 48 h-age-gated, mtime-LRU ordering, no trim.* Calling it "trim" mislabels it — nothing is ever trimmed.
2. **"Everything inside is recent (0 entries older than 7 days), so age-based cleanup frees nothing while the volume is 61–81 % full."** The mechanism is verified from the code path [V]. The two-machine 61–81 % occupancy figure is **not verified this run** (no shell, no `df`); this host is the Linux one and its current percentage is unknown to me (§10).
3. **"Is LRU the correct model?"** The literature does not support LRU-by-access on general filesystems (§4, §5) but *does* support oldest-first-by-mtime inside a size budget — which is what this repo already does for `/tmp` [V]. So "LRU" and "the right design" agree only if LRU is read as *ordering by content-mtime within a budget*, not as *atime-tracked eviction*.

---

## 10. Missing evidence / unverified

| Gap | Effect | What would settle it |
|---|---|---|
| **No web fetch this run** (no `web_search`/`source_check`) | Every [U] claim in §2–§7 rests on prior knowledge, including all specific option names, defaults, and threshold semantics | Re-run with web access against: `man7.org` `fstrim(8)`/`loop(4)`/`mount(8)`/`tmpfiles.d(5)`/`statx(2)`/`stat(2)`; `kernel.org` `Documentation/block/`, `Documentation/filesystems/ext4/`; `ccache.dev` config docs; `docs.rs/sccache`; Bazel `--disk_cache` docs; Nix manual GC; Docker/BuildKit prune docs; pnpm/npm store docs; kernel `fs/cachefiles` docs; `kubernetes.io` emptyDir/eviction; `man 8 diskutil` + Apple APFS Guide; AWS/GCE local-disk docs |
| Whether **any other host job** calls `fstrim` on `~/Scratch` | I inspected `volume.py`, `volume_reclaim.sh`, `tmp_scratch_sweep.sh`, `pressure_sweep.sh`, `main_sweeper.sh` header — no fstrim for the image. A repo-wide grep could still find one | `grep -rn fstrim --include=*.sh --include=*.py .` |
| **Current occupancy** of `~/Scratch` on this host, and whether deletion→trim actually shrinks the image here | The 61–81 % premise and the "trim returns blocks on this loop/backing pair" step are unmeasured | `df -h ~/Scratch`; `du -h` vs `du -h --apparent-size` on the image before/after `fstrim -v ~/Scratch` |
| **macOS-side behaviour** (`/Volumes/diskm-scratch`, APFS quota, purgeable) | Verdict is Linux-specific where it cites `noatime`; on APFS the atime question is different (`noatime` is not the macOS default) | `mount | grep diskm-scratch` and `diskutil apfs list` on the Mac; Apple APFS docs for purgeable |
| **Absence claim: "no first-party LRU scratch manager spec exists"** | Absence claims are the weakest class here | A targeted search of k8s KEPs, systemd RFEs, and `cachefiles` docs; if none, the claim stands as "none known to me" |
| Precise file:line citations for repo code | Function/file names are cited instead of line numbers to avoid fabricated precision | `grep -n` on the named functions |

---

## 11. Sources

**Kept — primary artifacts verified on this host (read 2026-10-28):**

- `/proc/mounts` — authoritative live mount table; establishes `noatime`, no `discard`, `/` on `relatime`, `loop24` for `~/Scratch`.
- `/proc/version` — kernel `6.17.0-29-generic` (dates every kernel-semantics claim).
- `/etc/fstab` — diskm-managed scratch entry with exact option set.
- `/sys/block/loop24/loop/backing_file` — proves the image↔loop↔mountpoint chain.
- `~/.config/disk-magician/config.json` — quota 200 GiB, `backend: native`, existing `budgets.classes` pattern.
- `scripts/volume.py` — image creation (`ftruncate`, `mke2fs -m 0`), ballast, scheduler cadence, `volume_high`/`volume_full` alarms, APFS container/quota parsing.
- `scripts/volume_reclaim.sh` — **the reclamation policy**: 90 % trigger, 80 % target, depth-3 candidate filter, 48 h age gate, oldest-first sort, ballast protocol, `partial`/`trim_target_not_reached` outcomes.
- `scripts/lib/scratch_budget.sh` — the existing size-budget oldest-first evictor + its d45 rationale + "cannot measure → preserve" discipline.
- `scripts/tmp_scratch_sweep.sh` — hourly entry point, 300 s bound on reclaim.
- `scripts/pressure_sweep.sh` — host-pressure trigger precedent, `--budget-gb` plumbing, Colima-only `fstrim`.
- `systemd/diskm-scratch-reclaim.{service,timer}.in` — `volume reclaim --clean`, `OnCalendar=hourly`.

**Canonical external sources named but NOT fetched this run** (all [U] claims above): `man7.org/linux/man-pages/man8/fstrim.8.html`, `man4/loop.4`, `man8/mount.8`, `man5/tmpfiles.d.5`, `man2/statx.2`, `man2/stat.2`; `docs.kernel.org/filesystems/ext4/`, `docs.kernel.org/block/`; `ccache.dev/manual/latest`; `github.com/mozilla/sccache`; `bazel.build/remote/caching`; `nixos.org/manual/nix` (garbage collection); `docs.docker.com/reference/cli/docker/buildx/prune/`; `pnpm.io/cli/store`, npm `cacache`; `docs.kernel.org/filesystems/caching/`; `kubernetes.io/docs/concepts/volumes/` + node-pressure eviction; `ss64.com/mac/diskutil` / Apple APFS Guide; AWS `instance-store` and GCE local-SSD docs.

**Rejected/deprioritized:** none — no search results were available to filter. Web-search-derived sources could not be evaluated at all this run, which is the single largest limitation of this brief (§10, row 1).

---

## 12. Next steps

1. Re-run this research **with web access** to convert the §2–§7 [U] claims into cited statements (highest value: `fstrim(8)`/`loop(4)` discard semantics, `tmpfiles.d(5)` age definition, cachefiles LRU, `diskutil` quota/reserve).
2. Measure the two unmeasured facts that decide the design: `du -h` vs `du -h --apparent-size` on `scratch.ext4` before/after `fstrim -v ~/Scratch` (does trim return blocks here?), and current guest occupancy.
3. Then implement the §8 minimum-viable policy as a `diskm` change: wire `scratch_budget_evict_root` to the volume root, change the trigger to a fraction budget, lower the floor to 2 h, add the post-deletion `fstrim` step, and keep `trim_target_not_reached` as the relief escalation.
