#!/usr/bin/env bash
# cleanup_ollama.sh — Remove local Ollama model blobs/manifests.
set -euo pipefail

DRY_RUN=true
MODELS_DIR="${OLLAMA_MODELS_DIR:-$HOME/.ollama/models}"

usage() {
  cat <<EOF
Usage: $(basename "$0") [--clean] [--dry-run] [-h|--help]

Options:
  --clean     Delete local Ollama model blobs/manifests.
  --dry-run   Preview model-store cleanup without deleting.
  -h, --help  Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
  case "${1:-}" in
    --clean)   DRY_RUN=false ;;
    --dry-run) DRY_RUN=true ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

log() { echo "[$(date '+%Y-%m-%dT%H:%M:%S')] $*"; }

size_kb() {
  local path="$1"
  [[ -e "$path" ]] || { echo 0; return; }
  du -sk "$path" 2>/dev/null | awk '{print $1+0}' || echo 0
}

fmt_kb() {
  local kb="${1:-0}"
  awk "BEGIN{
    if ($kb >= 1048576)  printf \"%.1fG\", $kb / 1048576
    else if ($kb >= 1024) printf \"%.0fM\", $kb / 1024
    else                  printf \"%dK\", $kb
  }"
}

log "Cleanup mode: $( [[ "$DRY_RUN" == true ]] && echo DRY-RUN || echo APPLY )"
log "Ollama model store: $MODELS_DIR"

if [[ ! -d "$MODELS_DIR" ]]; then
  log "Ollama model store missing; nothing to do."
  exit 0
fi

before_kb=$(size_kb "$MODELS_DIR")
log "Before: $(fmt_kb "$before_kb")"

if command -v ollama >/dev/null 2>&1; then
  model_list=$(ollama list 2>/dev/null | awk 'NR > 1 {print $1}' || true)
  if [[ -n "$model_list" ]]; then
    log "Registered models:"
    printf '%s\n' "$model_list" | sed 's/^/  /'
  else
    log "No registered models reported by ollama list; local blobs/manifests still occupy disk."
  fi
else
  log "ollama CLI not found; cleaning model-store files directly."
fi

if [[ "$DRY_RUN" == true ]]; then
  log "[dry-run] would delete contents of $MODELS_DIR"
  log "Potential reclaim: $(fmt_kb "$before_kb")"
  exit 0
fi

find "$MODELS_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
mkdir -p "$MODELS_DIR"

after_kb=$(size_kb "$MODELS_DIR")
freed_kb=$(( before_kb - after_kb ))
[[ "$freed_kb" -lt 0 ]] && freed_kb=0
log "After: $(fmt_kb "$after_kb")"
log "Freed: $(fmt_kb "$freed_kb")"
