#!/usr/bin/env bash
# install.sh — Local installation script for Disk Magician.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "=== Syncing package files ==="
cp disk_magician.sh src/disk_magician/
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
