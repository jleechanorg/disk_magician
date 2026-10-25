#!/usr/bin/env bash
# evict_fileprovider.sh — evict materialized cloud-storage (FileProvider) files back to
# cloud-only/dataless so their local blocks are freed (bead disk_magician-bfn6).
#
# Never deletes content: eviction keeps the file in the cloud and in the namespace; it
# re-materializes on access, so the reclaim is not permanent. A file is evicted only when
# the provider itself reports it uploaded, not uploading and error-free (helper "probe"),
# it is older than --min-age-hours, and no process has it open. Anything unmeasurable is
# skipped (fail closed). Dry-run by default; a real run needs --clean AND
# FILEPROVIDER_EVICT_APPROVED=1. Each verified eviction is written to the deletion log.
#
# Usage: evict_fileprovider.sh [--root DIR] [--min-age-hours N] [--limit N] [--dry-run|--clean]
# Default root: ~/Library/CloudStorage/Dropbox/conversation-backups
# Test hooks: DM_FILEPROVIDER_HELPER (probe/evict executable), DM_FILEPROVIDER_ALLOW_ANY_ROOT=1.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/safety_lib.sh
source "$SCRIPT_DIR/safety_lib.sh"

ROOT="$HOME/Library/CloudStorage/Dropbox/conversation-backups"
MIN_AGE_HOURS=24
LIMIT=0
CLEAN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --root) ROOT="${2:?--root needs a directory}"; shift 2 ;;
    --min-age-hours) MIN_AGE_HOURS="${2:?}"; shift 2 ;;
    --limit) LIMIT="${2:?}"; shift 2 ;;
    --clean) CLEAN=true; shift ;;
    --dry-run) CLEAN=false; shift ;;
    -h|--help) sed -n '2,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done
[[ "$MIN_AGE_HOURS" =~ ^[0-9]+$ && "$LIMIT" =~ ^[0-9]+$ ]] || { echo "ERROR: --min-age-hours/--limit must be integers" >&2; exit 2; }

if [[ "$CLEAN" == true && "${FILEPROVIDER_EVICT_APPROVED:-}" != "1" ]]; then
  echo "ERROR: --clean requires FILEPROVIDER_EVICT_APPROVED=1 (approval gate). Nothing evicted." >&2
  exit 2
fi

[[ -d "$ROOT" && ! -L "$ROOT" ]] || { echo "ERROR: root '$ROOT' is not a real directory" >&2; exit 2; }
ROOT="$(cd "$ROOT" && pwd -P)"
if [[ "${DM_FILEPROVIDER_ALLOW_ANY_ROOT:-0}" != "1" ]]; then
  case "$ROOT" in
    "$HOME"/Library/CloudStorage/?*/*) ;;
    *) echo "ERROR: root must be inside ~/Library/CloudStorage/<provider>/ (got $ROOT)" >&2; exit 2 ;;
  esac
fi

HELPER="${DM_FILEPROVIDER_HELPER:-}"
if [[ -z "$HELPER" ]]; then
  src="$SCRIPT_DIR/fileprovider_evict.swift"
  command -v swiftc >/dev/null 2>&1 || { echo "ERROR: swiftc not found; cannot build FileProvider helper" >&2; exit 2; }
  sum="$(shasum -a 256 "$src" | cut -c1-12)"
  bindir="${DISK_MAGICIAN_STATE_DIR:-$HOME/.disk_magician_state}/bin"
  HELPER="$bindir/fileprovider_evict-$sum"
  if [[ ! -x "$HELPER" ]]; then
    mkdir -p "$bindir"
    swiftc -O "$src" -o "$HELPER" || { echo "ERROR: helper build failed" >&2; exit 2; }
  fi
fi
[[ -x "$HELPER" ]] || { echo "ERROR: helper '$HELPER' not executable" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/evict-fp.XXXXXX")"
trap 'rm -rf -- "${WORK:?}"' EXIT

# stat -f is BSD; GNU stat (Linux CI) uses -c. Fields: blocks mtime size path.
if stat --version >/dev/null 2>&1; then STAT_ARGS=(-c $'%b\t%Y\t%s\t%n'); STAT_BS=(-c '%b %s')
else STAT_ARGS=(-f $'%b\t%m\t%z\t%N'); STAT_BS=(-f '%b %z'); fi

NOW="$(date +%s)"
CUTOFF=$((NOW - MIN_AGE_HOURS * 3600))

# Files open by any process (one system-wide lsof, filtered to the root).
lsof -w -n -F n 2>/dev/null | sed -n 's/^n//p' | grep -F -- "$ROOT/" >"$WORK/open.txt" || true

# Enumerate regular files; classify by measured allocated blocks and mtime.
: >"$WORK/cand.txt"; : >"$WORK/recent.txt"
n_total=0; n_dataless=0
while IFS=$'\t' read -r blocks mtime size path; do
  [[ "$blocks" =~ ^[0-9]+$ && "$mtime" =~ ^[0-9]+$ && -n "$path" ]] || continue
  n_total=$((n_total + 1))
  if ((blocks == 0)); then n_dataless=$((n_dataless + 1)); continue; fi
  if ((mtime > CUTOFF)); then printf '%s\t%s\t%s\n' "$blocks" "$size" "$path" >>"$WORK/recent.txt"; continue; fi
  printf '%s\t%s\t%s\n' "$blocks" "$size" "$path" >>"$WORK/cand.txt"
done < <(find "$ROOT" -type f -exec stat "${STAT_ARGS[@]}" {} +)

# Open files are skipped.
if [[ -s "$WORK/open.txt" ]]; then
  awk -F'\t' 'NR==FNR{o[$0]=1; next} ($3 in o){print > "'"$WORK"'/openskip.txt"; next} {print > "'"$WORK"'/cand2.txt"}' \
    "$WORK/open.txt" "$WORK/cand.txt"
  [[ -f "$WORK/cand2.txt" ]] && mv "$WORK/cand2.txt" "$WORK/cand.txt" || : >"$WORK/cand.txt"
fi
[[ -f "$WORK/openskip.txt" ]] || : >"$WORK/openskip.txt"
if ((LIMIT > 0)); then head -n "$LIMIT" "$WORK/cand.txt" >"$WORK/cand.lim" && mv "$WORK/cand.lim" "$WORK/cand.txt"; fi

# Provider upload-state probe (fail closed: anything but READY is skipped).
cut -f3- "$WORK/cand.txt" | tr '\n' '\0' | "$HELPER" probe >"$WORK/probe.txt" || true
awk -F'\t' 'NR==FNR{if($1=="READY")r[$2]=1; else why[$2]=$1; next}
  { if ($3 in r) print > "'"$WORK"'/ready.txt"; else print (($3 in why)?why[$3]:"SKIP:no_probe_result") "\t" $0 > "'"$WORK"'/notready.txt" }' \
  "$WORK/probe.txt" "$WORK/cand.txt"
for f in ready notready; do [[ -f "$WORK/$f.txt" ]] || : >"$WORK/$f.txt"; done

sum_gib() { awk -F'\t' -v c="$1" '{s+=$c} END{printf "%.3f", s*512/1073741824}' "$2"; }
count() { wc -l <"$1" | tr -d ' '; }

n_evicted=0; n_failed=0
if [[ "$CLEAN" == true ]]; then
  cut -f3- "$WORK/ready.txt" | tr '\n' '\0' | "$HELPER" evict >"$WORK/evict.txt" || true
  while IFS=$'\t' read -r st path; do
    if [[ "$st" != "EVICTED" ]]; then n_failed=$((n_failed + 1)); continue; fi
    # Verify: allocated blocks are now 0 and the logical size is unchanged.
    row="$(grep -F -- $'\t'"$path" "$WORK/ready.txt" | head -n1 || true)"
    before_blocks="${row%%$'\t'*}"; rest="${row#*$'\t'}"; before_size="${rest%%$'\t'*}"
    read -r after_blocks after_size < <(stat "${STAT_BS[@]}" "$path" 2>/dev/null || echo "x x")
    if [[ "$after_blocks" == 0 && "$after_size" == "$before_size" ]]; then
      deletion_log "$(basename "$0")" "evict_fileprovider" "$((before_blocks / 2))" "$path"
      n_evicted=$((n_evicted + 1))
    else
      n_failed=$((n_failed + 1))
    fi
  done <"$WORK/evict.txt"
fi

mode="DRY-RUN"; [[ "$CLEAN" == true ]] && mode="CLEAN"
echo "[$mode] root: $ROOT (min age ${MIN_AGE_HOURS}h)"
echo "files scanned: $n_total (already dataless: $n_dataless)"
echo "would evict (uploaded, aged, closed): $(count "$WORK/ready.txt") files, $(sum_gib 1 "$WORK/ready.txt") GiB physical"
echo "skipped recent (<${MIN_AGE_HOURS}h): $(count "$WORK/recent.txt") files, $(sum_gib 1 "$WORK/recent.txt") GiB physical"
echo "skipped open by a process: $(count "$WORK/openskip.txt") files, $(sum_gib 1 "$WORK/openskip.txt") GiB physical"
echo "skipped provider-not-ready: $(count "$WORK/notready.txt") files, $(sum_gib 2 "$WORK/notready.txt") GiB physical"
cut -f1 "$WORK/notready.txt" | sort | uniq -c | sed 's/^ */  reason /' | awk '{print}'
if [[ "$CLEAN" == true ]]; then
  echo "evicted+verified (blocks=0, size unchanged): $n_evicted; failed/unverified: $n_failed"
fi
