#!/usr/bin/env bash
# Machine-readable reporting metadata; caller supplies admitted Scratch TMPDIR.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/lib/scratch_budget.sh"
: "${TMPDIR:?admitted Scratch TMPDIR required}"
T="$(mktemp -d "$TMPDIR/pr322-metadata.XXXXXX")" || exit 2
trap 'rm -rf -- "$T"' EXIT
definition="$(sed -n '/^report_candidate_detail() {$/,/^}$/p' "$ROOT/scripts/cleanup_scratch_top_level.sh")"
[[ -n "$definition" ]] || exit 2
eval "$definition"
DETAIL_MIB=100 DETAIL_DEPTH=6
mkdir -p "$T/files" "$T/repository/.git"
truncate -s 200M "$T/files/payload"
printf 'protected\n' >"$T/repository/sentinel"
PASS=0 FAIL=0
for kind in measured opaque; do
  if [[ "$kind" == measured ]]; then entry="$T/files"; else entry="$T/repository"; fi
  kb="$(du -sk "$entry" | awk '{print $1}')"
  rows="$(report_candidate_detail "$entry" "$kb")"; rc=$?
  printf 'case=%s rc=%s\n%s\n' "$kind" "$rc" "$rows"
  if python3 - "$kind" "$entry" "$rows" "$rc" <<'PY'
import re, sys
kind, entry, output, rc = sys.argv[1:]
lines = output.splitlines()
flag = "F" if kind == "measured" else "G"
path = entry + "/payload" if kind == "measured" else entry
matches = [line for line in lines if line.startswith("detail:" + flag + " ")
           and path in line]
assert rc == "0" and len(matches) == 1, (rc, matches)
fields = dict(re.findall(r"(?:^|\s)([a-z_]+)=([^\s]+)", matches[0]))
assert fields.get("threshold_mib") == "100", fields
if kind == "measured":
    assert fields.get("bytes") == "209715200", fields
    assert fields.get("size_method") == "file-summed-apparent", fields
else:
    assert fields.get("size_method") == "unmeasured", fields
    assert fields.get("size_known") == "false", fields
    assert fields.get("age_known") == "false", fields
    assert not any(entry + "/sentinel" in line for line in lines), lines
PY
  then
    printf 'PASS: %s metadata\n' "$kind"; PASS=$((PASS + 1))
  else
    printf 'FAIL: %s metadata\n' "$kind"; FAIL=$((FAIL + 1))
  fi
done
printf 'PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
