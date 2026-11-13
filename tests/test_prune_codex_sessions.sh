#!/usr/bin/env bash
# Tests for scripts/prune_codex_sessions.sh — age/recency/open-file/safety gates.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/prune_codex_sessions.sh"
: "${TMPDIR:?admitted Scratch TMPDIR required}"
T="$(mktemp -d "$TMPDIR/prune-codex-sessions.XXXXXX")" || exit 2
trap 'rm -rf -- "$T"' EXIT

pass=0 fail=0
check() { if [[ "$2" == 1 ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1" >&2; fi; }
run() {  # run <codex_home>
  CODEX_HOME="$1" DISK_MAGICIAN_DELETION_LOG="$T/deletions.log" \
    timeout 120 bash "$SCRIPT" "${@:2}" >"$T/out.txt" 2>"$T/err.txt"
  echo $?
}

old_epoch() { echo $(( $(date +%s) - 86400 * $1 )); }

# case 1: dry-run is the default and removes nothing
H="$T/c1"; mkdir -p "$H/sessions/2026/01/01"
f="$H/sessions/2026/01/01/old.jsonl"; printf 'x\n' >"$f"; touch -t 202601010000 "$f"
rc=$(run "$H" --keep-recent 0); check "dry-run exit 0 (got $rc)" "$([[ $rc == 0 ]] && echo 1 || echo 0)"
check "dry-run keeps file" "$([[ -f $f ]] && echo 1 || echo 0)"
check "dry-run reports would-remove" "$(grep -q 'would-remove=1' "$T/out.txt" && echo 1 || echo 0)"

# case 2: --clean removes the old file and logs it
rc=$(run "$H" --clean --keep-recent 0)
check "--clean exit 0 (got $rc)" "$([[ $rc == 0 ]] && echo 1 || echo 0)"
check "--clean removes old file" "$([[ ! -f $f ]] && echo 1 || echo 0)"
check "--clean logs to deletion log" "$(grep -q 'old.jsonl' "$T/deletions.log" 2>/dev/null && echo 1 || echo 0)"
check "summary reports removed=1" "$(grep -q 'removed=1' "$T/out.txt" && echo 1 || echo 0)"

# case 3: recent file kept at any keep-recent value
H="$T/c3"; mkdir -p "$H/sessions"
recent="$H/sessions/recent.jsonl"; printf 'y\n' >"$recent"
rc=$(run "$H" --clean --keep-recent 0)
check "recent file kept (rc=$rc)" "$([[ -f $recent ]] && echo 1 || echo 0)"

# case 4: keep-recent protects the newest old files
H="$T/c4"; mkdir -p "$H/sessions"
for i in 1 2 3; do
  p="$H/sessions/s$i.jsonl"; printf 'z\n' >"$p"; touch -t 202601010000 "$p"
  touch -t "20260101000$i" "$p"
done
rc=$(run "$H" --clean --keep-recent 1)
check "keep-recent=1 leaves exactly 1 file" "$([[ $(find "$H/sessions" -type f | wc -l) -eq 1 ]] && echo 1 || echo 0)"
check "keep-recent keeps the newest (s3)" "$([[ -f $H/sessions/s3.jsonl ]] && echo 1 || echo 0)"

# case 5: symlink is never a candidate (and its target survives)
H="$T/c5"; mkdir -p "$H/sessions" "$T/c5-outside"
printf 'k\n' >"$T/c5-outside/real.jsonl"; touch -t 202601010000 "$T/c5-outside/real.jsonl"
ln -s "$T/c5-outside/real.jsonl" "$H/sessions/link.jsonl"
rc=$(run "$H" --clean --keep-recent 0)
check "symlink target survives" "$([[ -f $T/c5-outside/real.jsonl ]] && echo 1 || echo 0)"
check "symlink kept" "$([[ -L $H/sessions/link.jsonl ]] && echo 1 || echo 0)"

# case 6: floor is respected — a 10-day-old file survives a 30-day floor
H="$T/c6"; mkdir -p "$H/sessions"
mid="$H/sessions/mid.jsonl"; printf 'm\n' >"$mid"; touch -d "@$(old_epoch 10)" "$mid" 2>/dev/null || touch -t 202611010000 "$mid"
rc=$(run "$H" --clean --keep-recent 0 --older-than-days 30)
check "10d file survives 30d floor" "$([[ -f $mid ]] && echo 1 || echo 0)"

# case 7: sessions_archive only with --include-archive
H="$T/c7"; mkdir -p "$H/sessions" "$H/sessions_archive"
arch="$H/sessions_archive/a.jsonl"; printf 'a\n' >"$arch"; touch -t 202601010000 "$arch"
rc=$(run "$H" --clean --keep-recent 0)
check "archive untouched without flag" "$([[ -f $arch ]] && echo 1 || echo 0)"
rc=$(run "$H" --clean --keep-recent 0 --include-archive)
check "archive pruned with flag" "$([[ ! -f $arch ]] && echo 1 || echo 0)"

# case 8: non-session files inside the store are never candidates
H="$T/c8"; mkdir -p "$H/sessions"
state="$H/sessions/state.sqlite"; printf 's\n' >"$state"; touch -t 202601010000 "$state"
rc=$(run "$H" --clean --keep-recent 0)
check "non-jsonl file kept" "$([[ -f $state ]] && echo 1 || echo 0)"

# case 9: --max-gib caps the pass
H="$T/c9"; mkdir -p "$H/sessions"
for i in 1 2 3 4; do p="$H/sessions/b$i.jsonl"; head -c 4096 /dev/zero >"$p"; touch -t 202601010000 "$p"; done
rc=$(run "$H" --clean --keep-recent 0 --max-gib 1)
check "max-gib with small files still exits 0 (got $rc)" "$([[ $rc == 0 ]] && echo 1 || echo 0)"


# case 10: a file held open by a live process is kept
H="$T/c10"; mkdir -p "$H/sessions"
held="$H/sessions/held.jsonl"; printf 'h\n' >"$held"; touch -t 202601010000 "$held"
bash -c 'exec -a codex sleep 12' 9<"$held" &
holder=$!
sleep 1
rc=$(run "$H" --clean --keep-recent 0)
wait "$holder" 2>/dev/null
check "open file kept" "$([[ -f $held ]] && echo 1 || echo 0)"
check "open file counted as kept_open" "$(grep -q 'kept_open=1' "$T/out.txt" && echo 1 || echo 0)"

echo "prune_codex_sessions tests: pass=$pass fail=$fail"
[[ "$fail" -eq 0 ]]
