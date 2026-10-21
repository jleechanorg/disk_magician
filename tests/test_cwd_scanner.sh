#!/usr/bin/env bash
# Tests for the passwordless root cwd scanner wiring (bead disk_magician-kub3):
# scripts/diskm_cwd_scan.py, lsof_scanner_fpn / lsof_snapshot_cwds in
# scripts/lib/lsof_linux.sh, wrh_live_cwd_reason, and the installer contract.
# Linux only; no root needed (the helper is faked through the sandbox override).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "$(uname -s)" != Linux ]]; then echo "SKIP: Linux only"; exit 0; fi
# shellcheck source=scripts/lib/lsof_linux.sh
source "$ROOT/scripts/lib/lsof_linux.sh"
# shellcheck source=scripts/worktree_remove_hook.sh
source "$ROOT/scripts/worktree_remove_hook.sh"
PASS=0; FAIL=0
ok() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/dm-cwdscan-test.XXXXXX")"
trap 'rm -rf "${TMP:?}"' EXIT
FB="$TMP/fakebin"; mkdir -p "$FB"
FAKE="$TMP/fake-scan"
export DISK_MAGICIAN_TEST_SANDBOX="$TMP"
export DISK_MAGICIAN_CWD_SCAN_CMD="$FAKE"

# A lsof that would report an empty, "complete" map if (wrongly) consulted.
mk_lsof_marker() { printf '#!/bin/sh\ntouch %s/lsof-called\nprintf "p1\\nfcwd\\nn/\\n"\n' "$TMP" >"$FB/lsof"; chmod +x "$FB/lsof"; }

echo "== helper script =="
HELPER="$ROOT/scripts/diskm_cwd_scan.py"
real="$TMP/real.out"
if /usr/bin/python3 -I "$HELPER" >"$real"; then ok "helper exits 0 unprivileged"; else bad "helper failed"; fi
[[ "$(tr -cd '\0' <"$real" | wc -c)" -gt 0 ]] && ok "helper emits NUL-terminated records" || bad "no records"
grep -aq "^1"$'\t' "$real" && ok "helper reports pid 1" || bad "pid 1 missing from real scan"
/usr/bin/python3 -I "$HELPER" extra >/dev/null 2>&1 && bad "helper accepted an argument" || ok "helper rejects arguments"
head -1 "$HELPER" | grep -q '^#!/usr/bin/python3 -I$' && ok "helper pins interpreter and isolated mode" || bad "helper shebang"
DISK_MAGICIAN_CWD_SCAN_CMD="$HELPER"; lsof_scanner_fpn && ok "real helper output parses" || bad "real helper output rejected"
export DISK_MAGICIAN_CWD_SCAN_CMD="$FAKE"

echo "== complete map -> candidates decided from it =="
mk_lsof_marker
cat >"$FAKE" <<'SH'
#!/bin/sh
printf '1\t0\t/\0'
printf '4242\t1001\t/tmp/live-foreign/sub\0'
printf '900\t1000\t/home/me\0'
SH
chmod +x "$FAKE"
lsof_snapshot_cwds && ok "scanner map accepted" || bad "scanner map rejected: $LSOF_CWD_REASON"
[[ ! -e "$TMP/lsof-called" ]] && ok "lsof not consulted when scanner succeeds" || bad "lsof consulted"
cwd_list_has_path /tmp/idle-candidate "$LSOF_CWDS" && bad "idle candidate kept" || ok "candidate with no live cwd is removable"
cwd_list_has_path /tmp/live-foreign "$LSOF_CWDS" && ok "foreign-uid live cwd keeps candidate" || bad "foreign-uid cwd missed"
cd / && wrh_live_cwd_reason /tmp/idle-candidate; [[ -z "$WRH_LIVE_CWD_REASON" ]] && ok "hook: idle candidate removable" || bad "hook: idle gave $WRH_LIVE_CWD_REASON"
wrh_live_cwd_reason /tmp/live-foreign; [[ "$WRH_LIVE_CWD_REASON" == live-cwd ]] && ok "hook: foreign live cwd kept" || bad "hook: foreign gave '$WRH_LIVE_CWD_REASON'"

echo "== helper missing / sudo -n failing -> unchanged unprivileged path =="
rm -f "$TMP/lsof-called"
unset DISK_MAGICIAN_CWD_SCAN_CMD
saved_bin="$LSOF_SCANNER_BIN"; LSOF_SCANNER_BIN="$TMP/does-not-exist"
lsof_scanner_fpn; [[ $? == 1 ]] && ok "absent helper -> rc 1 (fallback)" || bad "absent helper rc"
printf '#!/bin/sh\necho "lsof: foreign process hides cwd" >&2\necho "p1"; echo fcwd; echo "n/proc/1/cwd (readlink: Permission denied)"\n' >"$FB/lsof"; chmod +x "$FB/lsof"
PATH="$FB:$PATH" lsof_snapshot_cwds && bad "fallback unexpectedly succeeded" || ok "absent helper: fail-closed lsof result unchanged ($LSOF_CWD_REASON)"
LSOF_SCANNER_BIN="$saved_bin"
printf '#!/bin/sh\nexit 1\n' >"$FAKE"; chmod +x "$FAKE"
export DISK_MAGICIAN_CWD_SCAN_CMD="$FAKE"
lsof_scanner_fpn; [[ $? == 1 ]] && ok "sudo -n failure (exit 1) -> rc 1 (fallback)" || bad "failing helper rc"
PATH="$FB:$PATH" lsof_snapshot_cwds && bad "failing helper: fallback succeeded" || ok "failing helper: fail-closed lsof result unchanged"
printf '#!/bin/sh\nprintf "1\\t0\\t/\\0"\n' >"$FAKE"
unset DISK_MAGICIAN_TEST_SANDBOX; LSOF_SCANNER_BIN="$TMP/does-not-exist"
lsof_scanner_fpn; [[ $? == 1 ]] && ok "override ignored outside the test sandbox" || bad "override honoured without sandbox"
LSOF_SCANNER_BIN="$saved_bin"; export DISK_MAGICIAN_TEST_SANDBOX="$TMP"

echo "== malformed helper output fails closed, no fallback =="
mk_lsof_marker
chk_malformed() {  # chk_malformed <name>  (fake already written)
    rm -f "$TMP/lsof-called"
    PATH="$FB:$PATH" lsof_snapshot_cwds && { bad "$1 accepted"; return; }
    [[ "$LSOF_CWD_REASON" == scanner-malformed && ! -e "$TMP/lsof-called" ]] && ok "$1 rejected" || bad "$1 reason='$LSOF_CWD_REASON' lsof-called=$([[ -e $TMP/lsof-called ]] && echo y || echo n)"
}
printf '#!/bin/sh\nprintf "1\\t0\\t/"\n' >"$FAKE"; chk_malformed "missing final NUL"
printf '#!/bin/sh\nprintf "1\\t0\\t/\\0abc\\t0\\t/x\\0"\n' >"$FAKE"; chk_malformed "non-numeric pid"
printf '#!/bin/sh\nprintf "1\\t0\\t/\\0"\nprintf "2\\tx\\t/a\\0"\n' >"$FAKE"; chk_malformed "non-numeric uid"
printf '#!/bin/sh\nprintf "1\\t0\\trelative\\0"\n' >"$FAKE"; chk_malformed "relative cwd"
printf '#!/bin/sh\nprintf "1\\t0\\t/a\\nb\\0"\n' >"$FAKE"; chk_malformed "newline in cwd"
printf '#!/bin/sh\nprintf "2\\t0\\t/a\\0"\n' >"$FAKE"; chk_malformed "map without pid 1"
printf '#!/bin/sh\nprintf "1\\t0\\0"\n' >"$FAKE"; chk_malformed "missing field"
printf '#!/bin/sh\nexit 0\n' >"$FAKE"; chk_malformed "empty output"
printf '#!/bin/sh\nprintf "1\\t0\\t/\\0"\n' >"$FAKE"
cd / && PATH="$FB:$PATH" wrh_live_cwd_reason /tmp/x; [[ -z "$WRH_LIVE_CWD_REASON" ]] && ok "minimal valid map accepted" || bad "minimal map: $WRH_LIVE_CWD_REASON"
printf '#!/bin/sh\nprintf "1\\t0\\t/"\n' >"$FAKE"
PATH="$FB:$PATH" wrh_live_cwd_reason /tmp/x; [[ "$WRH_LIVE_CWD_REASON" == cwd-unknown ]] && ok "hook: malformed map fails closed" || bad "hook malformed: '$WRH_LIVE_CWD_REASON'"

echo "== installer contract =="
out="$(bash "$ROOT/scripts/install_cwd_scanner.sh" --dry-run --user nobody 2>&1)"; rc=$?
[[ $rc == 0 ]] && ok "dry-run exits 0" || bad "dry-run rc=$rc: $out"
grep -qF 'nobody ALL=(root) NOPASSWD: /usr/local/sbin/diskm-cwd-scan ""' <<<"$out" && ok "sudoers rule forbids arguments" || bad "rule text: $out"
bash "$ROOT/scripts/install_cwd_scanner.sh" --user 'x;rm' --dry-run >/dev/null 2>&1 && bad "unsafe user accepted" || ok "unsafe user rejected"
bash "$ROOT/scripts/install_cwd_scanner.sh" --user root --dry-run >/dev/null 2>&1 && bad "root user accepted" || ok "root target rejected"
if [[ "$(id -u)" != 0 ]]; then
  bash "$ROOT/scripts/install_cwd_scanner.sh" --user nobody >/dev/null 2>&1 && bad "non-root install did not refuse" || ok "non-root install refused"
fi
"$ROOT/disk_magician.sh" install-cwd-scanner --help 2>&1 | grep -q Usage && ok "diskm dispatches install-cwd-scanner" || bad "dispatcher"

echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
