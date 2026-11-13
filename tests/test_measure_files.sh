#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRATCH="$(bash "$ROOT/disk_magician.sh" scratch-dir)"
[[ -n "$SCRATCH" && "$SCRATCH" != / && -d "$SCRATCH" ]] || {
  echo "test_measure_files: resolved Scratch path is unavailable: $SCRATCH" >&2
  exit 1
}
T="$(mktemp -d "$SCRATCH/.measure-files-test.XXXXXX")"
cleanup_fixture() {
  case "$T" in
    "$SCRATCH"/.measure-files-test.*) ;;
    *) echo "test_measure_files: refusing unexpected fixture path: $T" >&2; return 1 ;;
  esac
  [[ -d "$T" && ! -L "$T" ]] || return 0
  chmod -R u+rwX "$T" 2>/dev/null
  rm -rf -- "$T"
}
trap cleanup_fixture EXIT
PASS=0; FAIL=0
ok() { echo "  PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
run() { bash "$ROOT/disk_magician.sh" measure-files "$@"; }
sparse_file() {
  python3 -c 'from pathlib import Path; import sys; f=Path(sys.argv[1]).open("wb"); f.truncate(int(sys.argv[2])); f.close()' "$1" "$2"
}
flag_for() { awk -F '\t' -v p="$1" '$5 == p {print $4}' <<<"$2"; }
bytes_for() { awk -F '\t' -v p="$1" '$5 == p {print $1}' <<<"$2"; }

help="$(run --help)"; rc=$?
[[ "$rc" -eq 0 && "$help" == *"newest_epoch, flag, path"* \
   && "$help" == *"A=aggregated"* && "$help" == *"G=opaque Git"* \
   && "$help" == *"E=unreadable/unmeasured"* ]] \
  && ok 'help documents TSV columns and unknown-value flags' \
  || bad "help contract incomplete (rc=$rc)"

# Large directories must be itemised recursively at the fixed 100 MiB floor.
BIG="$T/big"
mkdir -p "$BIG/nested"
sparse_file "$BIG/nested/a" 104857600
sparse_file "$BIG/nested/b" 1048576
out="$(run "$BIG")"; rc=$?
[[ "$rc" -eq 0 ]] && ok 'large tree measurement succeeds' || bad "large tree rc=$rc"
[[ "$(flag_for "$BIG" "$out")" == "" && "$(flag_for "$BIG/nested" "$out")" == "" ]] \
  && ok '100 MiB ancestors are never aggregated' || bad 'large ancestor was aggregated'
[[ "$(flag_for "$BIG/nested/a" "$out")" == F && "$(bytes_for "$BIG/nested/a" "$out")" == 104857600 ]] \
  && ok '100 MiB file is reported individually' || bad '100 MiB file missing or mis-sized'
[[ "$(flag_for "$BIG/nested/b" "$out")" == F ]] \
  && ok 'small sibling is also itemised below large ancestor' || bad 'small sibling omitted'

# A directory strictly below 100 MiB may be represented by one aggregate row.
SMALL="$T/small"
mkdir -p "$SMALL"
sparse_file "$SMALL/a" 52428800
out="$(run "$SMALL")"; rc=$?
[[ "$rc" -eq 0 && "$(flag_for "$SMALL" "$out")" == A \
   && "$(bytes_for "$SMALL" "$out")" == 52428800 ]] \
  && ok 'sub-100 MiB directory is one apparent-size aggregate' \
  || bad 'sub-100 MiB aggregate mismatch'

# Git trees are opaque even when large; their descendants are never enumerated.
GIT="$T/repo"
mkdir -p "$GIT/.git"
truncate -s 120M "$GIT/payload"
out="$(run "$GIT")"; rc=$?
[[ "$rc" -eq 0 && "$(flag_for "$GIT" "$out")" == G \
   && -z "$(awk -F '\t' -v p="$GIT/" 'index($5,p)==1 {print}' <<<"$out")" ]] \
  && ok 'Git root reports opaque G boundary only' || bad 'Git subtree was traversed'

# A symlink is measured as a link and its target is never followed.
LINK="$T/link-root"
mkdir -p "$LINK" "$T/target"
sparse_file "$LINK/real" 104857600
sparse_file "$T/target/payload" 125829120
ln -s "$T/target" "$LINK/linked"
out="$(run "$LINK")"; rc=$?
[[ "$rc" -eq 0 && "$(flag_for "$LINK/linked" "$out")" == L \
   && "$(bytes_for "$LINK/linked" "$out")" -lt 4096 \
   && -z "$(awk -F '\t' -v p="$LINK/linked/" 'index($5,p)==1 {print}' <<<"$out")" ]] \
  && ok 'symlink row measures link without target traversal' \
  || { bad 'symlink was followed or misreported'; printf 'symlink_rows:\n%s\n' "$out"; }

# Unknown paths fail closed and deadlines use the shared monotonic parser.
out="$(run "$T/missing" 2>"$T/missing.err")"; rc=$?
[[ "$rc" -eq 1 && "$(flag_for "$T/missing" "$out")" == E ]] \
  && ok 'missing path emits E row and nonzero status' \
  || bad "missing path did not fail closed (rc=$rc)"
out="$(run "$SMALL" --deadline-at invalid 2>"$T/deadline.err")"; rc=$?
[[ "$rc" -eq 2 ]] && ok 'invalid deadline is rejected' \
  || bad "invalid deadline accepted (rc=$rc)"
out="$(run "$BIG" --deadline-at 0 2>"$T/expired.err")"; rc=$?
[[ "$rc" -eq 124 && "$(flag_for "$BIG" "$out")" == E ]] \
  && ok 'expired shared deadline fails closed with an E row' \
  || bad "expired deadline did not fail closed (rc=$rc)"

echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
