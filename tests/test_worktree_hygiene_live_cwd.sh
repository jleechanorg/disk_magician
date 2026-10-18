#!/usr/bin/env bash
# Regression: worktree_has_live_cwd must fail closed. "Cannot prove idle"
# includes an incomplete scan, an unexpected exit status, no usable cwd records,
# and any live or malformed uninspectable record.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../scripts/worktree_hygiene.sh
source "$ROOT/scripts/worktree_hygiene.sh"

P=0; F=0
ok()  { P=$((P+1)); printf '  PASS: %s\n' "$1"; }
bad() { F=$((F+1)); printf '  FAIL: %s\n' "$1"; }

base="${TMPDIR:-/tmp}"
mkdir -p "$base/dm-hyg-cwd"
TMP="$(mktemp -d "$base/dm-hyg-cwd/run.XXXXXX")"
trap 'rm -rf "${TMP:?}"' EXIT
WT="$TMP/wt"; mkdir -p "$WT/sub"
FB="$TMP/fakebin"; mkdir -p "$FB"

mk_lsof() {  # mk_lsof <heredoc body>
    cat > "$FB/lsof"
    chmod +x "$FB/lsof"
}

check() {  # check <name> <want-rc>
    local name="$1" want="$2" got
    if PATH="$FB:$PATH" worktree_has_live_cwd "$WT"; then got=0; else got=$?; fi
    if [[ "$got" == "$want" ]]; then ok "$name"; else bad "$name (want rc=$want got rc=$got)"; fi
}

echo "== worktree_has_live_cwd fail-closed contracts =="

mk_lsof <<'SH'
#!/bin/sh
exit 1
SH
check "no result set (lsof rc=1) -> unknown" 0

mk_lsof <<'SH'
#!/bin/sh
printf 'p1\nfcwd\nn/tmp/somewhere-else\n'
exit 0
SH
check "complete scan, cwd elsewhere -> idle" 1

mk_lsof <<SH
#!/bin/sh
printf 'p1\\nfcwd\\nn$WT/sub\\n'
exit 0
SH
check "cwd inside the worktree -> live" 0

mk_lsof <<'SH'
#!/bin/sh
printf 'p1\nfcwd\nn/tmp/somewhere-else\n'
printf 'lsof: totally unexpected diagnostic\n' >&2
exit 0
SH
check "unexpected stderr -> unknown (fail closed)" 0

mk_lsof <<'SH'
#!/bin/sh
printf 'p1\nfcwd\nn/tmp/somewhere-else\n'
printf "lsof: WARNING: can't stat() tracefs file system /sys/kernel/tracing\n      Output information may be incomplete.\n" >&2
exit 0
SH
check "unrelated mount warning -> idle" 1

mk_lsof <<'SH'
#!/bin/sh
printf 'p1\nfcwd\nn/tmp/somewhere-else\n'
exit 3
SH
check "unexpected lsof exit status -> unknown" 0

mk_lsof <<'SH'
#!/bin/sh
printf 'p1\nfcwd\nn/proc/1/cwd (readlink: Permission denied)\n'
exit 0
SH
check "live uninspectable process -> unknown" 0

mk_lsof <<'SH'
#!/bin/sh
printf 'p1\nfcwd\nn/tmp/x (stat: Permission denied)\n'
exit 0
SH
check "stat-denied record -> unknown" 0

mk_lsof <<'SH'
#!/bin/sh
printf 'p1\nfcwd\nnrelative/path\n'
exit 0
SH
check "malformed non-absolute record -> unknown" 0

mk_lsof <<'SH'
#!/bin/sh
printf 'p1\nfcwd\np2\nfcwd\n'
exit 0
SH
check "no cwd records -> unknown" 0

if [[ -d /proc/self ]]; then
    dead=999999; while [[ -e "/proc/$dead" ]]; do dead=$((dead - 1)); done
    cat > "$FB/lsof" <<SH
#!/bin/sh
printf 'p1\\nfcwd\\nn/tmp/somewhere-else\\nn/proc/$dead/cwd (readlink: Permission denied)\\n'
exit 0
SH
    chmod +x "$FB/lsof"
    check "exited pid denied record -> idle" 1
fi

printf 'worktree_has_live_cwd: %d passed, %d failed\n' "$P" "$F"
[[ "$F" -eq 0 ]]
