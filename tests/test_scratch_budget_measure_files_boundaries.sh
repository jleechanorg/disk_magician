#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/lib/scratch_budget.sh"
report_definition="$(sed -n '/^report_candidate_detail() {$/,/^}$/p' "$ROOT/scripts/cleanup_scratch_top_level.sh")"
[[ -n "$report_definition" ]] || { echo 'Cannot locate actual cleanup reporting function' >&2; exit 2; }
eval "$report_definition"
DETAIL_MIB=100
DETAIL_DEPTH=6
[[ -n "${TMPDIR:-}" && -d "$TMPDIR" ]] || { echo 'An existing admitted TMPDIR is required' >&2; exit 2; }
T="$(mktemp -d "$TMPDIR/pr322-boundaries.XXXXXX")" || exit 2
trap 'rm -rf -- "$T"' EXIT
PASS=0
FAIL=0
ok() { printf 'PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf 'FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }

mkdir -p "$T/small" "$T/outside"
printf 'payload' >"$T/small/plain"
truncate -s 200M "$T/outside/payload"
ln -s ../outside/payload "$T/small/link"
expected="$(python3 - "$T/small" <<'PY'
import os, sys
p = sys.argv[1]
print(sum(os.lstat(os.path.join(p, n)).st_size for n in ('plain', 'link')))
PY
)"
rows="$(scratch_budget_measure_files "$T/small" 100)"; rc=$?
actual="$(awk -F '\t' -v p="$T/small" '$4 == "A" && $5 == p {print $1}' <<<"$rows")"
printf 'symlink rc=%s expected_bytes=%s actual_bytes=%s\n%s\n' "$rc" "$expected" "$actual" "$rows"
if [[ "$rc" -eq 0 && "$actual" == "$expected" ]]; then
  ok 'below-threshold aggregate includes link bytes without target bytes'
else
  bad 'below-threshold aggregate omits or follows the symlink'
fi

mkdir -p "$T/bin" "$T/slow/child"
truncate -s 200M "$T/slow/child/payload"
REAL_FIND="$(command -v find)"
export REAL_FIND
cat >"$T/bin/find" <<'SH'
#!/usr/bin/env bash
sleep 1
exec "$REAL_FIND" "$@"
SH
chmod +x "$T/bin/find"
start="$(act_mono_now)"
ACT_DEADLINE_AT="$(python3 -c 'import time; print(time.monotonic() + 0.25)')"
export ACT_DEADLINE_AT
rows="$(PATH="$T/bin:$PATH" report_candidate_detail "$T/slow" 204800 2>"$T/deadline.stderr")"; rc=$?
end="$(act_mono_now)"
elapsed="$(python3 -c 'import sys; print(float(sys.argv[2])-float(sys.argv[1]))' "$start" "$end")"
unset ACT_DEADLINE_AT
printf 'caller_deadline rc=%s elapsed_seconds=%s\n%s\n' "$rc" "$elapsed" "$rows"
cat "$T/deadline.stderr"
if python3 -c 'import sys; sys.exit(0 if float(sys.argv[1]) < 0.9 else 1)' "$elapsed" && ! grep -Eq '^detail:[AFT] ' <<<"$rows"; then
  ok 'cleanup detail boundary interrupts within deadline without complete rows'
else
  bad 'cleanup detail boundary exceeds deadline or reports complete traversal'
fi
printf 'PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
