#!/usr/bin/env bash
set -uo pipefail
unset BASH_ENV ENV

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEST_SCRIPT="$ROOT/tests/test_measure_files.sh"
DISKM_SCRIPT="$ROOT/disk_magician.sh"
REAL_BASH="$(type -P bash)"
SCRATCH_ROOT="$("$REAL_BASH" "$DISKM_SCRIPT" scratch-dir 2>/dev/null)" || exit 1
[[ -n "$SCRATCH_ROOT" && "$SCRATCH_ROOT" == /* && "$SCRATCH_ROOT" != / &&
  -d "$SCRATCH_ROOT" ]] || exit 1
SCRATCH_ROOT="$(cd "$SCRATCH_ROOT" 2>/dev/null && pwd -P)" || exit 1
[[ -n "$SCRATCH_ROOT" && "$SCRATCH_ROOT" != / && -d "$SCRATCH_ROOT" && ! -L "$SCRATCH_ROOT" ]] || exit 1
WORK="$(mktemp -d "$SCRATCH_ROOT/.measure-files-guard.XXXXXX")" || exit 1
[[ -n "$WORK" && "$WORK" != / && "$WORK" == "$SCRATCH_ROOT"/.measure-files-guard.* &&
  -d "$WORK" && ! -L "$WORK" ]] || exit 1
WORK="$(cd "$WORK" 2>/dev/null && pwd -P)" || exit 1
[[ "$WORK" == "$SCRATCH_ROOT"/.measure-files-guard.* && -d "$WORK" && ! -L "$WORK" ]] || exit 1
cleanup_guard() {
  [[ -n "${WORK:-}" && "$WORK" != / && "$WORK" == "$SCRATCH_ROOT"/.measure-files-guard.* &&
    -d "$WORK" && ! -L "$WORK" ]] || return 0
  chmod -R u+rwx "$WORK" 2>/dev/null || true
  rm -rf -- "$WORK"
}
trap cleanup_guard EXIT

BIN="$WORK/bin"
MOCK_SCRATCH="$WORK/owned-scratch"
COMMAND_LOG="$WORK/fixture-command-attempts.log"
mkdir -p "$BIN" "$MOCK_SCRATCH" "$WORK/home"
: >"$COMMAND_LOG"

cat >"$BIN/bash" <<'EOF'
#!/bin/bash
set -euo pipefail
if [[ "$#" -eq 2 && "$1" == "$TEST_DISKMAGICIAN" && "$2" == scratch-dir ]]; then
  printf '%s\n' "$MOCK_SCRATCH_ROOT"
  exit 0
fi
exec "$REAL_BASH" "$@"
EOF
cat >"$BIN/mktemp" <<'EOF'
#!/bin/bash
printf 'mktemp\n' >>"$COMMAND_LOG"
exit 74
EOF
cat >"$BIN/mkdir" <<'EOF'
#!/bin/bash
printf 'mkdir\n' >>"$COMMAND_LOG"
exit 75
EOF
cat >"$BIN/python3" <<'EOF'
#!/bin/bash
printf 'python3\n' >>"$COMMAND_LOG"
exit 76
EOF
chmod 755 "$BIN/bash" "$BIN/mktemp" "$BIN/mkdir" "$BIN/python3"

rc=0
out="$(/usr/bin/env -i PATH="$BIN:/usr/bin:/bin" HOME="$WORK/home" \
  REAL_BASH="$REAL_BASH" TEST_DISKMAGICIAN="$DISKM_SCRIPT" MOCK_SCRATCH_ROOT="$MOCK_SCRATCH" \
  COMMAND_LOG="$COMMAND_LOG" "$REAL_BASH" "$TEST_SCRIPT" 2>&1)" || rc=$?
commands="$(tr '\n' ',' <"$COMMAND_LOG")"
if [[ "$rc" -ne 1 || "$out" != *"fixture allocation failed"* || "$commands" != mktemp, ]]; then
  echo "test_measure_files_fixture_guard: fail-closed allocation assertion failed (rc=$rc, fixture commands=$commands)" >&2
  exit 1
fi

echo "PASS: failed Scratch fixture allocation stops before mkdir or Python can run"
