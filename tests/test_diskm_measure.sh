#!/usr/bin/env bash
# scratch_budget_measure_files lives in scripts/diskm_measure.py; the bash
# wrapper must stay byte-identical to the pre-move heredoc on origin/main.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
: "${TMPDIR:?admitted Scratch TMPDIR required}"
T="$(mktemp -d "$TMPDIR/diskm-measure.XXXXXX")" || exit 2
trap 'chmod -R u+rwX "$T" 2>/dev/null; rm -rf -- "$T"' EXIT
PASS=0 FAIL=0
ok() { printf 'PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf 'FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }

[[ -f "$ROOT/scripts/diskm_measure.py" ]] || { bad 'scripts/diskm_measure.py is missing'; printf '%s passed, %s failed\n' "$PASS" "$FAIL"; exit 1; }

# Old function from the pre-change base, loaded from a copy of scripts/ so its relative sources resolve.
mkdir "$T/old"
cp -R "$ROOT/scripts" "$T/old/scripts"
git -C "$ROOT" show origin/main:scripts/lib/scratch_budget.sh >"$T/old/scripts/lib/scratch_budget.sh" || { bad 'cannot read origin/main scratch_budget.sh'; exit 1; }
grep -q 'python3 - "\$path"' "$T/old/scripts/lib/scratch_budget.sh" || { bad 'origin/main no longer holds the heredoc; golden base is wrong'; exit 1; }

F="$T/fx"
mkdir -p "$F/sparse" "$F/hl" "$F/repo/.git" "$F/empty" "$F/plain/sub"
ln -s ../plain "$F/link"
printf 'data' >"$F/hl/a"; ln "$F/hl/a" "$F/hl/b"
truncate -s 100M "$F/sparse/big"
printf 'x' >"$F/repo/.git/HEAD"; printf 'y' >"$F/repo/file"
printf 'z' >"$F/plain/sub/f"; ln -s plain "$F/plain/lnk"

old_run() { ( source "$T/old/scripts/lib/scratch_budget.sh"; scratch_budget_measure_files "$@" ); }
new_run() { ( source "$ROOT/scripts/lib/scratch_budget.sh"; scratch_budget_measure_files "$@" ); }

golden_ok=1
for d in link hl sparse repo empty plain; do
  for fmt in tsv --nul; do
    for thr in 1 100; do
      old_run "$F/$d" "$thr" "$fmt" >"$T/o.out" 2>"$T/o.err"; orc=$?
      new_run "$F/$d" "$thr" "$fmt" >"$T/n.out" 2>"$T/n.err"; nrc=$?
      if [[ "$orc" -ne "$nrc" ]] || ! cmp -s "$T/o.out" "$T/n.out" || ! cmp -s "$T/o.err" "$T/n.err"; then
        golden_ok=0; printf '  golden diff: %s fmt=%s thr=%s rc %s/%s\n' "$d" "$fmt" "$thr" "$orc" "$nrc"
      fi
    done
  done
done
if (( golden_ok )) && [[ -s "$T/n.out" ]]; then ok 'wrapper output and rc match origin/main byte for byte on all fixtures'; else bad 'wrapper output diverges from origin/main'; fi

# (b) rc passthrough
if [[ "$(id -u)" -eq 0 ]]; then
  printf 'SKIP: unreadable-subdir rc 1 (running as root)\n'
else
  mkdir -p "$F/denied/sub"; printf 'q' >"$F/denied/sub/f"; chmod 000 "$F/denied/sub"
  new_run "$F/denied" 100 tsv >"$T/d.out" 2>/dev/null; rc=$?
  old_run "$F/denied" 100 tsv >"$T/d.old" 2>/dev/null; orc=$?
  chmod 700 "$F/denied/sub"
  if [[ "$rc" -eq 1 && "$orc" -eq 1 ]] && cmp -s "$T/d.out" "$T/d.old"; then ok 'unreadable subdir returns rc 1 like origin/main'; else bad "unreadable subdir rc=$rc old=$orc"; fi
fi
new_run "" >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 2 ]]; then ok 'missing path argument returns rc 2'; else bad "missing path rc=$rc"; fi
ACT_DEADLINE_AT=0 new_run "$F/plain" 100 tsv >"$T/t.out" 2>/dev/null; rc=$?
if [[ "$rc" -eq 124 ]] && [[ "$(cat "$T/t.out")" == "$(printf '0\t0\t0\tE\t%s' "$F/plain")" ]]; then ok 'past deadline returns rc 124 with the E row'; else bad "deadline rc=$rc"; fi

# (c) exactly one diskm_measure.py python3 call per wrapper call
mkdir "$T/bin"
REAL_PYTHON="$(command -v python3)"
cat >"$T/bin/python3" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in *diskm_measure.py) printf 'call\n' >>"$MEASURE_TRACE" ;; esac
exec "$REAL_PYTHON" "$@"
SH
chmod +x "$T/bin/python3"
: >"$T/trace"
MEASURE_TRACE="$T/trace" REAL_PYTHON="$REAL_PYTHON" PATH="$T/bin:$PATH" new_run "$F/plain" 100 tsv >/dev/null 2>&1
calls="$(wc -l <"$T/trace" | tr -d ' ')"
if [[ "$calls" -eq 1 ]]; then ok 'one diskm_measure.py call per wrapper call'; else bad "diskm_measure.py calls=$calls"; fi

printf '%s passed, %s failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
