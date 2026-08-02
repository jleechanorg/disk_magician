#!/usr/bin/env bash
# init_shared_venv.sh
# Initializes a shared canonical venv under ~/.venvs/<repo_name>/venv
# and symlinks .venv in the target repository to it.
set -euo pipefail

REPO_DIR="${1:-$(pwd)}"
if [[ ! -d "$REPO_DIR" ]]; then
  echo "Error: Directory $REPO_DIR does not exist." >&2
  exit 1
fi

TOPLEVEL="$(git -C "$REPO_DIR" rev-parse --show-toplevel 2>/dev/null || echo "$REPO_DIR")"
REPO_NAME="$(basename "$TOPLEVEL")"
CENTRAL_DIR="$HOME/.venvs/$REPO_NAME"
CENTRAL_VENV="$CENTRAL_DIR/venv"

echo "[init_shared_venv] Initializing shared venv for $REPO_NAME..."
mkdir -p "$CENTRAL_DIR"

if [[ ! -d "$CENTRAL_VENV" ]]; then
  if command -v uv >/dev/null 2>&1; then
    uv venv "$CENTRAL_VENV"
  else
    python3 -m venv "$CENTRAL_VENV"
  fi
  echo "[init_shared_venv] Created central venv at $CENTRAL_VENV"
else
  echo "[init_shared_venv] Central venv already exists at $CENTRAL_VENV"
fi

TARGET="$TOPLEVEL/.venv"
if [[ -d "$TARGET" && ! -L "$TARGET" ]]; then
  BAK="${TARGET}.bak.$(date +%Y%m%d-%H%M%S)"
  mv "$TARGET" "$BAK"
  echo "[init_shared_venv] Backed up existing local venv to $BAK"
fi

ln -sfn "$CENTRAL_VENV" "$TARGET"
echo "[init_shared_venv] Symlinked $TARGET → $CENTRAL_VENV"
