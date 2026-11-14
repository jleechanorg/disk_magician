#!/usr/bin/env bash
# The public report has one size stop; deep large artifacts must reach files.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/lib/scratch_budget.sh"
: "${TMPDIR:?admitted Scratch TMPDIR required}"
T="$(mktemp -d "$TMPDIR/pr322-deep-report.XXXXXX")" || exit 2
trap 'rm -rf -- "$T"' EXIT
definition="$(sed -n '/^report_candidate_detail() {$/,/^}$/p' "$ROOT/scripts/cleanup_scratch_top_level.sh")"
[[ -n "$definition" ]] || { echo 'report caller absent' >&2; exit 2; }
eval "$definition"
DETAIL_MIB=100
DETAIL_DEPTH=6
payload="$T/artifact/a/b/c/d/e/f/g/h/i/payload"
mkdir -p "$(dirname "$payload")"
truncate -s 200M "$payload"
kb="$(du -sk "$T/artifact" | awk '{print $1}')"
rows="$(report_candidate_detail "$T/artifact" "$kb")"; rc=$?
printf 'actual_du_kb=%s caller_rc=%s\n%s\n' "$kb" "$rc" "$rows"
if python3 - "$payload" "$rows" "$rc" <<'PY'
import re, sys
payload, output, rc = sys.argv[1:]
lines = [line for line in output.splitlines() if line.startswith("detail:")]
reached = []
substitutes = []
for line in lines:
    flag = line.split()[0].removeprefix("detail:")
    fields = dict(re.findall(r"(?:^|\s)([a-z_]+)=([^\s]+)", line))
    if flag == "F" and line.endswith(" " + payload):
        reached.append(fields)
    if flag == "T" or (flag == "A" and int(fields.get("bytes", "0")) >= 104857600):
        substitutes.append(line)
assert rc == "0", rc
assert len(reached) == 1 and reached[0].get("bytes") == "209715200", lines
assert not substitutes, substitutes
assert reached[0].get("threshold_mib") == "100", reached
assert reached[0].get("size_method") == "inode-deduplicated-file-summed-apparent", reached
PY
then
  echo 'PASS=1 FAIL=0'
else
  echo 'PASS=0 FAIL=1'
  exit 1
fi
