#!/usr/bin/env bash
# test_cleanup_colima_paths.sh — Colima root resolution (macOS vs Linux XDG)
#
# The cleaner hardcoded ~/.colima/_lima and skipped as "not Colima" on a host
# whose VM lives at ~/.config/colima (8.8 GiB, running, 2026-10-22). This test
# pins the resolution order so the Linux path cannot regress:
#   COLIMA_HOME -> existing ~/.colima/_lima -> existing $XDG_CONFIG_HOME/colima/_lima
#   -> ~/.colima (macOS default)
#
# Run: bash tests/test_cleanup_colima_paths.sh
set -uo pipefail

REPO_ROOT="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/cleanup_colima.sh"

PASS=0
FAIL=0
ok() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $1"; echo "        $2"; FAIL=$((FAIL + 1)); }

TMPROOT="$(CDPATH= cd -- "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMPROOT"' EXIT

run_paths() { # run_paths <home> <xdg_config_home> [colima_home]
  local home="$1" xdg="$2" ch="${3:-}"
  env -i PATH="/usr/bin:/bin:/usr/sbin" HOME="$home" XDG_CONFIG_HOME="$xdg" \
      ${ch:+COLIMA_HOME="$ch"} bash "$SCRIPT" --print-paths 2>&1
}

field() { sed -n "s/^$1=//p" <<<"$2"; }

# --- case 1: macOS layout (~/.colima/_lima exists) --------------------------
H1="$TMPROOT/h1"; mkdir -p "$H1/.colima/_lima"
OUT=$(run_paths "$H1" "$H1/.config")
[[ "$(field COLIMA_LIMA "$OUT")" == "$H1/.colima/_lima" ]] \
  && ok "macOS ~/.colima/_lima wins when present" \
  || bad "macOS ~/.colima/_lima wins when present" "got $(field COLIMA_LIMA "$OUT")"

# --- case 2: Linux XDG layout, no ~/.colima --------------------------------
H2="$TMPROOT/h2"; mkdir -p "$H2/.config/colima/_lima"
OUT=$(run_paths "$H2" "$H2/.config")
[[ "$(field COLIMA_LIMA "$OUT")" == "$H2/.config/colima/_lima" ]] \
  && ok "XDG ~/.config/colima/_lima used on Linux" \
  || bad "XDG ~/.config/colima/_lima used on Linux" "got $(field COLIMA_LIMA "$OUT")"
[[ "$(field COLIMA_DOCKER_SOCKET "$OUT")" == "$H2/.config/colima/default/docker.sock" ]] \
  && ok "socket follows the resolved root" \
  || bad "socket follows the resolved root" "got $(field COLIMA_DOCKER_SOCKET "$OUT")"

# --- case 3: COLIMA_HOME beats both ---------------------------------------
H3="$TMPROOT/h3"; mkdir -p "$H3/.config/colima/_lima" "$TMPROOT/ch/_lima"
OUT=$(run_paths "$H3" "$H3/.config" "$TMPROOT/ch")
[[ "$(field COLIMA_ROOT "$OUT")" == "$TMPROOT/ch" ]] \
  && ok "COLIMA_HOME overrides the XDG root" \
  || bad "COLIMA_HOME overrides the XDG root" "got $(field COLIMA_ROOT "$OUT")"

# --- case 4: neither exists -> macOS default (never invents the XDG path) --
H4="$TMPROOT/h4"; mkdir -p "$H4"
OUT=$(run_paths "$H4" "$H4/.config")
[[ "$(field COLIMA_ROOT "$OUT")" == "$H4/.colima" ]] \
  && ok "default root stays ~/.colima when nothing exists" \
  || bad "default root stays ~/.colima when nothing exists" "got $(field COLIMA_ROOT "$OUT")"

# --- case 5: --print-paths never touches the VM ---------------------------
H5="$TMPROOT/h5"; mkdir -p "$H5/.config/colima/_lima"
OUT=$(run_paths "$H5" "$H5/.config")
lines=$(grep -c . <<<"$OUT")
if [[ "$lines" -eq 3 ]] && ! grep -qvE '^COLIMA_(ROOT|LIMA|DOCKER_SOCKET)=' <<<"$OUT"; then
  ok "--print-paths is side-effect free"
else
  bad "--print-paths is side-effect free" "unexpected lines: $OUT"
fi

echo
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
