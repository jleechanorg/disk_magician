#!/usr/bin/env bash
set -uo pipefail
unset BASH_ENV ENV

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRATCH="$(bash "$ROOT/disk_magician.sh" scratch-dir)" || {
  echo "test_measure_files: Scratch resolution failed" >&2
  exit 1
}
[[ -n "$SCRATCH" && "$SCRATCH" == /* && "$SCRATCH" != / && -d "$SCRATCH" ]] || {
  echo "test_measure_files: resolved Scratch path is unavailable: $SCRATCH" >&2
  exit 1
}
SCRATCH="$(cd -- "$SCRATCH" 2>/dev/null && pwd -P)" || {
  echo "test_measure_files: Scratch path could not be canonicalized" >&2
  exit 1
}
[[ -n "$SCRATCH" && "$SCRATCH" != / && -d "$SCRATCH" && ! -L "$SCRATCH" ]] || {
  echo "test_measure_files: canonical Scratch path is unavailable" >&2
  exit 1
}
T=""
cleanup_fixture() {
  [[ -n "${T:-}" && "$T" != / ]] || return 0
  case "$T" in
    "$SCRATCH"/.measure-files-test.*) ;;
    *) echo "test_measure_files: refusing unexpected fixture path: $T" >&2; return 1 ;;
  esac
  [[ -d "$T" && ! -L "$T" ]] || return 0
  chmod -R u+rwX "$T" 2>/dev/null || true
  rm -rf -- "$T"
}
trap cleanup_fixture EXIT
T="$(mktemp -d "$SCRATCH/.measure-files-test.XXXXXX")" || {
  echo "test_measure_files: fixture allocation failed under Scratch" >&2
  exit 1
}
[[ -n "$T" && "$T" != / && "$T" == "$SCRATCH"/.measure-files-test.* && -d "$T" && ! -L "$T" ]] || {
  echo "test_measure_files: refusing invalid fixture path: $T" >&2
  exit 1
}
T="$(cd -- "$T" 2>/dev/null && pwd -P)" || {
  echo "test_measure_files: fixture path could not be canonicalized" >&2
  exit 1
}
[[ "$T" == "$SCRATCH"/.measure-files-test.* && -d "$T" && ! -L "$T" ]] || {
  echo "test_measure_files: refusing escaped fixture path: $T" >&2
  exit 1
}
PASS=0; FAIL=0
ok() { echo "  PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
run() { bash "$ROOT/disk_magician.sh" measure-files "$@"; }
sparse_file() {
  python3 -c 'from pathlib import Path; import sys; f=Path(sys.argv[1]).open("wb"); f.truncate(int(sys.argv[2])); f.close()' "$1" "$2" \
    || { echo "test_measure_files: could not create sparse fixture: $1" >&2; exit 1; }
}
flag_for() { awk -F '\t' -v p="$1" '$5 == p {print $4}' <<<"$2"; }
bytes_for() { awk -F '\t' -v p="$1" '$5 == p {print $1}' <<<"$2"; }

help="$(run --help)"; rc=$?
if [[ "$rc" -eq 0 && "$help" == *"newest_epoch, flag, path"* \
   && "$help" == *"A=aggregated"* && "$help" == *"G=opaque Git"* \
   && "$help" == *"E=unreadable/unmeasured"* ]]; then
  ok 'help documents TSV columns and unknown-value flags'
else
  bad "help contract incomplete (rc=$rc)"
fi

# Large directories must be itemised recursively at the fixed 100 MiB floor.
BIG="$T/big"
mkdir -p "$BIG/nested"
sparse_file "$BIG/nested/a" 104857600
sparse_file "$BIG/nested/b" 1048576
out="$(run "$BIG")"; rc=$?
if [[ "$rc" -eq 0 ]]; then ok 'large tree measurement succeeds'; else bad "large tree rc=$rc"; fi
if [[ "$(flag_for "$BIG" "$out")" == "" && "$(flag_for "$BIG/nested" "$out")" == "" ]]; then
  ok '100 MiB ancestors are never aggregated'
else
  bad 'large ancestor was aggregated'
fi
if [[ "$(flag_for "$BIG/nested/a" "$out")" == F \
   && "$(bytes_for "$BIG/nested/a" "$out")" == 104857600 ]]; then
  ok '100 MiB file is reported individually'
else
  bad '100 MiB file missing or mis-sized'
fi
if [[ "$(flag_for "$BIG/nested/b" "$out")" == F ]]; then
  ok 'small sibling is also itemised below large ancestor'
else
  bad 'small sibling omitted'
fi

# A directory strictly below 100 MiB may be represented by one aggregate row.
SMALL="$T/small"
mkdir -p "$SMALL"
sparse_file "$SMALL/a" 52428800
out="$(run "$SMALL")"; rc=$?
if [[ "$rc" -eq 0 && "$(flag_for "$SMALL" "$out")" == A \
   && "$(bytes_for "$SMALL" "$out")" == 52428800 ]]; then
  ok 'sub-100 MiB directory is one apparent-size aggregate'
else
  bad 'sub-100 MiB aggregate mismatch'
fi

# Git trees are opaque even when large; their descendants are never enumerated.
GIT="$T/repo"
mkdir -p "$GIT/.git"
sparse_file "$GIT/payload" 125829120
out="$(run "$GIT")"; rc=$?
if [[ "$rc" -eq 0 && "$(flag_for "$GIT" "$out")" == G \
   && -z "$(awk -F '\t' -v p="$GIT/" 'index($5,p)==1 {print}' <<<"$out")" ]]; then
  ok 'Git root reports opaque G boundary only'
else
  bad 'Git subtree was traversed'
fi

# A symlink is measured as a link and its target is never followed.
LINK="$T/link-root"
mkdir -p "$LINK" "$T/target"
sparse_file "$LINK/real" 104857600
sparse_file "$T/target/payload" 125829120
ln -s "$T/target" "$LINK/linked"
out="$(run "$LINK")"; rc=$?
if [[ "$rc" -eq 0 && "$(flag_for "$LINK/linked" "$out")" == L \
   && "$(bytes_for "$LINK/linked" "$out")" -lt 4096 \
   && -z "$(awk -F '\t' -v p="$LINK/linked/" 'index($5,p)==1 {print}' <<<"$out")" ]]; then
  ok 'symlink row measures link without target traversal'
else
  bad 'symlink was followed or misreported'
  printf 'symlink_rows:\n%s\n' "$out"
fi
out="$(run "$LINK/linked/")"; rc=$?
if [[ "$rc" -eq 0 && "$(flag_for "$LINK/linked" "$out")" == L \
   && -z "$(awk -F '\t' -v p="$LINK/linked/" 'index($5,p)==1 {print}' <<<"$out")" ]]; then
  ok 'trailing slash does not turn a symlink path into its target directory'
else
  bad 'trailing slash caused the symlink target to be traversed'
  printf 'trailing_slash_rows:\n%s\n' "$out"
fi

# Unknown paths fail closed and deadlines use the shared monotonic parser.
out="$(run "$T/missing" 2>"$T/missing.err")"; rc=$?
if [[ "$rc" -eq 1 && "$(flag_for "$T/missing" "$out")" == E ]]; then
  ok 'missing path emits E row and nonzero status'
else
  bad "missing path did not fail closed (rc=$rc)"
fi
out="$(run "$SMALL" --deadline-at invalid 2>"$T/deadline.err")"; rc=$?
if [[ "$rc" -eq 2 ]]; then ok 'invalid deadline is rejected'; else bad "invalid deadline accepted (rc=$rc)"; fi
out="$(run "$BIG" --deadline-at 0 2>"$T/expired.err")"; rc=$?
if [[ "$rc" -eq 124 && "$(flag_for "$BIG" "$out")" == E ]]; then
  ok 'expired shared deadline fails closed with an E row'
else
  bad "expired deadline did not fail closed (rc=$rc)"
fi
out="$(run '////' --deadline-at 0 2>"$T/root-expired.err")"; rc=$?
if [[ "$rc" -eq 124 && "$(flag_for / "$out")" == E ]]; then
  ok 'trailing separators preserve the root path before an expired deadline fails closed'
else
  bad "root path was not normalized before deadline rejection (rc=$rc)"
fi

echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
