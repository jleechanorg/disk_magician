#!/usr/bin/env bash
# Provision or upgrade a Linux quota-bounded Scratch ext4 volume with online discard.
# Idempotent: safe on a brand-new machine or an existing Scratch setup.
# Usage: sudo scripts/install_linux_scratch.sh [--user USER] [--quota-gb 200] [--mountpoint PATH] [--image PATH] [--config PATH] [--state-dir DIR]
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "Run with sudo: sudo $0 $*" >&2
  exit 1
fi

TARGET_USER="${SUDO_USER:-}"
QUOTA_GB=200
MOUNTPOINT=""
IMAGE_PATH=""
CONFIG_PATH=""
STATE_DIR=""

while (($#)); do
  case "$1" in
    --user) TARGET_USER="$2"; shift 2 ;;
    --quota-gb) QUOTA_GB="$2"; shift 2 ;;
    --mountpoint) MOUNTPOINT="$2"; shift 2 ;;
    --image) IMAGE_PATH="$2"; shift 2 ;;
    --config) CONFIG_PATH="$2"; shift 2 ;;
    --state-dir) STATE_DIR="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,4p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

[ -n "$TARGET_USER" ] || { echo "Pass --user <username> when SUDO_USER is unset" >&2; exit 2; }
[[ "$QUOTA_GB" =~ ^[1-9][0-9]*$ ]] || { echo "Invalid --quota-gb: $QUOTA_GB" >&2; exit 2; }

TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
TARGET_GROUP="$(id -gn "$TARGET_USER")"
[ -n "$TARGET_HOME" ] && [ -d "$TARGET_HOME" ] || { echo "Home not found for $TARGET_USER" >&2; exit 2; }

MOUNTPOINT="${MOUNTPOINT:-$TARGET_HOME/Scratch}"
IMAGE_PATH="${IMAGE_PATH:-$TARGET_HOME/.local/share/disk-magician/volumes/scratch.ext4}"
CONFIG_PATH="${CONFIG_PATH:-$TARGET_HOME/.config/disk-magician/config.json}"
STATE_DIR="${STATE_DIR:-$TARGET_HOME/.disk_magician_state}"
QUOTA_BYTES=$((QUOTA_GB * 1024 * 1024 * 1024))

install -d -o "$TARGET_USER" -g "$TARGET_GROUP" -m 755 "$(dirname "$IMAGE_PATH")" "$MOUNTPOINT" "$(dirname "$CONFIG_PATH")" "$STATE_DIR/volumes"

if [ ! -f "$IMAGE_PATH" ]; then
  truncate -s "$QUOTA_BYTES" "$IMAGE_PATH"
  mkfs.ext4 -F -q -L diskm-scratch "$IMAGE_PATH"
  chown "$TARGET_USER:$TARGET_GROUP" "$IMAGE_PATH"
  chmod 600 "$IMAGE_PATH"
  echo "Created sparse ${QUOTA_GB} GiB ext4 image: $IMAGE_PATH"
else
  EXISTING_BYTES="$(stat -c %s "$IMAGE_PATH")"
  if [ "$EXISTING_BYTES" -ne "$QUOTA_BYTES" ]; then
    QUOTA_BYTES="$EXISTING_BYTES"
    QUOTA_GB=$((EXISTING_BYTES / 1073741824))
  fi
  echo "Preserving existing image: $IMAGE_PATH (${QUOTA_GB} GiB)"
fi

FS_UUID="$(blkid -s UUID -o value "$IMAGE_PATH" | tr '[:upper:]' '[:lower:]')"
[ -n "$FS_UUID" ] || { echo "Failed to read filesystem UUID from $IMAGE_PATH" >&2; exit 1; }

python3 - /etc/fstab "$IMAGE_PATH" "$MOUNTPOINT" "$CONFIG_PATH" "$STATE_DIR/volumes/registry.json" "$QUOTA_GB" "$QUOTA_BYTES" "$FS_UUID" <<'PY'
import datetime, hashlib, json, os, pathlib, shutil, sys

fstab = pathlib.Path(sys.argv[1])
image, mount = sys.argv[2], sys.argv[3]
cfg_path, reg_path = pathlib.Path(sys.argv[4]), pathlib.Path(sys.argv[5])
quota_gb, quota_bytes, fs_uuid = int(sys.argv[6]), int(sys.argv[7]), sys.argv[8]

tag = hashlib.sha256(f"{image}\n{mount}\n".encode()).hexdigest()
begin, end = f"# diskm-scratch:{tag}:begin\n", f"# diskm-scratch:{tag}:end\n"
opts_str = "loop,user,noauto,nosuid,nodev,noatime,exec,discard"
entry_line = f"{image} {mount} ext4 {opts_str} 0 0\n"

lines = fstab.read_text(encoding="utf-8").splitlines(keepends=True)
out, matched, changed, inside = [], 0, False, False
for line in lines:
    stripped = line.strip()
    if stripped.startswith("# diskm-scratch:") and stripped.endswith(":begin"):
        inside = True
        continue
    if inside:
        if stripped.startswith("# diskm-scratch:") and stripped.endswith(":end"):
            inside = False
        continue
    if stripped and not stripped.startswith("#"):
        parts = stripped.split()
        if len(parts) >= 4 and parts[1] == mount:
            matched += 1
            opts = parts[3].split(",")
            if "discard" not in opts:
                opts.append("discard")
                parts[3] = ",".join(opts)
                line = " ".join(parts) + "\n"
                changed = True
    out.append(line)

if matched == 0:
    if out and not out[-1].endswith("\n"):
        out[-1] += "\n"
    out.extend([begin, entry_line, end])
    changed = True

if changed:
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    backup = f"{fstab}.bak.{stamp}"
    shutil.copy2(fstab, backup)
    fstab.write_text("".join(out), encoding="utf-8")
    print(f"Updated {fstab} (backup: {backup})")

cfg = json.loads(cfg_path.read_text(encoding="utf-8")) if cfg_path.exists() else {}
vols = cfg.setdefault("volumes", {})
vols.setdefault("swap_headroom_gb", 40)
vols.setdefault("alarm_floor_gb", 20)
vols["encryption"] = "none"
vols["classes"] = {
    "scratch": {
        "name": "diskm-scratch",
        "quota_gb": quota_gb,
        "image_path": image,
        "mountpoint": mount,
        "backend": "native",
    }
}
tmp = cfg_path.with_suffix(".json.tmp")
tmp.write_text(json.dumps(cfg, indent=2) + "\n", encoding="utf-8")
os.replace(tmp, cfg_path)

reg = {
    "schema_version": 1,
    "volumes": {
        "scratch": {
            "state": "active",
            "image_path": image,
            "mountpoint": mount,
            "quota_bytes": quota_bytes,
            "filesystem_uuid": fs_uuid,
        }
    },
}
rtmp = reg_path.with_suffix(".json.tmp")
rtmp.write_text(json.dumps(reg, indent=2) + "\n", encoding="utf-8")
os.replace(rtmp, reg_path)
PY

chown "$TARGET_USER:$TARGET_GROUP" "$CONFIG_PATH" "$STATE_DIR/volumes/registry.json"
systemctl daemon-reload
if mountpoint -q "$MOUNTPOINT"; then
  mount -o remount,discard "$MOUNTPOINT"
else
  mount "$MOUNTPOINT"
fi
chown "$TARGET_USER:$TARGET_GROUP" "$MOUNTPOINT"

BALLAST="$MOUNTPOINT/.diskm-ballast"
if [ ! -f "$BALLAST" ]; then
  dd if=/dev/zero of="$BALLAST" bs=1M count=64 status=none
  chown "$TARGET_USER:$TARGET_GROUP" "$BALLAST"
  chmod 600 "$BALLAST"
fi

echo "Verified Linux Scratch mount:"
findmnt -no SOURCE,TARGET,FSTYPE,OPTIONS "$MOUNTPOINT"
