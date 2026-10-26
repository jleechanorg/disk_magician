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
# Usage: evict_fileprovider.sh [--root DIR] [--min-age-hours N] [--limit N] [--prune-unuploaded-local-duplicates] [--dry-run|--clean]
# Default root: ~/Library/CloudStorage/Dropbox/conversation-backups
# Test hooks: DM_FILEPROVIDER_HELPER (probe/evict executable), DM_FILEPROVIDER_ALLOW_ANY_ROOT=1,
#             DM_FILEPROVIDER_LOCAL_CODEX_DIRS, DM_FILEPROVIDER_LOCAL_CLAUDE_DIR.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/safety_lib.sh
source "$SCRIPT_DIR/safety_lib.sh"

ROOT="$HOME/Library/CloudStorage/Dropbox/conversation-backups"
MIN_AGE_HOURS=24
LIMIT=0
CLEAN=false
PRUNE_UNUPLOADED_DUPS=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --root) ROOT="${2:?--root needs a directory}"; shift 2 ;;
    --min-age-hours) MIN_AGE_HOURS="${2:?}"; shift 2 ;;
    --limit) LIMIT="${2:?}"; shift 2 ;;
    --prune-unuploaded-local-duplicates) PRUNE_UNUPLOADED_DUPS=true; shift ;;
    --clean) CLEAN=true; shift ;;
    --dry-run) CLEAN=false; shift ;;
    -h|--help) sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
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

# Enumerate regular files; classify by measured allocated blocks and mtime in awk
# to avoid slow per-file bash read loops over 350k+ dataless placeholders.
: >"$WORK/cand.txt"; : >"$WORK/recent.txt"
read -r n_total n_dataless < <(
  find "$ROOT" -type f -exec stat "${STAT_ARGS[@]}" {} + | awk -F'\t' \
    -v cutoff="$CUTOFF" -v recent="$WORK/recent.txt" -v cand="$WORK/cand.txt" '
    $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ && $4 != "" {
      total++
      if ($1 + 0 == 0) { dataless++; next }
      if ($2 + 0 > cutoff) { print $1 "\t" $3 "\t" $4 > recent; next }
      print $1 "\t" $3 "\t" $4 > cand
    }
    END { printf "%d %d\n", total+0, dataless+0 }'
)

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

: >"$WORK/dups_verified.txt"
n_pruned=0; n_prune_failed=0
if [[ "$PRUNE_UNUPLOADED_DUPS" == true && -s "$WORK/notready.txt" ]]; then
  CODEX_DIRS="${DM_FILEPROVIDER_LOCAL_CODEX_DIRS:-$HOME/.codex/sessions:$HOME/.codex/sessions_archive}"
  CLAUDE_DIR="${DM_FILEPROVIDER_LOCAL_CLAUDE_DIR:-$HOME/.claude/projects}"
  python3 - "$WORK/notready.txt" "$ROOT" "$CODEX_DIRS" "$CLAUDE_DIR" >"$WORK/dups_verified.txt" <<'PY'
import os, stat, sys

notready_file, root, codex_dirs_raw, claude_dir = sys.argv[1:5]
codex_dirs = [d for d in codex_dirs_raw.split(":") if d]
ELIGIBLE = {"SKIP:uploading", "SKIP:upload_error", "SKIP:not_uploaded"}
CODEX_MARKERS = ("/conversation-backups/codex_conversations/sessions/", "/codex_conversations/sessions/")
CLAUDE_MARKERS = ("/conversation-backups/claude_conversations/projects/", "/claude_conversations/projects/")


def find_primary(dbx_path):
    for m in CODEX_MARKERS:
        if m in dbx_path:
            rel = dbx_path.split(m, 1)[1]
            for d in codex_dirs:
                cand = os.path.join(d, rel)
                if os.path.lexists(cand):
                    return cand
    for m in CLAUDE_MARKERS:
        if m in dbx_path:
            rel = dbx_path.split(m, 1)[1]
            if claude_dir:
                cand = os.path.join(claude_dir, rel)
                if os.path.lexists(cand):
                    return cand
    return None


def prefix_matches(primary, dbx_path, size):
    rem = size
    try:
        with open(primary, "rb") as fp, open(dbx_path, "rb") as fd:
            while rem > 0:
                chunk = min(rem, 1048576)
                bp = fp.read(chunk)
                bd = fd.read(chunk)
                if len(bd) != chunk or bp != bd:
                    return False
                rem -= chunk
        return True
    except OSError:
        return False


with open(notready_file, encoding="utf-8", errors="replace") as f:
    for line in f:
        parts = line.rstrip("\n").split("\t", 3)
        if len(parts) != 4:
            continue
        reason, blocks_s, size_s, dbx_path = parts
        if reason not in ELIGIBLE:
            continue
        primary = find_primary(dbx_path)
        if not primary:
            continue
        try:
            st_p = os.lstat(primary)
            st_d = os.lstat(dbx_path)
        except OSError:
            continue
        if not (stat.S_ISREG(st_p.st_mode) and stat.S_ISREG(st_d.st_mode)):
            continue
        if (st_p.st_dev, st_p.st_ino) == (st_d.st_dev, st_d.st_ino):
            continue
        if st_p.st_blocks <= 0 or st_d.st_blocks <= 0 or st_d.st_size <= 0:
            continue
        if st_p.st_size < st_d.st_size:
            continue
        if not prefix_matches(primary, dbx_path, st_d.st_size):
            continue
        print(f"{st_d.st_blocks}\t{st_d.st_size}\t{dbx_path}\t{primary}")
PY
  if [[ "$CLEAN" == true && -s "$WORK/dups_verified.txt" ]]; then
    while IFS=$'\t' read -r before_blocks before_size path primary; do
      if [[ -f "$primary" && ! -L "$primary" && -f "$path" && ! -L "$path" && ! "$primary" -ef "$path" ]]; then
        rm -f -- "$path"
        if [[ ! -e "$path" && -f "$primary" ]]; then
          deletion_log "$(basename "$0")" "prune_unuploaded_duplicate" "$((before_blocks / 2))" "$path"
          n_pruned=$((n_pruned + 1))
        else
          n_prune_failed=$((n_prune_failed + 1))
        fi
      else
        n_prune_failed=$((n_prune_failed + 1))
      fi
    done <"$WORK/dups_verified.txt"
  fi
fi

mode="DRY-RUN"; [[ "$CLEAN" == true ]] && mode="CLEAN"
echo "[$mode] root: $ROOT (min age ${MIN_AGE_HOURS}h)"
echo "files scanned: $n_total (already dataless: $n_dataless)"
echo "would evict (uploaded, aged, closed): $(count "$WORK/ready.txt") files, $(sum_gib 1 "$WORK/ready.txt") GiB physical"
echo "skipped recent (<${MIN_AGE_HOURS}h): $(count "$WORK/recent.txt") files, $(sum_gib 1 "$WORK/recent.txt") GiB physical"
echo "skipped open by a process: $(count "$WORK/openskip.txt") files, $(sum_gib 1 "$WORK/openskip.txt") GiB physical"
echo "skipped provider-not-ready: $(count "$WORK/notready.txt") files, $(sum_gib 2 "$WORK/notready.txt") GiB physical"
cut -f1 "$WORK/notready.txt" | sort | uniq -c | sed 's/^ */  reason /' | awk '{print}'
if [[ "$PRUNE_UNUPLOADED_DUPS" == true ]]; then
  echo "would prune unuploaded duplicate (verified in local primary): $(count "$WORK/dups_verified.txt") files, $(sum_gib 1 "$WORK/dups_verified.txt") GiB physical"
fi
if [[ "$CLEAN" == true ]]; then
  echo "evicted+verified (blocks=0, size unchanged): $n_evicted; failed/unverified: $n_failed"
  if [[ "$PRUNE_UNUPLOADED_DUPS" == true ]]; then
    echo "pruned+verified unuploaded duplicates (local primary intact): $n_pruned; failed/unverified: $n_prune_failed"
  fi
fi
