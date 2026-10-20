#!/usr/bin/env bash
# test_deletion_log_coverage.sh — every removal PRIMITIVE logs exactly one
# deletion_log line per successful removal and none on refusal/failure, and
# every deleter script is covered by a primitive or allow-listed with a reason.
# The structural guard-level check lives in tests/test_removal_sites.sh (T18).
#
# Fixtures live under /tmp and stub only the C14 verdict / python remover, so
# the real primitive code (lib/quarantine.sh, worktree_remove_hook.sh,
# safety_lib.sh, strip_dir, clear_dir_contents) is what runs.
# Run: bash tests/test_deletion_log_coverage.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0
ok() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

T="$(mktemp -d /tmp/disk-magician-dlcov.XXXXXX)" || { echo "FATAL: no /tmp fixture" >&2; exit 2; }
case "$T" in /tmp/*|/private/tmp/*) ;; *) echo "FATAL: fixture not under /tmp: '$T'" >&2; exit 2 ;; esac
T="$(cd "$T" && pwd -P)"
trap 'chmod -R u+w "$T" 2>/dev/null; rm -rf -- "$T"' EXIT
export HOME="$T/home" TMPDIR="$T/tmp" DM_ACTUATOR=fixture.sh DISK_MAGICIAN_DELETION_LOG="$T/del.log"
mkdir -p "$HOME" "$TMPDIR"

lines() { if [[ -f "$DISK_MAGICIAN_DELETION_LOG" ]]; then wc -l <"$DISK_MAGICIAN_DELETION_LOG" | tr -d ' '; else echo 0; fi; }
reset() { rm -f -- "$DISK_MAGICIAN_DELETION_LOG"; }
# expect <label> <want-lines> [<action> <path>] — checks count and, when given, the tab-separated fields.
expect() {
  local label="$1" want="$2" act="${3:-}" path="${4:-}" n
  n="$(lines)"
  if [[ "$n" != "$want" ]]; then bad "$label: expected $want log line(s), got $n"; return; fi
  if [[ -n "$act" ]]; then
    if awk -F'\t' -v a="$act" -v p="$path" '$2=="fixture.sh" && $3==a && $4 ~ /^(-1|[0-9]+)$/ && $5==p {f=1} END{exit !f}' "$DISK_MAGICIAN_DELETION_LOG"; then
      ok "$label"
    else bad "$label: line fields wrong: $(cat "$DISK_MAGICIAN_DELETION_LOG")"; fi
  else ok "$label"; fi
}

# ---- fake C14 remover used by quarantine_remove --------------------------
FAKE="$T/fake"; mkdir -p "$FAKE/lib"
cat >"$FAKE/quarantine_rename.py" <<'PY'
import os, shutil, sys
cmd = sys.argv[1]
if cmd == "bind":
    open(sys.argv[3], "w").write(sys.argv[2])
elif cmd == "candidate":
    print(open(sys.argv[2]).read())
elif cmd == "remove":
    res = os.environ.get("FAKE_RESULT", "removed:q1")
    if res.startswith("removed:"):
        p = sys.argv[2]
        if os.path.isdir(p) and not os.path.islink(p):
            shutil.rmtree(p)
        else:
            os.unlink(p)
    print(res)
PY
cat >"$FAKE/worktree_quarantine.py" <<'PY'
import os, shutil, sys
res = os.environ.get("FAKE_RESULT", "removed:w1")
if res.startswith("removed:"):
    shutil.rmtree(sys.argv[3])
print(res)
PY

# q <verdict> <fake-result> <guard> <path> [fn] — run a primitive in a clean shell.
q() {
  local verdict="$1" result="$2" guard="$3" path="$4" fn="${5:-quarantine_remove}"
  VERDICT="$verdict" FAKE_RESULT="$result" DM_DELETION_LOGGED="$guard" bash -c '
    source "$1/scripts/lib/quarantine.sh" 2>/dev/null
    artifact_removal_verdict() { echo "$VERDICT"; }
    log() { :; }
    _Q_LIB="$2/lib"
    if [[ "$4" == c14_remove ]]; then c14_remove "$3" --kind ephemeral; else quarantine_remove "$3" --kind ephemeral; fi
  ' _ "$ROOT" "$FAKE" "$path" "$fn" >/dev/null 2>&1
}
export VERDICT=remove

echo "== quarantine_remove / c14_remove =="
mkdir -p "$T/d1" && head -c 8192 /dev/zero >"$T/d1/f"
reset; q remove removed:q1 "" "$T/d1"
[[ ! -e "$T/d1" ]] && ok "dir really removed" || bad "dir still present"
expect "quarantine_remove dir -> one remove line" 1 remove "$T/d1"

head -c 4096 /dev/zero >"$T/f1"
reset; q remove removed:q1 "" "$T/f1"; expect "quarantine_remove file -> remove_file" 1 remove_file "$T/f1"

head -c 4096 /dev/zero >"$T/tgt"; ln -s "$T/tgt" "$T/lnk"
reset; q remove removed:q1 "" "$T/lnk"; expect "quarantine_remove symlink -> remove_symlink" 1 remove_symlink "$T/lnk"

mkdir -p "$T/d2"
reset; q remove removed:q1 "" "$T/d2" c14_remove; expect "c14_remove success -> one line" 1 remove "$T/d2"

mkdir -p "$T/d3"
export VERDICT=kept:dirty
reset; q kept:dirty removed:q1 "" "$T/d3"; expect "verdict refusal -> zero lines" 0
export VERDICT=remove
reset; q remove kept:locked "" "$T/d3"; expect "remover refusal (kept:*) -> zero lines" 0
reset; q remove deferred:phase2 "" "$T/d3"; expect "deferred/quarantined (not removed) -> zero lines" 0
[[ -d "$T/d3" ]] && ok "refused dir untouched" || bad "refused dir was removed"
reset; q remove removed:q1 1 "$T/d3"; expect "DM_DELETION_LOGGED=1 caller guard -> zero lines" 0
[[ ! -e "$T/d3" ]] && ok "guarded call still removed the dir" || bad "guarded call did not remove"

echo "== wrh_remove_now =="
wrh() { # <fake-result>
  FAKE_RESULT="$1" bash -c '
    source "$1/scripts/worktree_remove_hook.sh" 2>/dev/null
    wtn_main_repo() { echo "$2/mainrepo"; }
    wrh_log() { :; }
    _WRH_DIR="$2"
    wrh_remove_now "$3" "$3" --quarantine "$2/inv.json"
  ' _ "$ROOT" "$FAKE" "$WT"
}
: >"$FAKE/inv.json"; mkdir -p "$FAKE/mainrepo"
WT="$T/wt1"; mkdir -p "$WT" && head -c 4096 /dev/zero >"$WT/f"
reset; wrh removed:w1 >/dev/null 2>&1; rc=$?
[[ $rc -eq 0 && ! -e "$WT" ]] && ok "worktree removed rc 0" || bad "worktree removal rc=$rc exists=$([[ -e $WT ]] && echo y || echo n)"
expect "wrh_remove_now success -> one remove_worktree line" 1 remove_worktree "$WT"
WT="$T/wt2"; mkdir -p "$WT"
reset; wrh kept:dirty >/dev/null 2>&1; rc=$?
[[ $rc -ne 0 ]] && ok "refusal returns non-zero" || bad "refusal returned 0"
expect "wrh_remove_now refusal -> zero lines" 0

echo "== rm_logged / deletion_size_kb =="
rl() { bash -c 'source "$1/scripts/safety_lib.sh"; rm_logged "$2"' _ "$ROOT" "$1" >/dev/null 2>&1; }
mkdir -p "$T/r1" && head -c 8192 /dev/zero >"$T/r1/f"
reset; rl "$T/r1"; expect "rm_logged success -> one line" 1 remove "$T/r1"
reset; rl "$T/does-not-exist"; expect "rm_logged on absent path -> zero lines" 0
if [[ "$(id -u)" != 0 ]]; then
  mkdir -p "$T/ro" && : >"$T/ro/stuck" && chmod 555 "$T/ro"
  reset; rl "$T/ro/stuck"; expect "rm_logged failing rm -> zero lines" 0
  chmod 755 "$T/ro"
fi
mkdir -p "$T/shim"
printf '#!/bin/sh\nsleep 5\necho 99 "$2"\n' >"$T/shim/du"; chmod +x "$T/shim/du"
r="$(PATH="$T/shim:$PATH" DM_DELETION_SIZE_TIMEOUT=1 bash -c 'source "$1/scripts/safety_lib.sh"; deletion_size_kb "$2"' _ "$ROOT" "$T" 2>/dev/null)"
[[ "$r" == "-1" ]] && ok "slow du is capped and logs -1" || bad "slow du gave '$r', want -1"

echo "== strip_dir (cleanup_worktree_deps.sh) =="
mkdir -p "$T/wt/node_modules/x" && head -c 8192 /dev/zero >"$T/wt/node_modules/x/f"
reset; bash -c '
  source "$1/scripts/safety_lib.sh"
  safety_gate() { return 0; }
  DRY_RUN=false; total_kb=0; count=0
  stripped_paths="|"
  eval "$(sed -n "/^strip_dir() {/,/^}/p" "$1/scripts/cleanup_worktree_deps.sh")"
  strip_dir "$2" "$2/node_modules"
' _ "$ROOT" "$T/wt" >/dev/null 2>&1
[[ ! -e "$T/wt/node_modules" ]] && ok "node_modules stripped" || bad "node_modules still present"
expect "strip_dir success -> one strip line" 1 strip "$T/wt/node_modules"

echo "== clear_dir_contents (cleanup_agent_artifacts.sh) =="
mkdir -p "$T/aa/sub" && head -c 4096 /dev/zero >"$T/aa/sub/f"
reset; bash -c '
  source "$1/scripts/safety_lib.sh"
  DRY_RUN=false
  eval "$(sed -n "/^clear_dir_contents() {/,/^}/p" "$1/scripts/cleanup_agent_artifacts.sh")"
  clear_dir_contents "$2"
' _ "$ROOT" "$T/aa" >/dev/null 2>&1
expect "clear_dir_contents -> one empty line" 1 empty "$T/aa"

echo "== script coverage allow-list =="
# Each deleter must route through a logging primitive (marker below) or carry a reason.
marker='deletion_log|deletion_log_removal|rm_logged|c14_remove|quarantine_remove|wrh_remove_now|strip_dir'
allow_reason() {
  case "$1" in
    cleanup_colima.sh) echo "docker/builder prune + fstrim: no filesystem path; effect is the datadisk df delta" ;;
    cleanup_codex_db.sh) echo "VACUUM only; database files are never deleted" ;;
    reclaim_worktree_venvs.sh) echo "mv to .bak rename, nothing freed; the .bak is reaped by cleanup_worktree_venvs.sh (c14_remove)" ;;
    *) return 1 ;;
  esac
}
for s in cleanup_worktrees.sh worktree_remove_hook.sh worktree_reap.sh cleanup_worktree_deps.sh \
         cleanup_worktree_venvs.sh reclaim_worktree_venvs.sh cleanup_colima.sh cleanup_codex_db.sh \
         cleanup_antigravity_brain.sh cleanup_sessions.sh prune_aside_sessions.sh prune_aside_sessions.py \
         cleanup_uv_cache.sh cleanup_downloads_evidence.sh cleanup_llm_inspector.sh \
         cleanup_supervisor_logs.sh cleanup_agent_artifacts.sh cleanup_apfs_snapshots.sh; do
  f="$ROOT/scripts/$s"
  [[ -f "$f" ]] || { bad "$s missing (update the list if it was folded)"; continue; }
  if grep -Eq "$marker" "$f"; then ok "$s routes through a logging primitive"
  elif reason="$(allow_reason "$s")"; then ok "$s allow-listed: $reason"
  else bad "$s removes data but neither logs nor is allow-listed"; fi
done

echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
