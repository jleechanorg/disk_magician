#!/usr/bin/env bash
# scratch_budget_measure_files: reporting must stop at a floor instead of printing
# ONE `du` total per candidate. The aggregate total is what hid 23.7 GiB of stale
# Android build dirs inside a 35 GiB Scratch tree (2026-11-03), so at or above the
# threshold the walker must itemise, and only below it may it aggregate.
#
# Fixtures use sparse files (apparent size, so `truncate -s 120M` costs no disk)
# and live under caller-supplied admitted TMPDIR.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/scripts/lib/scratch_budget.sh"

T="$(mktemp -d "${TMPDIR:?admitted Scratch TMPDIR required}/.dm-mf-test.XXXXXX")"
trap 'chmod -R u+rwX "$T" 2>/dev/null; rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok()  { echo "  PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

# Aggregate row = flag A; anything else is an itemised/kind row.
rows_for() { awk -F'\t' -v p="$1" '$5 == p' <<<"$2"; }
flags_of() { awk -F'\t' -v p="$1" '$5 == p {print $4}' <<<"$2"; }
bytes_of() { awk -F'\t' -v p="$1" '$5 == p {print $1}' <<<"$2"; }

# 1. A 200 MiB directory is itemised, not aggregated as one 200 MiB row.
BIG="$T/big"
mkdir -p "$BIG"
truncate -s 120M "$BIG/f1" && truncate -s 80M "$BIG/f2"
out="$(scratch_budget_measure_files "$BIG" 100)"; rc=$?
[[ "$rc" -eq 0 ]] && ok "200 MiB tree measured without error" || bad "200 MiB tree returned rc=$rc"
[[ "$(flags_of "$BIG" "$out")" == "" ]] \
  && ok "200 MiB directory is not aggregated" || bad "200 MiB directory aggregated into one row"
grep -q 'F	'"$BIG"'/f1$' <<<"$out" && grep -q 'F	'"$BIG"'/f2$' <<<"$out" \
  && ok "both 200 MiB children reported as their own file rows" \
  || bad "200 MiB children missing itemised rows"
[[ "$(awk -F'\t' -v d="$BIG" 'index($5, d "/") == 1 {s += $1} END {print s+0}' <<<"$out")" == "209715200" ]] \
  && ok "itemised rows sum to the 200 MiB total" || bad "itemised rows do not sum to the tree total"

# 2. A 50 MiB directory is ONE aggregated row.
SMALL="$T/small"
mkdir -p "$SMALL"
truncate -s 30M "$SMALL/a" && truncate -s 20M "$SMALL/b"
out="$(scratch_budget_measure_files "$SMALL" 100)"; rc=$?
[[ "$rc" -eq 0 ]] && ok "50 MiB tree measured without error" || bad "50 MiB tree returned rc=$rc"
[[ "$(wc -l <<<"$out")" -eq 1 ]] && ok "50 MiB tree reported as exactly one row" \
  || bad "50 MiB tree reported as $(wc -l <<<"$out") rows"
[[ "$(flags_of "$SMALL" "$out")" == "A" ]] && ok "50 MiB row is flagged aggregated" \
  || bad "50 MiB row not flagged A (got '$(flags_of "$SMALL" "$out")')"
[[ "$(bytes_of "$SMALL" "$out")" == "52428800" ]] && ok "50 MiB aggregate carries the full 52428800 bytes" \
  || bad "50 MiB aggregate bytes wrong: '$(bytes_of "$SMALL" "$out")'"
[[ "$(awk -F'\t' '$5 == "'"$SMALL"'" {print $2}' <<<"$out")" == "2" ]] \
  && ok "aggregate row counts both files" || bad "aggregate row file count wrong"

# 3. The threshold is honoured AT the boundary: exactly 100 MiB is never
#    aggregated at 100, including an attempted ceiling above 100.
EXACT="$T/exact"
mkdir -p "$EXACT"
truncate -s 100M "$EXACT/f"
out="$(scratch_budget_measure_files "$EXACT" 100)"
grep -q 'A	'"$EXACT"'$' <<<"$out" \
  && bad "100 MiB aggregated at a 100 MiB threshold" \
  || ok "100 MiB directory itemised at a 100 MiB threshold"
out="$(scratch_budget_measure_files "$EXACT" 101)"
[[ "$(flags_of "$EXACT" "$out")" != "A" ]] && ok "101 MiB configuration capped to100 MiB" \
  || bad "configured ceiling above100 MiB hid the directory"

# 4. Symlinks are never followed: a link to a 200 MiB tree contributes the link
#    itself (a few dozen bytes), never the target's bytes.
LINK_DIR="$T/linked"
mkdir -p "$LINK_DIR"
truncate -s 200M "$LINK_DIR/real"
ln -s "$LINK_DIR/real" "$LINK_DIR/link-to-real"
out="$(scratch_budget_measure_files "$LINK_DIR" 100)"
[[ "$(flags_of "$LINK_DIR/link-to-real" "$out")" == "L" ]] \
  && ok "symlink reported as its own link row" || bad "symlink not reported as a link row"
[[ "$(bytes_of "$LINK_DIR/link-to-real" "$out")" -lt 4096 ]] \
  && ok "symlink row carries the link size, not the 200 MiB target" \
  || bad "symlink row followed the target ($(bytes_of "$LINK_DIR/link-to-real" "$out") bytes)"
[[ "$(awk -F'\t' -v d="$LINK_DIR" 'index($5, d "/link-to-real/") == 1' <<<"$out" | wc -l)" -eq 0 ]] \
  && ok "nothing below the symlink was walked" || bad "walked through a symlink"

# 5. An unreadable subdirectory is reported, never silently skipped.
UNR="$T/unreadable"
mkdir -p "$UNR/blocked"
truncate -s 200M "$UNR/readable"
chmod 000 "$UNR/blocked"
errs="$T/err5"
out="$(scratch_budget_measure_files "$UNR" 100 2>"$errs")"; rc=$?
chmod 755 "$UNR/blocked"
if [[ "$(id -u)" == 0 ]]; then
  echo "  SKIP: unreadable-subdir case needs a non-root user (root reads mode 000)"
else
  grep -q 'E	'"$UNR"'/blocked$' <<<"$out" \
    && ok "unreadable subdirectory reported as its own E row" \
    || bad "unreadable subdirectory swallowed (no E row)"
  [[ "$rc" -eq 1 ]] && ok "unreadable subtree fails closed (rc=1)" || bad "unreadable subtree returned rc=$rc"
  [[ -s "$errs" ]] && ok "unreadable subtree named on stderr" || bad "unreadable subtree not named on stderr"
  [[ "$(awk -F'\t' -v d="$UNR" 'index($5, d "/blocked/") == 1' <<<"$out" | wc -l)" -eq 0 ]] \
    && ok "no rows fabricated beneath the unreadable directory" \
    || bad "rows emitted beneath an unreadable directory"
fi

# 6. A large descendant is itemised even below the former six-level stop.
DEEP="$T/deep"
PAYLOAD="$DEEP/a/b/c/d/e/f/g/h/i/payload"
mkdir -p "$(dirname "$PAYLOAD")"
truncate -s 150M "$PAYLOAD"
out="$(scratch_budget_measure_files "$DEEP" 100)"
[[ "$(flags_of "$PAYLOAD" "$out")" == "F" ]] \
  && ok "deep large payload reported as a file" \
  || bad "deep large payload not itemised"
[[ "$(awk -F'\t' '$4 == "T" {n++} END {print n+0}' <<<"$out")" == "0" ]] \
  && ok "no depth-truncated row substitutes for itemisation" \
  || bad "depth-truncated row remains"
[[ "$(bytes_of "$PAYLOAD" "$out")" == "157286400" ]] \
  && ok "deep file row carries the real 150 MiB" \
  || bad "deep file row lost the payload size"
[[ "$(wc -l <<<"$out")" -eq 1 ]] \
  && ok "only the payload is reported, not ancestor aggregates" \
  || bad "unexpected ancestor or duplicate rows"

echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
