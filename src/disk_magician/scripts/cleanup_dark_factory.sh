#!/usr/bin/env bash
# cleanup_dark_factory.sh — Retention for dark-factory artifacts, which have
# no upstream pruning: installed releases, per-run dirs, and df-* AO session
# homes. Defaults to dry-run; pass --clean to delete.
#
# Never deleted: releases referenced by ~/.local/bin symlinks, systemd user
# units/drop-ins, or a live process; the newest --keep-releases releases;
# anything with a file modified inside --days (floor: safety_min_stale_days).
set -euo pipefail
# Paths are byte strings: byte-wise tools avoid "illegal byte sequence"
# aborts (BSD sed/tr) on non-UTF-8 names under a UTF-8 locale.
export LC_ALL=C

# shellcheck source=scripts/safety_lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/safety_lib.sh"

DRY_RUN=true
DAYS=30
KEEP_RELEASES=3
RELEASES_DIR="${HOME}/.local/share/dark-factory/releases"
RUNS_DIR="${HOME}/.dark-factory/runs"
SESSIONS_DIR="${HOME}/.ao-sessions"
BIN_DIR="${HOME}/.local/bin"
UNIT_DIR="${HOME}/.config/systemd/user"

usage() {
  cat <<EOF
Usage: $(basename "$0") [--clean] [--dry-run] [--days N] [--keep-releases N] [-h|--help]

  --clean            Actually delete (default: dry-run preview)
  --days N           Staleness threshold for runs/sessions/releases (default: 30, min 7)
  --keep-releases N  Always keep the N newest releases (default: 3)

On Linux, --clean refuses while any of your processes hides its cwd/env/open
files from you (non-dumpable, e.g. systemd --user); it lists them. Set
DARK_FACTORY_UNSCANNABLE_APPROVED=1 to accept that they use no candidate path.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --clean)   DRY_RUN=false ;;
    --dry-run) DRY_RUN=true ;;
    --days)    shift; DAYS="${1:?--days requires a number}" ;;
    --keep-releases) shift; KEEP_RELEASES="${1:?--keep-releases requires a number}" ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

# At most 6 digits, so bash's 64-bit arithmetic cannot overflow.
[[ "$DAYS" =~ ^[0-9]{1,6}$ && "$KEEP_RELEASES" =~ ^[0-9]{1,6}$ ]] || { echo "--days and --keep-releases must be integers 0..999999" >&2; exit 2; }
DAYS=$((10#$DAYS)); KEEP_RELEASES=$((10#$KEEP_RELEASES))  # leading zeros are not octal

floor="$(safety_min_stale_days)"
(( DAYS < floor )) && DAYS="$floor"
sandbox_guard_roots "$RELEASES_DIR" "$RUNS_DIR" "$SESSIONS_DIR"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# A scan that cannot see everything must not authorize deletion: --clean
# aborts; a dry-run only warns.
scan_fail() {
  if [[ "$DRY_RUN" == false ]]; then
    echo "Incomplete reference scan ($1) — refusing --clean." >&2
    exit 1
  fi
  log "WARN: incomplete reference scan ($1)"
}

# Physical path of a root (ancestor symlinks resolved), so it compares equal
# to the resolved paths that /proc, lsof, and realpath report.
phys() { (cd -P "$1" 2>/dev/null && pwd) || printf '%s\n' "$1"; }

# Escape a literal path for use inside an ERE.
re_escape() { printf '%s' "$1" | sed 's/[][\.*^$+?(){}|]/\\&/g'; }

# Resolve each stdin path through every symlink (relative or chained).
realpaths() { python3 -c 'import os,sys
for l in sys.stdin.buffer:  # bytes: paths need not be valid UTF-8
    l = l.rstrip(b"\n")
    if l: sys.stdout.buffer.write(os.path.realpath(l) + b"\n")'; }
# Same, for NUL-delimited input (names may contain newlines).
realpaths0() { python3 -c 'import os,sys
for l in sys.stdin.buffer.read().split(b"\0"):
    if l: sys.stdout.buffer.write(os.path.realpath(l) + b"\n")'; }

# A symlinked root would let rm act on its target outside the gated path.
root_ok() {
  if [[ -L "$1" ]]; then log "SKIP root (symlink): $1"; return 1; fi
  [[ -d "$1" ]]
}

# Every path a live process is using: exe, cwd, argv, environment, open files.
LIVE_REFS="$(mktemp)"
UNSCANNABLE=""
REFTEXT=""
trap 'rm -f "$LIVE_REFS" "$UNSCANNABLE" "$REFTEXT"' EXIT
# DISK_MAGICIAN_TEST_NO_PROC forces the ps/lsof branch (test-only override).
if [[ -d /proc/self && -z "${DISK_MAGICIAN_TEST_NO_PROC:-}" ]]; then
  UNSCANNABLE="$(mktemp)"
  for p in /proc/[0-9]*; do
    if [[ -O "$p" ]]; then
      # argv of our own processes must be read; a failure while the process
      # still exists (and is not a zombie) means the reference set is incomplete.
      if ! tr '\0' '\n' <"$p/cmdline" 2>/dev/null; then
        if [[ -d "$p" ]] && ! grep -qE '^State:[[:space:]]*Z' "$p/status" 2>/dev/null; then
          scan_fail "cannot read argv of own process $p"
        fi
        continue
      fi
      # The kernel denies cwd/environ/fds of non-dumpable processes even to
      # their own uid (systemd --user, ssh-agent). Their usage is unknowable,
      # so they gate --clean below unless explicitly approved.
      if ! { readlink "$p/exe" && readlink "$p/cwd" && tr '\0' '\n' <"$p/environ" \
             && find "$p/fd" -maxdepth 1 -type l -printf '%l\n'; } 2>/dev/null; then
        if [[ -d "$p" ]] && ! grep -qE '^State:[[:space:]]*Z' "$p/status" 2>/dev/null; then
          printf '%s %s\n' "${p#/proc/}" "$(tr '\0' ' ' <"$p/cmdline" 2>/dev/null)" >>"$UNSCANNABLE"
        fi
      fi
    else
      { readlink "$p/exe"; readlink "$p/cwd"; tr '\0' '\n' <"$p/cmdline"; } 2>/dev/null || true
    fi
  done >"$LIVE_REFS"
  if [[ -s "$UNSCANNABLE" ]]; then
    if [[ "$DRY_RUN" == false && "${DARK_FACTORY_UNSCANNABLE_APPROVED:-}" != 1 ]]; then
      echo "Own processes whose cwd/env/open files the kernel hides (pid argv):" >&2
      sed 's/^/  /' "$UNSCANNABLE" >&2
      echo "They could be using a candidate path. Refusing --clean; set DARK_FACTORY_UNSCANNABLE_APPROVED=1 to accept." >&2
      exit 1
    fi
    log "Note: $(wc -l <"$UNSCANNABLE" | tr -d ' ') own unscannable (non-dumpable) process(es); argv scanned only"
  fi
else
  # macOS: argv and environment from ps; cwd, exe, and open files from lsof.
  # Any nonzero exit means a partial scan.
  ps -axwwE -o command= >"$LIVE_REFS" 2>/dev/null || scan_fail "ps failed"
  lsof_raw="$(lsof -nP -w -u "$(id -u)" -Fn 2>/dev/null)" || scan_fail "lsof incomplete"
  lsof_out="$(sed -n 's/^n//p' <<<"${lsof_raw:-}")"
  [[ -n "$lsof_out" ]] || scan_fail "lsof returned nothing"
  printf '%s\n' "$lsof_out" >>"$LIVE_REFS"
fi
# The scan must see this process's own argv and cwd, or it is not seeing processes.
if ! LC_ALL=C grep -aqF "cleanup_dark_factory" "$LIVE_REFS" || ! LC_ALL=C grep -aqxF "$(pwd -P)" "$LIVE_REFS"; then
  scan_fail "live-process scan did not see this process"
fi

# Matches the physical path or, under a symlinked root, its logical form.
is_live() {
  LC_ALL=C grep -aqF "$1" "$LIVE_REFS" && return 0
  [[ -n "${2:-}" && "$2" != "$1" ]] && LC_ALL=C grep -aqF "$2" "$LIVE_REFS"
}

# rc 0 when no file under $1 was modified within $DAYS days. Fails closed: if
# find cannot read part of the tree, recency is unknown and the path is kept.
is_stale() {
  local hit
  hit="$(find "$1" -newermt "-${DAYS} days" -print -quit 2>/dev/null)" || return 1
  [[ -z "$hit" ]]
}

total_kb=0
count=0
# remove <physical path> <kind> [logical alias]: safety rules are written
# against logical (~) paths, so a symlinked HOME is gated on both forms.
remove() {
  local path="$1" kind="$2" alias="${3:-}" reason kb
  if ! reason="$(safety_gate "$path")"; then
    log "PROTECTED ($reason): $path"
    return 0
  fi
  if [[ -n "$alias" && "$alias" != "$path" ]] && ! reason="$(safety_gate "$alias")"; then
    log "PROTECTED ($reason): $alias"
    return 0
  fi
  kb="$(du -sk "$path" 2>/dev/null | awk '{print $1}')"
  kb="${kb:-0}"
  if [[ "$DRY_RUN" == true ]]; then
    total_kb=$(( total_kb + kb )); count=$(( count + 1 ))
    log "DRY RUN: would remove $kind: $path (${kb} KB)"
    return 0
  fi
  chmod -R u+w "$path" 2>/dev/null || true
  if rm -rf "$path" 2>/dev/null && [[ ! -e "$path" ]]; then
    total_kb=$(( total_kb + kb )); count=$(( count + 1 ))
    deletion_log "cleanup_dark_factory" "remove_$kind" "$kb" "$path"
  else
    log "WARN: failed to remove $path"
  fi
}

# --- releases ---
if root_ok "$RELEASES_DIR"; then
  rel_logical="$RELEASES_DIR"
  RELEASES_DIR="$(phys "$RELEASES_DIR")"
  # Scan reference dirs at their physical location, so a symlinked
  # ~/.local/bin or unit dir (dotfile managers) is traversed.
  [[ -d "$BIN_DIR" ]] && BIN_DIR="$(phys "$BIN_DIR")"
  [[ -d "$UNIT_DIR" ]] && UNIT_DIR="$(phys "$UNIT_DIR")"
  ref_re="($(re_escape "$rel_logical")|$(re_escape "$RELEASES_DIR"))/[^/\"' ]+"
  units="$(mktemp)"
  if [[ -d "$UNIT_DIR" ]]; then
    find "$UNIT_DIR" \( -type f -o -type l \) >"$units" 2>/dev/null || scan_fail "unreadable $UNIT_DIR"
  fi
  if [[ -d "$BIN_DIR" ]]; then
    [[ -r "$BIN_DIR" && -x "$BIN_DIR" ]] || scan_fail "unreadable $BIN_DIR"
  fi
  keep="$(mktemp)"
  REFTEXT="$(mktemp)"
  # HOME escaped for a sed replacement (& \ and the # delimiter are special).
  home_r="$(printf '%s' "$HOME" | sed 's/[&\\#]/\\&/g')"
  {
    find "$BIN_DIR" -maxdepth 1 -type l -print0 2>/dev/null | realpaths0 || true
    # Text references: bin shims, unit files (%h expanded), live argv.
    {
      while IFS= read -r -d '' f; do  # dotfiles included; symlinks read through to their target
        [[ -r "$f" ]] || scan_fail "unreadable $f"
        if LC_ALL=C grep -Iq . "$f" 2>/dev/null; then
          cat "$f" || scan_fail "cannot read $f"
        else
          # Binary launcher (or empty file): extract embedded release paths.
          LC_ALL=C grep -aoE "$ref_re" "$f" 2>/dev/null || [[ $? -eq 1 ]] || scan_fail "cannot read $f"
        fi
      done < <(find -L "$BIN_DIR" -mindepth 1 -maxdepth 1 -type f -print0 2>/dev/null)
      while IFS= read -r f; do
        [[ -e "$f" ]] || continue  # dangling unit symlink
        [[ -r "$f" ]] || scan_fail "unreadable $f"
        cat "$f" || scan_fail "cannot read $f"
      done <"$units"
      cat "$LIVE_REFS"
    } | tr '\0' '\n' | python3 -c 'import re,sys
# systemd C escapes: \a \b \f \n \r \t \v \\ \" \x27 \s, \nnn, \xHH, \uXXXX, \UXXXXXXXX
M = {b"a": b"\a", b"b": b"\b", b"f": b"\f", b"n": b"\n", b"r": b"\r", b"t": b"\t",
     b"v": b"\v", b"\\": b"\\", b"\"": b"\"", b"\x27": b"\x27", b"s": b" "}
def dec(m):
    e = m.group(1)
    if e[:1] == b"x": return bytes([int(e[1:], 16)])
    if e[:1] in (b"u", b"U"): return chr(int(e[1:], 16)).encode("utf-8", "surrogatepass")
    if e[:1].isdigit(): return bytes([int(e, 8) & 255])
    return M[e]
pat = re.compile(rb"\\(x[0-9a-fA-F]{2}|u[0-9a-fA-F]{4}|U[0-9a-fA-F]{8}|[0-7]{3}|[abfnrtvs\\\"\x27])")
for l in sys.stdin.buffer:
    sys.stdout.buffer.write(pat.sub(dec, l))' \
      | sed -e "s#%h#$home_r#g" -e "s#\${HOME}#$home_r#g" -e "s#\$HOME#$home_r#g" -e "s#~/#$home_r/#g" \
      | tee "$REFTEXT" | { LC_ALL=C grep -aoE "$ref_re" || true; }
  } | realpaths | { grep -oE "^$(re_escape "$RELEASES_DIR")/[^/]+" || true; } | sort -u >"$keep"
  rm -f "$units"
  newest=0
  while IFS= read -r rel; do
    (( newest >= KEEP_RELEASES )) && break
    rel="${rel%/}"
    [[ -L "$rel" ]] && continue
    echo "$rel" >>"$keep"
    newest=$(( newest + 1 ))
  done < <(ls -1td "$RELEASES_DIR"/*/ 2>/dev/null || true)
  log "Releases kept (referenced or newest $KEEP_RELEASES): $(sort -u "$keep" | while IFS= read -r k; do [[ -d "$k" ]] && basename "$k" | cut -c1-7; done | tr '\n' ' ')"
  for rel in "$RELEASES_DIR"/*/; do
    rel="${rel%/}"
    [[ -d "$rel" && ! -L "$rel" ]] || continue
    grep -qxF "$rel" "$keep" && continue
    # Substring match over all reference text, so any terminator (: ; ) etc.)
    # still protects; over-protection (r1 vs r10) is the safe direction.
    LC_ALL=C grep -aqF -e "$rel" -e "$rel_logical/${rel##*/}" "$REFTEXT" && continue
    is_live "$rel" "$rel_logical/${rel##*/}" && continue
    is_stale "$rel" || { log "SKIP release (recent): $rel"; continue; }
    remove "$rel" release "$rel_logical/${rel##*/}"
  done
  rm -f "$keep"
fi

# --- runs ---
if root_ok "$RUNS_DIR"; then
  runs_logical="$RUNS_DIR"
  RUNS_DIR="$(phys "$RUNS_DIR")"
  while IFS= read -r -d '' run; do
    [[ -L "$run" ]] && continue
    is_live "$run" "$runs_logical/${run##*/}" && continue
    is_stale "$run" || continue
    remove "$run" run "$runs_logical/${run##*/}"
  done < <(find "$RUNS_DIR" -mindepth 1 -maxdepth 1 -type d -mtime +"$DAYS" -print0)
fi

# --- df-* AO session homes ---
if root_ok "$SESSIONS_DIR"; then
  sessions_logical="$SESSIONS_DIR"
  SESSIONS_DIR="$(phys "$SESSIONS_DIR")"
  for sess in "$SESSIONS_DIR"/df-*/; do
    sess="${sess%/}"
    [[ -d "$sess" && ! -L "$sess" ]] || continue
    is_live "$sess" "$sessions_logical/${sess##*/}" && { log "SKIP session (live process): $sess"; continue; }
    is_stale "$sess" || continue
    remove "$sess" session "$sessions_logical/${sess##*/}"
  done
fi

mode="Would reclaim"
[[ "$DRY_RUN" == false ]] && mode="Reclaimed"
log "$mode: ${count} item(s), $(( total_kb / 1024 / 1024 )) GiB (${total_kb} KB), threshold ${DAYS}d"
