#!/usr/bin/env bash
# install.sh — Local installation script for Disk Magician.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "=== Syncing package files ==="
cp disk_magician.sh src/disk_magician/
cp config.json.template src/disk_magician/
cp -r scripts/* src/disk_magician/scripts/

echo "=== Setting script permissions ==="
chmod +x disk_magician.sh scripts/*.sh src/disk_magician/disk_magician.sh src/disk_magician/scripts/*.sh

echo "=== Cleaning up previous build artifacts ==="
rm -rf build dist src/*.egg-info *.egg-info

echo "=== Installing Disk Magician locally ==="

if command -v uv &>/dev/null; then
  echo "Detected 'uv'. Installing using 'uv tool install'..."
  uv tool install --force --no-cache .
  echo "Disk Magician successfully installed via uv!"
  echo "You can now run it using: disk-magician"
elif command -v pip3 &>/dev/null; then
  echo "Detected 'pip3'. Installing in user space..."
  pip3 install --user .
  echo "Disk Magician successfully installed via pip3!"
  echo "Ensure your ~/.local/bin or Python user bin is in your PATH."
else
  echo "Error: Neither 'uv' nor 'pip3' was found in your PATH." >&2
  exit 1
fi

echo "=== Installing Claude Commands and Skills ==="
CLAUDE_DIR="${HOME}/.claude"
if [[ -d "$CLAUDE_DIR" ]]; then
  mkdir -p "$CLAUDE_DIR/commands" "$CLAUDE_DIR/skills/disk_magician" \
    "$CLAUDE_DIR/skills/disk-root-cause" "$CLAUDE_DIR/skills/disk-audit"
  cp "$SCRIPT_DIR/skills/claude/SKILL.md" "$CLAUDE_DIR/skills/disk_magician/SKILL.md"
  cp "$SCRIPT_DIR/skills/disk-root-cause/SKILL.md" "$CLAUDE_DIR/skills/disk-root-cause/SKILL.md"
  cp "$SCRIPT_DIR/skills/disk-audit/SKILL.md" "$CLAUDE_DIR/skills/disk-audit/SKILL.md"
  cp "$SCRIPT_DIR/skills/claude/commands/disk_magician.md" "$CLAUDE_DIR/commands/disk_magician.md"
  cp "$SCRIPT_DIR/skills/claude/commands/diskm.md" "$CLAUDE_DIR/commands/diskm.md"
  cp "$SCRIPT_DIR/commands/disk-root-cause.md" "$CLAUDE_DIR/commands/disk-root-cause.md"
  echo "Claude commands (/disk_magician, /diskm) and skill successfully installed!"
else
  echo "Warning: ~/.claude directory not found. Skipping Claude commands/skills installation."
fi

echo "=== Installing Codex Skill ==="
mkdir -p "${HOME}/.agents/skills/disk-root-cause" "${HOME}/.agents/skills/disk-audit"
cp "$SCRIPT_DIR/skills/disk-root-cause/SKILL.md" "${HOME}/.agents/skills/disk-root-cause/SKILL.md"
cp "$SCRIPT_DIR/skills/disk-audit/SKILL.md" "${HOME}/.agents/skills/disk-audit/SKILL.md"
echo "Codex disk-root-cause and disk-audit skills successfully installed!"

echo "=== Optional: install weekly launchd sweepers ==="
echo "Run: ./scripts/install_launchd_sweepers.sh --unload-legacy"
