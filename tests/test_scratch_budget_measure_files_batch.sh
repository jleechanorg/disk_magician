#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/lib/scratch_budget.sh"
: "${TMPDIR:?admitted Scratch TMPDIR required}"
T="$(mktemp -d "$TMPDIR/scratch-measure-batch.XXXXXX")" || exit 2
trap 'rm -rf -- "$T"' EXIT
PASS=0 FAIL=0
ok() { printf 'PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf 'FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }

mkdir "$T/bin" "$T/flat"
REAL_STAT="$(command -v stat)"
REAL_PYTHON="$(command -v python3)"
cat >"$T/bin/stat" <<'SH'
#!/usr/bin/env bash
printf 'call\n' >>"$STAT_INVOKE_TRACE"
exec "$REAL_STAT" "$@"
SH
chmod +x "$T/bin/stat"
cat >"$T/bin/python3" <<'SH'
#!/usr/bin/env bash
printf 'call\n' >>"$PYTHON_INVOKE_TRACE"
exec "$REAL_PYTHON" "$@"
SH
chmod +x "$T/bin/python3"
python3 -c 'from pathlib import Path; import sys; root=Path(sys.argv[1]); data=b"x"*2048; [(root / ("f%04d.bin" % i)).write_bytes(data) for i in range(1000)]' "$T/flat"
STAT_INVOKE_TRACE="$T/stat.calls" REAL_STAT="$REAL_STAT" \
  PYTHON_INVOKE_TRACE="$T/python.calls" REAL_PYTHON="$REAL_PYTHON" \
  PATH="$T/bin:$PATH" scratch_budget_measure_files "$T/flat" 1 >"$T/rows"; rc=$?
summary="$(awk -F '\t' '$4 == "F" { files++; bytes += $1 } $4 == "E" { errors++ } END { printf "%d %0.f %d", files, bytes, errors }' "$T/rows")"
if [[ -f "$T/stat.calls" ]]; then stat_calls="$(wc -l <"$T/stat.calls" | tr -d ' ')"; else stat_calls=0; fi
python_calls="$(wc -l <"$T/python.calls" | tr -d ' ')"
printf 'rows=%s stat_processes=%s python_processes=%s rc=%s\n' "$summary" "$stat_calls" "$python_calls" "$rc"
if [[ "$summary" == "1000 2048000 0" && "$rc" -eq 0 && "$stat_calls" -le 2 && "$python_calls" -le 10 ]]; then
  ok 'flat file rows and apparent bytes are preserved with bounded stat process fanout'
else
  bad 'flat file measurement changed rows or still spawns stat per leaf'
fi

mkdir "$T/inject"
cat >"$T/inject/sitecustomize.py" <<'PY'
import errno
import os
import sys

if sys.argv and sys.argv[0] == "-" and os.environ.get("TEST_MISSING_AFTER_ENUMERATION"):
    target = os.environ["TEST_MISSING_AFTER_ENUMERATION"]
    original_lstat = os.lstat
    def lstat(path, *args, **kwargs):
        if os.fspath(path) == target:
            raise FileNotFoundError(errno.ENOENT, "simulated post-enumeration disappearance", target)
        return original_lstat(path, *args, **kwargs)
    os.lstat = lstat
PY
TEST_MISSING_AFTER_ENUMERATION="$T/flat/f0000.bin" \
  STAT_INVOKE_TRACE="$T/stat.calls" REAL_STAT="$REAL_STAT" \
  PYTHON_INVOKE_TRACE="$T/python.calls" REAL_PYTHON="$REAL_PYTHON" \
  PYTHONPATH="$T/inject" PATH="$T/bin:$PATH" \
  scratch_budget_measure_files "$T/flat" 1 >"$T/missing.rows" 2>"$T/missing.err"; rc=$?
if [[ "$rc" -eq 1 ]] && grep -Fqx "$(printf '0\t0\t0\tE\t%s' "$T/flat/f0000.bin")" "$T/missing.rows"; then
  ok 'a post-enumeration metadata disappearance remains explicitly unmeasured'
else
  bad 'a missing file was counted or lost its error row'
fi

python3 -c 'from pathlib import Path; import sys; p=Path(sys.argv[1]); p.mkdir(); (p/"a\n").write_bytes(b"x"*2097152)' "$T/newline"
scratch_budget_measure_files "$T/newline" 1 >"$T/newline.rows"; rc=$?
if [[ "$rc" -eq 0 ]] && python3 -c 'from pathlib import Path; import os,sys; expected=b"\tF\t"+os.fsencode(Path(sys.argv[1])/"a\n")+b"\n"; assert expected in Path(sys.argv[2]).read_bytes()' "$T/newline" "$T/newline.rows"; then
  ok 'batch flush preserves a trailing newline in a filename'
else
  bad 'batch capture changed filename bytes'
fi

ACT_DEADLINE_AT=0 scratch_budget_measure_files "$T/flat" 1 >"$T/deadline.rows" 2>"$T/deadline.err"; rc=$?
if [[ "$rc" -eq 124 ]] && grep -Fqx "$(printf '0\t0\t0\tE\t%s' "$T/flat")" "$T/deadline.rows" \
   && ! grep -q $'\tF\t' "$T/deadline.rows"; then
  ok 'pre-expired batch deadline emits one explicit unknown root row'
else
  bad 'expired batch deadline was hidden or reported complete file rows'
fi
printf 'PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
