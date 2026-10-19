#!/usr/bin/env bash
# Tests for scripts/lib/lsof_linux.sh — the single strict interpreter of
# `lsof -d cwd -Fpn` output for every live-cwd gate.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/lsof_linux.sh
source "$REPO_ROOT/scripts/lib/lsof_linux.sh"
PASS=0; FAIL=0
ok() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
eq() { [[ "$2" == "$3" ]] && ok "$1" || bad "$1 (want '$3' got '$2')"; }

echo "== lsof_stderr_incomplete =="
mount_warn=$'lsof: WARNING: can\'t stat() tracefs file system /sys/kernel/debug/tracing\n      Output information may be incomplete.'
lsof_stderr_incomplete "" && bad "empty stderr flagged" || ok "empty stderr is complete"
lsof_stderr_incomplete "$mount_warn" && bad "mount-stat warning flagged" || ok "mount-stat warning alone is complete"
lsof_stderr_incomplete "$mount_warn"$'\nlsof: WARNING: can\'t open /proc/42/fd: Permission denied' && ok "other warning still incomplete" || bad "other warning ignored"
lsof_stderr_incomplete $'      Output information may be incomplete.\nlsof: WARNING: can\'t stat() file /home/x/wt: No such file' && ok "non-mount stat warning still incomplete" || bad "non-mount stat warning ignored"

echo "== lsof_cwd_blocks =="
eq "two complete blocks" \
  "$(lsof_cwd_blocks <<< $'p1\nfcwd\nn/home/a\np2\nfcwd\nn/home/b')" \
  $'1|ok|/home/a\n2|ok|/home/b'
eq "missing n record" "$(lsof_cwd_blocks <<< $'p1\nfcwd')" '1|incomplete|'
eq "p+n block without f (-Fpn shape)" "$(lsof_cwd_blocks <<< $'p1\nn/home/a')" '1|ok|/home/a'
eq "kernel-thread block with no cwd" "$(lsof_cwd_blocks <<< $'p1')" '1|nofd|'
eq "duplicate n record" "$(lsof_cwd_blocks <<< $'p1\nfcwd\nn/a\nn/b')" '1|bad|'
eq "duplicate f record" "$(lsof_cwd_blocks <<< $'p1\nfcwd\nfcwd\nn/a')" '1|bad|'
eq "empty pid" "$(lsof_cwd_blocks <<< $'p\nfcwd\nn/a')" '|bad|'
eq "record before first pid" "$(lsof_cwd_blocks <<< $'fcwd\nn/a\np1\nfcwd\nn/b')" $'1|ok|/b\n-|bad|'
eq "stray field" "$(lsof_cwd_blocks <<< $'p1\nfcwd\nn/a\nz')" '1|bad|'

echo "== lsof_cwd_value_verdict =="
eq "absolute path resolved" "$(lsof_cwd_value_verdict /home/a)" resolved
eq "relative path unknown" "$(lsof_cwd_value_verdict relative/path)" unknown
eq "stat diagnostic unknown" "$(lsof_cwd_value_verdict '/mnt/x (stat: Permission denied)')" unknown
eq "lstat diagnostic unknown" "$(lsof_cwd_value_verdict '/mnt/x (lstat: Permission denied)')" unknown
eq "other readlink diagnostic unknown" "$(lsof_cwd_value_verdict '/proc/7/cwd (readlink: Operation not permitted)')" unknown
if [[ -d /proc/self ]]; then
  eq "foreign denied pid unknown by default" "$(lsof_cwd_value_verdict '/proc/1/cwd (readlink: Permission denied)' 2>/dev/null)" unknown
  sleep 30 & own_pid=$!
  eq "own unreadable pid unknown by default" "$(lsof_cwd_value_verdict "/proc/$own_pid/cwd (readlink: Permission denied)" 2>/dev/null)" unknown
  eq "approved unreadable pid ignorable" \
     "$(DISK_MAGICIAN_UNSCANNABLE_CWD_APPROVED=1 lsof_cwd_value_verdict "/proc/$own_pid/cwd (readlink: Permission denied)" 2>/dev/null)" ignorable
  kill "$own_pid" 2>/dev/null
  dead=999999; while [[ -e /proc/$dead ]]; do dead=$((dead - 1)); done
  eq "exited pid ignorable" "$(lsof_cwd_value_verdict "/proc/$dead/cwd (readlink: Permission denied)" 2>/dev/null)" ignorable
else
  eq "denied pid unknown without procfs" "$(lsof_cwd_value_verdict '/proc/1/cwd (readlink: Permission denied)' 2>/dev/null)" unknown
fi

echo "== lsof_collect_cwds =="
lsof_collect_cwds $'p1\nfcwd\nn/home/a\np2\nfcwd\nn/home/b' "" 0 && ok "complete scan accepted" || bad "complete scan rejected ($LSOF_CWD_REASON)"
eq "complete scan cwd list" "$LSOF_CWDS" $'/home/a\n/home/b'
lsof_collect_cwds $'p1\nfcwd' "" 0 && bad "incomplete block accepted" || ok "incomplete block rejected: $LSOF_CWD_REASON"
lsof_collect_cwds $'p1\nfcwd\nn/home/a' "" 2 && bad "nonzero rc accepted" || ok "nonzero rc rejected: $LSOF_CWD_REASON"
lsof_collect_cwds $'p1\nfcwd\nn/home/a' "lsof: cannot stat" 0 && bad "unexpected stderr accepted" || ok "unexpected stderr rejected: $LSOF_CWD_REASON"
lsof_collect_cwds "" "" 0 && bad "empty output accepted" || ok "empty output rejected: $LSOF_CWD_REASON"
lsof_collect_cwds $'p1\nfcwd\nnrelative' "" 0 && bad "relative path accepted" || ok "relative path rejected: $LSOF_CWD_REASON"
lsof_collect_cwds $'p\nfcwd\nn/a\np1\nfcwd\nn/b' "" 0 && bad "empty pid accepted" || ok "empty pid rejected: $LSOF_CWD_REASON"
lsof_collect_cwds $'fcwd\nn/a\np1\nfcwd\nn/b' "" 0 && bad "record before first pid accepted" || ok "record before first pid rejected: $LSOF_CWD_REASON"
lsof_collect_cwds $'p1\np2\nfcwd\nn/b' "" 0 && bad "pid-only block accepted" || ok "pid-only block rejected: $LSOF_CWD_REASON"
lsof_collect_cwds $'n/a\nn/b' "" 0 && bad "pid-less scan accepted" || ok "pid-less scan rejected: $LSOF_CWD_REASON"
lsof_stderr_incomplete $'      Output information may be incomplete.' && ok "standalone trailer incomplete" || bad "standalone trailer trusted"
lsof_stderr_incomplete $'lsof: WARNING: can\'t stat() apfs file system /' && ok "root mount warning incomplete" || bad "root mount warning trusted"
if [[ -d /proc/self ]]; then
  dead=999999; while [[ -e /proc/$dead ]]; do dead=$((dead - 1)); done
  lsof_collect_cwds $'p1\nfcwd\nn/proc/'"$dead"'/cwd (readlink: Permission denied)' "" 0 \
    && bad "only-exited-denied accepted" || ok "only-exited-denied rejected: $LSOF_CWD_REASON"
  lsof_collect_cwds $'p1\nfcwd\nn/proc/1/cwd (readlink: Permission denied)' "" 0 \
    && bad "denied-only scan accepted as complete" || ok "denied-only scan rejected: $LSOF_CWD_REASON"
fi

echo "== cwd_list_has_path =="
cwds=$'/home/a\n/home/work/wt/sub'
cwd_list_has_path /home/work/wt "$cwds" && ok "cwd beneath the candidate matches" || bad "cwd beneath the candidate missed"
cwd_list_has_path /home/a "$cwds" && ok "exact cwd match" || bad "exact cwd match missed"
cwd_list_has_path /home/other "$cwds" && bad "unrelated path matched" || ok "unrelated path rejected"
cwd_list_has_path /home/work/wt/sub "$cwds" && ok "exact deeper cwd match" || bad "exact deeper cwd missed"
cwd_list_has_path /home/work/wt/sub/deeper "$cwds" && bad "cwd above the candidate matched" || ok "cwd above the candidate rejected"

echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
