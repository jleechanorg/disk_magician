#!/usr/bin/env bash
# test_hands_off_auto_cleanup.sh — Regression suite for hands-off auto-cleanup (v0.2.406).
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0

ok() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
assert_eq() {
  if [[ "$1" == "$2" ]]; then
    ok "$3 (= $2)"
  else
    bad "$3 — expected '$2', got '$1'"
  fi
}

TMPROOT="$(mktemp -d /tmp/dm-hands-off-test.XXXXXX)" || exit 1
[[ -d "$TMPROOT" && "$TMPROOT" == /tmp/dm-hands-off-test.* ]] || exit 1
TMPROOT="$(cd "$TMPROOT" && pwd -P)" || exit 1
cleanup() {
  case "$TMPROOT" in /tmp/dm-hands-off-test.*|/private/tmp/dm-hands-off-test.*) ;; *) return ;; esac
  [[ -d "$TMPROOT" ]] || return
  chmod -R u+rwx "$TMPROOT" 2>/dev/null || true
  python3 -c 'import shutil, sys; shutil.rmtree(sys.argv[1], ignore_errors=True)' "$TMPROOT"
}
trap cleanup EXIT

export HOME="$TMPROOT/home"
export DISK_MAGICIAN_STATE_DIR="$TMPROOT/state"
export DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$TMPROOT/ptmp"
export DISK_MAGICIAN_DARWIN_USER_TEMP_DIR_OVERRIDE="$TMPROOT/utmp"
mkdir -p "$HOME" "$DISK_MAGICIAN_STATE_DIR" "$TMPROOT/ptmp" "$TMPROOT/utmp" "$TMPROOT/bin"
chmod 700 "$HOME"

cat >"$TMPROOT/bin/lsof" <<'STUB'
#!/bin/sh
case " $* " in
  *" -d cwd "*) printf 'p1\nfcwd\nn/\n' ;;
  *) exit 1 ;;
esac
STUB
cat >"$TMPROOT/bin/cwd_scan.sh" <<'STUB'
#!/bin/sh
printf '1\t0\t/\0'
STUB
chmod +x "$TMPROOT/bin/lsof" "$TMPROOT/bin/cwd_scan.sh"
export PATH="$TMPROOT/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export DISK_MAGICIAN_LSOF_BIN="$TMPROOT/bin/lsof"
export DISK_MAGICIAN_CWD_SCAN_CMD="$TMPROOT/bin/cwd_scan.sh"
export DISK_MAGICIAN_TEST_SANDBOX="$TMPROOT"
export GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

export DISK_MAGICIAN_CONFIG="$TMPROOT/config.json"
printf '{"monitored_dirs": []}\n' >"$DISK_MAGICIAN_CONFIG"
export DISK_MAGICIAN_AO_CONFIG="$TMPROOT/ao.yaml"
mkdir -p "$TMPROOT/ao-worktrees"
cat >"$DISK_MAGICIAN_AO_CONFIG" <<YAML
projects:
  demo:
    worktreeDir: $TMPROOT/ao-worktrees
YAML

backdate_tree() {
  local target="$1" hours="$2"
  python3 - "$target" "$hours" <<'PY'
import os, sys, time
root, hours = sys.argv[1], float(sys.argv[2])
t = time.time() - hours * 3600.0
for cur, dirs, files in os.walk(root):
    for f in files:
        os.utime(os.path.join(cur, f), (t, t))
    for d in dirs:
        os.utime(os.path.join(cur, d), (t, t))
os.utime(root, (t, t))
PY
}

echo "== (a) owner:null ancestor linked-worktree relaxation (disk_magician-cauk) =="
# shellcheck source=scripts/lib/artifact_verdict.sh
source "$REPO_ROOT/scripts/lib/artifact_verdict.sh"

mkdir -p "$TMPROOT/repos/main" "$TMPROOT/worktrees"
git -C "$TMPROOT/repos/main" init -q -b main
printf 'root\n' >"$TMPROOT/repos/main/README.md"
git -C "$TMPROOT/repos/main" add README.md
git -C "$TMPROOT/repos/main" commit -qm init

WT_NON_AO="$TMPROOT/worktrees/wt-non-ao"
git -C "$TMPROOT/repos/main" worktree add -q -b wt-non-ao "$WT_NON_AO"

mk_dd() {
  local dir="$1"
  mkdir -p "$dir/Build" "$dir/Index.noindex"
  printf 'obj\n' >"$dir/Build/out.o"
}

DD_OLD="$WT_NON_AO/dd-old"
mk_dd "$DD_OLD"
backdate_tree "$DD_OLD" 72

DD_YOUNG="$WT_NON_AO/dd-young"
mk_dd "$DD_YOUNG"

DD_TRACKED="$WT_NON_AO/dd-tracked"
mk_dd "$DD_TRACKED"
git -C "$WT_NON_AO" add dd-tracked
git -C "$WT_NON_AO" commit -qm "add tracked dd"
backdate_tree "$DD_TRACKED" 72

LEASE_NON_AO="$(lease_path_for "$WT_NON_AO")"
mkdir -p "${LEASE_NON_AO%/*}"
printf '{"path":"%s","owner":null}\n' "$WT_NON_AO" >"$LEASE_NON_AO"

assert_eq "$(artifact_removal_verdict "$DD_OLD" --kind xcode-derived-data)" "remove" "owner:null ancestor worktree allows >=48h untracked xcode-derived-data"
assert_eq "$(GIT_DIR="$TMPROOT/bogus-git-dir" bash "$REPO_ROOT/scripts/lib/artifact_verdict.sh" "$DD_OLD" --kind xcode-derived-data)" "remove" "ambient GIT_DIR ignored by _av_git on untracked xcode-derived-data"
assert_eq "$(artifact_removal_verdict "$DD_TRACKED" --kind xcode-derived-data)" "kept:owner-unknown" "git-tracked xcode-derived-data under owner:null ancestor blocked"
assert_eq "$(artifact_removal_verdict "$DD_YOUNG" --kind xcode-derived-data)" "kept:recent-activity" "<48h untracked xcode-derived-data blocked"

SUBREPO="$WT_NON_AO/subrepo"
mkdir -p "$SUBREPO"
git -C "$SUBREPO" init -q -b main
SUBREPO_DD="$SUBREPO/dd-tracked"
mk_dd "$SUBREPO_DD"
git -C "$SUBREPO" add dd-tracked
git -C "$SUBREPO" commit -qm "nested repo tracked dd"
backdate_tree "$SUBREPO" 72
assert_eq "$(bash "$REPO_ROOT/scripts/lib/artifact_verdict.sh" "$SUBREPO_DD" --kind xcode-derived-data)" "kept:owner-unknown" "tracked DerivedData inside untracked nested git repo does not inherit worktree owner:null relaxation"

WT_LIVE="$TMPROOT/worktrees/wt-live"
git -C "$TMPROOT/repos/main" worktree add -q -b wt-live "$WT_LIVE"
DD_LIVE="$WT_LIVE/dd-live"
mk_dd "$DD_LIVE"
backdate_tree "$DD_LIVE" 72
LEASE_LIVE="$(lease_path_for "$WT_LIVE")"
LIVE_START="$(_lease_ps_lstart_epoch "$$")"
printf '{"path":"%s","owner":{"pid":%s,"start_epoch":%s,"comm":"bash"}}\n' "$WT_LIVE" "$$" "$LIVE_START" >"$LEASE_LIVE"
assert_eq "$(artifact_removal_verdict "$DD_LIVE" --kind xcode-derived-data)" "kept:live-owner" "live-owner ancestor worktree blocks child removal"

WT_AO="$TMPROOT/ao-worktrees/wt-ao"
git -C "$TMPROOT/repos/main" worktree add -q -b wt-ao "$WT_AO"
DD_AO="$WT_AO/dd-ao"
mk_dd "$DD_AO"
backdate_tree "$DD_AO" 72
LEASE_AO="$(lease_path_for "$WT_AO")"
printf '{"path":"%s","owner":null}\n' "$WT_AO" >"$LEASE_AO"
assert_eq "$(artifact_removal_verdict "$DD_AO" --kind xcode-derived-data)" "kept:ao-owned" "AO-owned owner:null ancestor worktree blocks child removal"

echo "== (b) ~/.hermes/cache/scratch/<child> 48h ephemeral verdict =="
mkdir -p "$HOME/.hermes/cache/scratch/old-run" "$HOME/.hermes/cache/scratch/fresh-run"
printf 'old\n' >"$HOME/.hermes/cache/scratch/old-run/data.txt"
printf 'fresh\n' >"$HOME/.hermes/cache/scratch/fresh-run/data.txt"
backdate_tree "$HOME/.hermes/cache/scratch/old-run" 72
assert_eq "$(artifact_removal_verdict "$HOME/.hermes/cache/scratch/old-run" --kind ephemeral)" "remove" ">=48h hermes scratch child approved as ephemeral"
assert_eq "$(artifact_removal_verdict "$HOME/.hermes/cache/scratch/fresh-run" --kind ephemeral)" "kept:recent-activity" "<48h hermes scratch child kept"

echo "== (c) SIM_UNLEASED_EPHEMERAL_APPROVED=1 simulator pruning =="
SIM_ROOT="$TMPROOT/sim-devices"
mkdir -p "$SIM_ROOT"
XCRUN_STUB="$TMPROOT/bin/xcrun-sim"
cat >"$XCRUN_STUB" <<'STUB'
#!/bin/sh
if [ "$1" = "simctl" ] && [ "$2" = "delete" ] && [ -n "$3" ]; then
  case "$3" in
    *-*-*-*-*) python3 -c 'import os, shutil, sys; shutil.rmtree(os.path.join(sys.argv[1], sys.argv[2]))' "$DISK_MAGICIAN_SIM_FIXTURE_ROOT" "$3" ;;
  esac
  exit 0
fi
exit 0
STUB
chmod +x "$XCRUN_STUB"

export DISK_MAGICIAN_SIM_FIXTURE_ROOT="$SIM_ROOT"
export DISK_MAGICIAN_SIM_FIXTURE_XCRUN="$XCRUN_STUB"
# shellcheck source=scripts/sim_lifecycle.sh
source "$REPO_ROOT/scripts/sim_lifecycle.sh"

U_OLD="11111111-1111-1111-1111-111111111111"
U_YOUNG="22222222-2222-2222-2222-222222222222"
U_BOOTED="33333333-3333-3333-3333-333333333333"
U_POOL="44444444-4444-4444-4444-444444444444"
U_LEASED="55555555-5555-5555-5555-555555555555"
U_MANAGED="66666666-6666-6666-6666-666666666666"

sim_fixture_device "$SIM_ROOT" "$U_OLD" "ephemeral-old" "Shutdown" 72
backdate_tree "$SIM_ROOT/$U_OLD" 72
sim_fixture_device "$SIM_ROOT" "$U_YOUNG" "ephemeral-young" "Shutdown" 12
sim_fixture_device "$SIM_ROOT" "$U_BOOTED" "ephemeral-booted" "Booted" 72
backdate_tree "$SIM_ROOT/$U_BOOTED" 72
sim_fixture_device "$SIM_ROOT" "$U_POOL" "wai-shared-pool-1" "Shutdown" 72
backdate_tree "$SIM_ROOT/$U_POOL" 72
sim_fixture_device "$SIM_ROOT" "$U_LEASED" "ephemeral-leased" "Shutdown" 72
backdate_tree "$SIM_ROOT/$U_LEASED" 72
mkdir -p "$DISK_MAGICIAN_STATE_DIR/sim_leases/$U_LEASED"
printf '1\n' >"$DISK_MAGICIAN_STATE_DIR/sim_leases/$U_LEASED/generation"
printf 'owner\n' >"$DISK_MAGICIAN_STATE_DIR/sim_leases/$U_LEASED/owner"
printf '%064d\n' 1 >"$DISK_MAGICIAN_STATE_DIR/sim_leases/$U_LEASED/token_fingerprint"

sim_fixture_device "$SIM_ROOT" "$U_MANAGED" "managed-no-receipt" "Shutdown" 72
backdate_tree "$SIM_ROOT/$U_MANAGED" 72
mkdir -p "$DISK_MAGICIAN_STATE_DIR/gen"
printf '1\n' >"$DISK_MAGICIAN_STATE_DIR/gen/$U_MANAGED"

unset SIM_UNLEASED_EPHEMERAL_APPROVED || true
assert_eq "$(artifact_removal_verdict "$SIM_ROOT/$U_OLD" --kind simulator-device)" "kept:simulator-proof" "unmanaged sim device kept without SIM_UNLEASED_EPHEMERAL_APPROVED"

export SIM_UNLEASED_EPHEMERAL_APPROVED=1
assert_eq "$(artifact_removal_verdict "$SIM_ROOT/$U_OLD" --kind simulator-device)" "remove" "unmanaged >=48h Shutdown sim device approved with SIM_UNLEASED_EPHEMERAL_APPROVED=1"
assert_eq "$(artifact_removal_verdict "$SIM_ROOT/$U_MANAGED" --kind simulator-device)" "kept:simulator-proof" "managed gen/<udid> device without receipt stays protected"

prune_out="$(sim_prune --clean 2>&1)"
[[ ! -d "$SIM_ROOT/$U_OLD" ]] && ok "sim_prune --clean deleted unmanaged >=48h Shutdown device" || bad "sim_prune --clean kept $U_OLD: $prune_out"
[[ -d "$SIM_ROOT/$U_YOUNG" ]] && ok "sim_prune --clean kept <48h device" || bad "deleted <48h device"
[[ -d "$SIM_ROOT/$U_BOOTED" ]] && ok "sim_prune --clean kept Booted device" || bad "deleted Booted device"
[[ -d "$SIM_ROOT/$U_POOL" ]] && ok "sim_prune --clean kept wai-shared-* device" || bad "deleted wai-shared-* device"
[[ -d "$SIM_ROOT/$U_LEASED" ]] && ok "sim_prune --clean kept leased device" || bad "deleted leased device"
[[ -d "$SIM_ROOT/$U_MANAGED" ]] && ok "sim_prune --clean kept gen/\$udid managed device without receipt" || bad "deleted managed device without receipt"

unset SIM_UNLEASED_EPHEMERAL_APPROVED DISK_MAGICIAN_SIM_FIXTURE_ROOT DISK_MAGICIAN_SIM_FIXTURE_XCRUN

echo "== (d) plist templates, main_sweeper.sh wiring, and cleanup_xcode.sh sim prune hook =="
python3 - "$REPO_ROOT" <<'PY'
import pathlib, plistlib, sys
root = pathlib.Path(sys.argv[1])

for rel, checks in [
    (
        "launchd/com.jleechanorg.disk-magician-scratch-pressure.plist.template",
        {"DISK_MAGICIAN_SCRATCH_LRU_BUDGET_PCT": "50", "DISK_MAGICIAN_SCRATCH_DETAIL": "off", "DISK_MAGICIAN_SCRATCH_MIN_KB": "262144"},
    ),
    (
        "launchd/com.jleechanorg.disk-magician-main-sweeper.plist.template",
        {"SIM_UNLEASED_EPHEMERAL_APPROVED": "1", "FILEPROVIDER_EVICT_APPROVED": "1", "DISK_MAGICIAN_SCRATCH_LRU_BUDGET_PCT": "50"},
    ),
]:
    raw_txt = (root / rel).read_text(encoding="utf-8")
    assert "Authority: operator decision 2026-11-18" in raw_txt, rel
    for payload in (raw_txt.encode("utf-8"), raw_txt.replace("@HOME@", "/Users/test").encode("utf-8")):
        parsed = plistlib.loads(payload)
        env = parsed["EnvironmentVariables"]
        for k, v in checks.items():
            assert env[k] == v, (rel, k, env.get(k))
print("PLIST_OK")
PY
if [[ $? -eq 0 ]]; then ok "launchd plist templates valid XML with required EnvironmentVariables"; else bad "plist template validation failed"; fi

MOCK_MS="$TMPROOT/mock_ms"
mkdir -p "$MOCK_MS/scripts" "$HOME/.hermes/cache/scratch" "$HOME/Library/CloudStorage/Dropbox/conversation-backups"
CALL_LOG="$TMPROOT/ms_calls.log"
for s in cleanup_scratch_top_level.sh cleanup_tmp.sh cleanup_pr_scratch.sh cleanup_llm_inspector.sh quarantine_reconcile.sh cleanup_dev_caches.sh prune_aside_sessions.sh evict_fileprovider.sh slim_worktree_checkouts.sh cleanup_worktree_deps.sh; do
  cat >"$MOCK_MS/scripts/$s" <<STUB
#!/bin/sh
echo "$s \$* | min_kb=\${DISK_MAGICIAN_SCRATCH_MIN_KB:-} detail=\${DISK_MAGICIAN_SCRATCH_DETAIL:-} approved=\${SCRATCH_TOP_LEVEL_APPROVED:-}" >> "$CALL_LOG"
if [ "$s" = "cleanup_scratch_top_level.sh" ]; then exit 75; fi
exit 0
STUB
  chmod +x "$MOCK_MS/scripts/$s"
done

OSTYPE=darwin23   DISK_MAGICIAN_REPO_ROOT="$MOCK_MS"   DISK_MAGICIAN_PRESSURE_FREE_GB_OVERRIDE=10   DISK_MAGICIAN_SCRATCH_LRU_BUDGET_PCT=50   FILEPROVIDER_EVICT_APPROVED=1   WORKTREE_APPROVED=1   DISK_MAGICIAN_SKIP_CLONES=1   DISK_MAGICIAN_SKIP_TMP_LARGE=1   DISK_MAGICIAN_STATE_DIR="$TMPROOT/ms_state"   DISK_MAGICIAN_MAIN_SWEEPER_LOG="$TMPROOT/ms.log"   bash "$REPO_ROOT/scripts/main_sweeper.sh" --clean --skip-snapshot --skip-health >/dev/null 2>&1
ms_rc=$?
[[ "$ms_rc" -eq 0 ]] || cat "$TMPROOT/ms.log" >&2
assert_eq "$ms_rc" "0" "main_sweeper pressure + routine run exited 0"

ms_log_txt="$(cat "$TMPROOT/ms.log")"
[[ "$ms_log_txt" == *"skipped/partial (lock held or budget target unmet, rc=75)"* ]]   && ok "main_sweeper logs updated rc=75 skipped/partial message"   || bad "main_sweeper rc=75 message missing: $ms_log_txt"

calls_txt="$(cat "$CALL_LOG")"
[[ "$calls_txt" == *"cleanup_scratch_top_level.sh --clean --budget-pct 50 --budget-preserve-content-keeps | min_kb=1048576 detail=off approved=1"* ]]   && ok "Phase 2 invokes scratch_prune --budget-pct 50 --budget-preserve-content-keeps with MIN_KB=1048576 DETAIL=off APPROVED=1"   || bad "Phase 2 scratch_prune call missing/wrong: $calls_txt"
[[ "$calls_txt" == *"cleanup_pr_scratch.sh --clean --tmp-dir $HOME/.hermes/cache/scratch --pattern *"* ]]   && ok "Tier 1 invokes cleanup_pr_scratch on ~/.hermes/cache/scratch"   || bad "Tier 1 hermes scratch call missing"
[[ "$calls_txt" == *"evict_fileprovider.sh --clean"* ]]   && ok "Tier 4 invokes evict_fileprovider on darwin when Dropbox root exists and FILEPROVIDER_EVICT_APPROVED=1"   || bad "Tier 4 evict_fileprovider missing"

t1_tmp_ln="$(grep -n '^cleanup_tmp.sh ' "$CALL_LOG" | head -1 | cut -d: -f1)"
t1_dev_ln="$(grep -n '^cleanup_dev_caches.sh ' "$CALL_LOG" | head -1 | cut -d: -f1)"
t6_slim_ln="$(grep -n '^slim_worktree_checkouts.sh ' "$CALL_LOG" | head -1 | cut -d: -f1)"
t6_deps_ln="$(grep -n '^cleanup_worktree_deps.sh ' "$CALL_LOG" | head -1 | cut -d: -f1)"
[[ -n "$t1_tmp_ln" && -n "$t1_dev_ln" && "$t1_tmp_ln" -lt "$t1_dev_ln" ]]   && ok "Tier 1 runs cleanup_dev_caches.sh AFTER cleanup_tmp.sh"   || bad "Tier 1 ordering invalid ($t1_tmp_ln vs $t1_dev_ln)"
[[ -n "$t6_slim_ln" && -n "$t6_deps_ln" && "$t6_slim_ln" -lt "$t6_deps_ln" ]]   && ok "Tier 6 runs slim_worktree_checkouts.sh BEFORE cleanup_worktree_deps.sh"   || bad "Tier 6 ordering invalid ($t6_slim_ln vs $t6_deps_ln)"

echo "== (e) Non-stubbed main_sweeper guards (evict_fileprovider missing Dropbox root + slim_worktree_checkouts WORKTREE_APPROVED=0) =="
rmdir "$HOME/Library/CloudStorage/Dropbox/conversation-backups"
REAL_GUARD_REPO="$TMPROOT/real_guard_repo"
mkdir -p "$REAL_GUARD_REPO/scripts"
ln -s "$REPO_ROOT/scripts/lib" "$REAL_GUARD_REPO/scripts/lib"
ln -s "$REPO_ROOT/scripts/safety_lib.sh" "$REAL_GUARD_REPO/scripts/safety_lib.sh"
ln -s "$REPO_ROOT/scripts/evict_fileprovider.sh" "$REAL_GUARD_REPO/scripts/evict_fileprovider.sh"
ln -s "$REPO_ROOT/scripts/slim_worktree_checkouts.sh" "$REAL_GUARD_REPO/scripts/slim_worktree_checkouts.sh"

OSTYPE=darwin23   DISK_MAGICIAN_REPO_ROOT="$REAL_GUARD_REPO"   DISK_MAGICIAN_PRESSURE_FREE_GB_OVERRIDE=200   FILEPROVIDER_EVICT_APPROVED=1   WORKTREE_APPROVED=0   DISK_MAGICIAN_STATE_DIR="$TMPROOT/ms_real_guard_state"   DISK_MAGICIAN_MAIN_SWEEPER_LOG="$TMPROOT/ms_real_guard.log"   bash "$REPO_ROOT/scripts/main_sweeper.sh" --clean --skip-snapshot --skip-health >/dev/null 2>&1
guard_rc=$?
guard_log="$(cat "$TMPROOT/ms_real_guard.log")"
assert_eq "$guard_rc" "0" "non-stubbed main_sweeper --clean skips missing Dropbox root (FILEPROVIDER_EVICT_APPROVED=1) and unapproved slim_worktree_checkouts (WORKTREE_APPROVED=0) with rc=0"
[[ "$guard_log" != *"WARN:"* ]]   && ok "non-stubbed main_sweeper --clean recorded zero step warnings/errors"   || bad "unexpected WARN in main_sweeper log: $guard_log"

echo "== (f) Behavioral P0 test: real cleanup_scratch_top_level.sh --clean --budget-pct 50 --budget-preserve-content-keeps keeps secrets and dirty repos =="
SCRATCH_BEHAV_ROOT="$TMPROOT/scratch_behav"
mkdir -p "$SCRATCH_BEHAV_ROOT/secret-entry" "$SCRATCH_BEHAV_ROOT/dirty-repo"
printf -- '-----BEGIN PRIVATE KEY-----\nsecret\n-----END PRIVATE KEY-----\n' >"$SCRATCH_BEHAV_ROOT/secret-entry/key.pem"
head -c 65536 /dev/zero >"$SCRATCH_BEHAV_ROOT/secret-entry/pad.bin"
backdate_tree "$SCRATCH_BEHAV_ROOT/secret-entry" 72

git -C "$SCRATCH_BEHAV_ROOT/dirty-repo" init -q -b main
printf 'base\n' >"$SCRATCH_BEHAV_ROOT/dirty-repo/file.txt"
git -C "$SCRATCH_BEHAV_ROOT/dirty-repo" add file.txt
git -C "$SCRATCH_BEHAV_ROOT/dirty-repo" commit -qm init
printf 'uncommitted\n' >>"$SCRATCH_BEHAV_ROOT/dirty-repo/file.txt"
head -c 65536 /dev/zero >"$SCRATCH_BEHAV_ROOT/dirty-repo/pad.bin"
backdate_tree "$SCRATCH_BEHAV_ROOT/dirty-repo" 72

FAKE_DISKM_BEHAV="$TMPROOT/bin/fake-diskm-behav"
cat >"$FAKE_DISKM_BEHAV" <<'STUB'
#!/usr/bin/env bash
if [[ "$1 $2" == "volume verify-mount" ]]; then exit 0; fi
if [[ "$1 $2" == "volume status" ]]; then
  printf '{"volumes":[{"class":"scratch","allocated_bytes":900000,"quota_bytes":1000000}]}
'
  exit 0
fi
exit 2
STUB
chmod +x "$FAKE_DISKM_BEHAV"

scratch_behav_out="$(
  DISK_MAGICIAN_TEST_CONTEXT=1   DISK_MAGICIAN_TEST_SANDBOX="$TMPROOT"   DISK_MAGICIAN_SCRATCH_ROOT_OVERRIDE="$SCRATCH_BEHAV_ROOT"   DISK_MAGICIAN_DISKM_BIN="$FAKE_DISKM_BEHAV"   DISK_MAGICIAN_STATE_DIR="$TMPROOT/scratch_behav_state"   DISK_MAGICIAN_DELETION_LOG="$TMPROOT/scratch_behav_del.log"   DISK_MAGICIAN_SCRATCH_MIN_KB=1   SCRATCH_TOP_LEVEL_APPROVED=1   bash "$REPO_ROOT/scripts/cleanup_scratch_top_level.sh" --clean --budget-pct 50 --budget-preserve-content-keeps 2>&1
)"
scratch_behav_rc=$?
assert_eq "$scratch_behav_rc" "75" "real cleanup_scratch_top_level.sh --budget-preserve-content-keeps exits 75 when only protected candidates exist"
[[ "$scratch_behav_out" == *"kept:secret-like $SCRATCH_BEHAV_ROOT/secret-entry"* ]]   && ok "real budget-preserve-content-keeps logs kept:secret-like for .pem entry"   || bad "missing kept:secret-like in: $scratch_behav_out"
[[ "$scratch_behav_out" == *"kept:dirty $SCRATCH_BEHAV_ROOT/dirty-repo"* ]]   && ok "real budget-preserve-content-keeps logs kept:dirty for dirty git repo"   || bad "missing kept:dirty in: $scratch_behav_out"
[[ -d "$SCRATCH_BEHAV_ROOT/secret-entry" && -d "$SCRATCH_BEHAV_ROOT/dirty-repo" ]]   && ok "both >=48h secret and dirty Scratch entries preserved on disk under SCRATCH_TOP_LEVEL_APPROVED=1"   || bad "secret or dirty Scratch entry was deleted!"

echo "== (g) Behavioral P1 #2 test: slim_worktree_checkouts.sh skips active leased and open-file worktrees =="
SLIM_REPO="$TMPROOT/slim_repo"
SLIM_ROOTS="$TMPROOT/slim_roots"
mkdir -p "$SLIM_REPO/docs" "$SLIM_REPO/src" "$SLIM_ROOTS"
head -c 65536 /dev/zero >"$SLIM_REPO/docs/manual.bin"
printf 'code\n' >"$SLIM_REPO/src/main.py"
git -C "$SLIM_REPO" init -q -b main
git -C "$SLIM_REPO" config extensions.worktreeConfig true
git -C "$SLIM_REPO" add -A
git -C "$SLIM_REPO" commit -qm init

WT_SLIM_LEASED="$SLIM_ROOTS/wt-leased"
WT_SLIM_OPEN="$SLIM_ROOTS/wt-open"
WT_SLIM_OK="$SLIM_ROOTS/wt-ok"
git -C "$SLIM_REPO" worktree add -q -b slim-leased "$WT_SLIM_LEASED"
git -C "$SLIM_REPO" worktree add -q -b slim-open "$WT_SLIM_OPEN"
git -C "$SLIM_REPO" worktree add -q -b slim-ok "$WT_SLIM_OK"
for w in "$WT_SLIM_LEASED" "$WT_SLIM_OPEN" "$WT_SLIM_OK"; do
  find "$w" -path "$w/.git" -prune -o -exec python3 -c 'import os,sys,time; t=time.time()-72*3600
for p in sys.argv[1:]: os.utime(p,(t,t))' {} +
done

SLIM_LEASE_FILE="$(lease_path_for "$WT_SLIM_LEASED")"
mkdir -p "${SLIM_LEASE_FILE%/*}"
SLIM_LIVE_START="$(_lease_ps_lstart_epoch "$$")"
printf '{"path":"%s","owner":{"pid":%s,"start_epoch":%s,"comm":"bash"}}
' "$WT_SLIM_LEASED" "$$" "$SLIM_LIVE_START" >"$SLIM_LEASE_FILE"

LSOF_OPEN_STUB="$TMPROOT/bin/lsof-slim-open"
cat >"$LSOF_OPEN_STUB" <<STUB
#!/bin/sh
case " \$* " in
  *" -d cwd "*) printf 'p1\nfcwd\nn/\n'; exit 0 ;;
  *"$WT_SLIM_OPEN/docs"*) printf 'p999\nn%s/docs/manual.bin\n' "$WT_SLIM_OPEN"; exit 0 ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$LSOF_OPEN_STUB"

slim_out="$(
  WORKTREE_APPROVED=1   DISK_MAGICIAN_LSOF_BIN="$LSOF_OPEN_STUB"   bash "$REPO_ROOT/scripts/slim_worktree_checkouts.sh" --clean --roots "$SLIM_ROOTS" 2>&1
)"
[[ "$slim_out" == *"LEASE-SKIP $WT_SLIM_LEASED (kept:lease-busy:"* ]]   && ok "slim_worktree_checkouts skips active live-PID worktree lease as kept:lease-busy"   || bad "missing LEASE-SKIP in: $slim_out"
[[ "$slim_out" == *"OPEN-SKIP  $WT_SLIM_OPEN (kept:open-file"* ]]   && ok "slim_worktree_checkouts skips worktree with open file under excluded dir"   || bad "missing OPEN-SKIP in: $slim_out"
[[ -f "$WT_SLIM_LEASED/docs/manual.bin" ]] && ok "leased worktree docs remain materialized" || bad "leased worktree docs were dematerialized"
[[ -f "$WT_SLIM_OPEN/docs/manual.bin" ]] && ok "open-file worktree docs remain materialized" || bad "open-file worktree docs were dematerialized"
[[ ! -e "$WT_SLIM_OK/docs/manual.bin" ]] && ok "unleased idle worktree without open files was slimmed" || bad "eligible worktree was not slimmed: $slim_out"

echo "== (h) cleanup_xcode.sh sim prune timeout sanitization and degraded SIMCTL_STATUS =="
MOCK_XCODE="$TMPROOT/mock_xcode"
mkdir -p "$MOCK_XCODE/scripts"
cp -R "$REPO_ROOT/scripts/." "$MOCK_XCODE/scripts/"
XCODE_DISKM_LOG="$TMPROOT/xcode_diskm.log"
cat >"$MOCK_XCODE/disk_magician.sh" <<STUB
#!/bin/sh
echo "\$*" >> "$XCODE_DISKM_LOG"
exit "\${MOCK_PRUNE_RC:-0}"
STUB
cat >"$TMPROOT/bin/xcrun" <<'STUB'
#!/bin/sh
exit "${MOCK_XCRUN_RC:-0}"
STUB
chmod +x "$MOCK_XCODE/disk_magician.sh" "$TMPROOT/bin/xcrun"

bash "$MOCK_XCODE/scripts/cleanup_xcode.sh" --dry-run >/dev/null 2>&1
bash "$MOCK_XCODE/scripts/cleanup_xcode.sh" --clean >/dev/null 2>&1
xcode_calls="$(cat "$XCODE_DISKM_LOG" 2>/dev/null || true)"
[[ "$xcode_calls" == *"sim prune --dry-run"* && "$xcode_calls" == *"sim prune --clean"* ]]   && ok "cleanup_xcode.sh invokes bounded disk_magician.sh sim prune for --dry-run and --clean"   || bad "cleanup_xcode.sh sim prune calls missing: $xcode_calls"

xcode_octal_out="$(MOCK_PRUNE_RC=124 DISK_MAGICIAN_SIM_PRUNE_TIMEOUT_SECONDS="08" bash "$MOCK_XCODE/scripts/cleanup_xcode.sh" --clean 2>&1)"
[[ "$xcode_octal_out" == *"summary: simulator housekeeping degraded (sim prune timed out after 8s)"* ]]   && ok "cleanup_xcode.sh sanitizes octal 08 timeout and sets degraded SIMCTL_STATUS on rc=124"   || bad "octal/timeout SIMCTL_STATUS failed: $xcode_octal_out"

xcode_bad_out="$(MOCK_PRUNE_RC=124 DISK_MAGICIAN_SIM_PRUNE_TIMEOUT_SECONDS="not-a-number" bash "$MOCK_XCODE/scripts/cleanup_xcode.sh" --clean 2>&1)"
[[ "$xcode_bad_out" == *"summary: simulator housekeeping degraded (sim prune timed out after 120s)"* ]]   && ok "cleanup_xcode.sh falls back to 120s when DISK_MAGICIAN_SIM_PRUNE_TIMEOUT_SECONDS is invalid"   || bad "invalid timeout fallback failed: $xcode_bad_out"

xcode_rc_out="$(MOCK_PRUNE_RC=24 bash "$MOCK_XCODE/scripts/cleanup_xcode.sh" --clean 2>&1)"
[[ "$xcode_rc_out" == *"summary: simulator housekeeping degraded (sim prune rc=24)"* ]]   && ok "cleanup_xcode.sh sets degraded (sim prune rc=24) on non-zero sim prune exit"   || bad "non-zero sim prune SIMCTL_STATUS failed: $xcode_rc_out"

xcode_no_downgrade="$(MOCK_XCRUN_RC=124 MOCK_PRUNE_RC=24 DISK_MAGICIAN_SIMCTL_TIMEOUT_SECONDS="09" bash "$MOCK_XCODE/scripts/cleanup_xcode.sh" --clean 2>&1)"
[[ "$xcode_no_downgrade" == *"summary: simulator housekeeping degraded (simctl timed out after 9s)"* ]]   && ok "cleanup_xcode.sh preserves prior degraded SIMCTL_STATUS without overwriting it"   || bad "degraded SIMCTL_STATUS was overwritten: $xcode_no_downgrade"

echo
echo "=== Result: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
