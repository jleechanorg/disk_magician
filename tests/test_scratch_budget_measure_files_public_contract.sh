#!/usr/bin/env bash
# PR322 public reporting contract; caller supplies admitted Scratch TMPDIR.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/lib/scratch_budget.sh"
: "${TMPDIR:?admitted Scratch TMPDIR required}"
T="$(mktemp -d "$TMPDIR/pr322-public.XXXXXX")" || exit 2
trap 'rm -rf -- "$T"' EXIT
PASS=0 FAIL=0
ok() { printf 'PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf 'FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }
definition="$(sed -n '/^report_candidate_detail() {$/,/^}$/p' "$ROOT/scripts/cleanup_scratch_top_level.sh")"
[[ -n "$definition" ]] || { echo "report caller absent" >&2; exit 2; }
eval "$definition"
DETAIL_MIB=100 DETAIL_DEPTH=6

# Use actual allocated-size input, as the cleanup caller does, not fabricated kb.
mkdir -p "$T/sparse"
truncate -s 200M "$T/sparse/payload"
kb="$(du -sk "$T/sparse" | awk '{print $1}')"
printf 'sparse apparent_bytes=209715200 actual_du_kb=%s\n' "$kb"
if ! [[ "$kb" =~ ^[0-9]+$ ]] || (( kb >= 102400 )); then
  echo "Fixture not sparse below100MiB on this filesystem" >&2
  exit 2
fi
rows="$(report_candidate_detail "$T/sparse" "$kb")"; rc=$?
printf 'sparse caller_rc=%s\n%s\n' "$rc" "$rows"
if grep -F "detail:F bytes=209715200 " <<<"$rows" | grep -Fq "$T/sparse/payload"; then
  ok "sparse apparent200MiB is itemised by actual caller"
else
  bad "allocated du threshold hides sparse apparent200MiB detail"
fi

# Git roots are opaque boundaries: each root/nested marker yields one G row;
# descendants receive no fabricated size/age rows and non-Git siblings remain measurable.
for location in root nested; do
  for marker in directory file; do
    case_root="$T/$location-$marker"
    mkdir -p "$case_root"
    if [[ "$location" == root ]]; then protected="$case_root"
    else
      protected="$case_root/repository"
      mkdir -p "$protected"
      truncate -s 150M "$case_root/ordinary"
    fi
    if [[ "$marker" == directory ]]; then mkdir "$protected/.git"
    else printf 'gitdir: /unresolved-test-only\n' >"$protected/.git"; fi
    mkdir "$protected/protected-content"
    truncate -s 200M "$protected/protected-content/sentinel"
    rows="$(scratch_budget_measure_files "$case_root" 100 6)"; rc=$?
    printf 'git_case=%s-%s rc=%s\n%s\n' "$location" "$marker" "$rc" "$rows"
    if python3 - "$protected" "$location" "$case_root" "$rows" "$rc" <<'PY'
import os, sys
protected, location, root, output, rc = sys.argv[1:]
rows = [line.split("\t", 4) for line in output.splitlines()]
git_rows = [r for r in rows if len(r) == 5 and r[3] == "G"]
opaque = (len(git_rows) == 1 and git_rows[0][4] == protected
          and git_rows[0][:3] == ["0", "0", "0"])
children = [r for r in rows if len(r) == 5 and r[4].startswith(protected + "/")]
ordinary = location == "root" or any(
    len(r) == 5 and r[4] == root + "/ordinary" and r[3] == "F"
    and r[0] == str(150 * 1024 * 1024) for r in rows)
assert rc == "0" and opaque and not children and ordinary, (rc, rows)
assert os.path.getsize(protected + "/protected-content/sentinel") == 200 * 1024 * 1024
PY
    then ok "$location Git $marker emits one opaque G row with no child ages/sizes"
    else bad "$location Git $marker boundary or sibling accounting is wrong"
    fi
  done
done
printf 'PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
