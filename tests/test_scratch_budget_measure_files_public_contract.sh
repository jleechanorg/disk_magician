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

# Log every path actually visited by find, including nodes its original
# predicates would not print. Prepending an always-true action keeps the
# original predicates and -prune behavior; it does not walk a second tree.
mkdir -p "$T/bin"
REAL_FIND="$(command -v find)"
REAL_STAT="$(command -v stat)"
export REAL_FIND REAL_STAT
cat >"$T/bin/find" <<'SH'
#!/usr/bin/env bash
root="$1"
shift
exec "$REAL_FIND" "$root" -exec sh -c 'printf "%s\n" "$2" >> "$1"' _ "$PR322_FIND_TRACE.$$" {} \; -a "$@"
SH
cat >"$T/bin/stat" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" >>"$PR322_STAT_TRACE"
exec "$REAL_STAT" "$@"
SH
chmod +x "$T/bin/find" "$T/bin/stat"
for location in root nested; do
  for marker in directory file; do
    case_root="$T/$location-$marker"
    mkdir -p "$case_root"
    if [[ "$location" == root ]]; then
      protected="$case_root"
    else
      protected="$case_root/repository"
      mkdir -p "$protected"
      truncate -s 150M "$case_root/ordinary"
    fi
    if [[ "$marker" == directory ]]; then
      mkdir "$protected/.git"
    else
      printf 'gitdir: /unresolved-test-only\n' >"$protected/.git"
    fi
    mkdir "$protected/protected-content"
    truncate -s 200M "$protected/protected-content/sentinel"
    PR322_FIND_TRACE="$T/$location-$marker.find"
    PR322_STAT_TRACE="$T/$location-$marker.stat"
    export PR322_FIND_TRACE PR322_STAT_TRACE
    : >"$PR322_FIND_TRACE"
    : >"$PR322_STAT_TRACE"
    rows="$(PATH="$T/bin:$PATH" scratch_budget_measure_files "$case_root" 100 6)"; rc=$?
    printf 'git_case=%s-%s rc=%s\n%s\n' "$location" "$marker" "$rc" "$rows"
    if python3 - "$protected" "$location" "$case_root" "$PR322_FIND_TRACE" "$PR322_STAT_TRACE" "$rows" "$rc" <<'PY'
import pathlib, sys
protected, location, root, find_log, stat_log, output, rc = sys.argv[1:]
violations = []
logs = list(pathlib.Path(find_log).parent.glob(pathlib.Path(find_log).name + ".*"))
logs.append(pathlib.Path(stat_log))
for log in logs:
    for path in log.read_text().splitlines():
        if path.startswith(protected + "/") and path != protected + "/.git":
            violations.append(path)
rows = [line.split("\t", 4) for line in output.splitlines()]
opaque = [r for r in rows if len(r) == 5 and r[4] == protected
          and r[3].lower() in ("g", "o", "git", "opaque")]
exposed = [r[4] for r in rows if len(r) == 5
           and r[4].startswith(protected + "/")]
ordinary = location == "root" or any(
    len(r) == 5 and r[4] == root + "/ordinary"
    and r[3] == "F" and r[0] == str(150 * 1024 * 1024) for r in rows)
if rc != "0" or violations or exposed or not opaque or not ordinary:
    print("boundary_failure", dict(rc=rc, traversed=violations,
          exposed=exposed, opaque=opaque, ordinary_measured=ordinary))
    raise SystemExit(1)
PY
    then
      ok "$location Git $marker is opaque before subtree scan"
    else
      bad "$location Git $marker traversed, hidden, or swallowed sibling"
    fi
  done
done
printf 'PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
