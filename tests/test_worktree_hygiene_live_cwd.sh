#!/usr/bin/env bash
# Regression: worktree_has_live_cwd must fail closed. An incomplete lsof scan, a
# live process that hides its cwd, or an unexpected lsof exit status must all be
# reported as "live" so hygiene never removes an occupied worktree.
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

mk_lsof() { printf '#!/bin/sh\n%s\n' "$1" > "$FB/lsof"; chmod +x "$FB/lsof"; }

mk_lsof_mount_warning() {
    cat > "$FB/lsof" <<'SH'
#!/bin/sh
printf "lsof: WARNING: can't stat() tracefs file system /sys/kernel/tracing\n      Output information may be incomplete.\n" >&2
exit 1
SH
    chmod +x "$FB/lsof"
}

check() {  # check <name> <want-rc>
    local name="$1" want="$2" got
    if PATH="$FB:$PATH" worktree_has_live_cwd "$WT"; then got=0; else got=$?; fi
    if [[ "$got" == "$want" ]]; then ok "$name"; else bad "$name (want rc=$want got rc=$got)"; fi
}

echo "== worktree_has_live_cwd fail-closed contracts =="

mk_lsof 'exit 1'
check "clean scan, no matches -> idle" 1

mk_lsof 'printf "p1\nfcwd\nn%s\n" "'"$WT"'/sub"; exit 0'
check "cwd inside the worktree -> live" 0

mk_lsof 'echo "lsof: totally unexpected diagnostic" >&2; exit 1'
check "unexpected stderr -> unknown (fail closed)" 0

mk_lsof_mount_warning
check "unrelated mount warning -> idle" 1

mk_lsof 'exit 3'
check "unexpected lsof exit status -> unknown (fail closed)" 0

mk_lsof 'printf "p1\nfcwd\nn/proc/1/cwd (readlink: Permission denied)\n"; exit 0'
check "live uninspectable process -> unknown (fail closed)" 0

if [[ -d /proc/self ]]; then
    dead=999999; while [[ -e "/proc/$dead" ]]; do dead=$((dead - 1)); done
    mk_lsof 'printf "p1\nfcwd\nn/proc/'"$dead"'/cwd (readlink: Permission denied)\n"; exit 0'
    check "exited pid denied record -> idle" 1
fi

printf 'worktree_has_live_cwd: %d passed, %d failed\n' "$P" "$F"
[[ "$F" -eq 0 ]]
