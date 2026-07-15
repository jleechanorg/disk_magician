#!/usr/bin/env bash
# Integration coverage for the snapshot backup repository's push boundary.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WORK="$(mktemp -d -t disk_snapshot_git_guard.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

APP="$WORK/app"
HOME_DIR="$WORK/home"
BIN_DIR="$WORK/bin"
BACKUP_REPO="$HOME_DIR/.disk_magician_backup"
REMOTE_REPO="$WORK/remote.git"
mkdir -p "$APP/scripts" "$HOME_DIR" "$BIN_DIR"
cp "$REPO_ROOT/disk_magician.sh" "$APP/disk_magician.sh"
cp "$REPO_ROOT/config.json.template" "$APP/config.json.template"

cat > "$BIN_DIR/hostname" <<'SH'
#!/usr/bin/env bash
printf '%s\n' test-host
SH
chmod +x "$BIN_DIR/hostname"

write_snapshot_stub() {
    local payload="$1"
    cat > "$APP/scripts/disk_snapshot.sh" <<SH
#!/usr/bin/env bash
set -euo pipefail
[[ "\${1:-}" == "--output" ]]
mkdir -p "\$(dirname "\$2")"
printf '%s\n' '$payload' > "\$2"
SH
    chmod +x "$APP/scripts/disk_snapshot.sh"
}

init_backup_repo() {
    rm -rf "$BACKUP_REPO" "$REMOTE_REPO"
    mkdir -p "$BACKUP_REPO/backup/test-host"
    git init -q --bare "$REMOTE_REPO"
    git init -q -b main "$BACKUP_REPO"
    git -C "$BACKUP_REPO" config user.name "Disk Magician Test"
    git -C "$BACKUP_REPO" config user.email "test@disk-magician.invalid"
    printf '%s\n' '{"snapshot":"base"}' > "$BACKUP_REPO/backup/test-host/disk_snapshot.json"
    git -C "$BACKUP_REPO" add backup/test-host/disk_snapshot.json
    git -C "$BACKUP_REPO" commit -q -m base
    git -C "$BACKUP_REPO" remote add origin "$REMOTE_REPO"
    git -C "$BACKUP_REPO" push -q -u origin main
}

run_snapshot() {
    HOME="$HOME_DIR" PATH="$BIN_DIR:$PATH" bash "$APP/disk_magician.sh" snapshot
}

init_backup_repo
write_snapshot_stub '{"snapshot":"clean"}'
clean_output="$WORK/clean.out"
run_snapshot >"$clean_output" 2>&1
[[ "$(git -C "$BACKUP_REPO" rev-parse HEAD)" == "$(git --git-dir="$REMOTE_REPO" rev-parse refs/heads/main)" ]]
grep -q "Snapshot history guard passed" "$clean_output"

secret_value="outgoing-secret-marker"
private_key_begin="$(printf '%s%s' '-----BEGIN PRIVATE' ' KEY-----')"
private_key_end="$(printf '%s%s' '-----END PRIVATE' ' KEY-----')"
secret_payload="$(printf '%s\n' '{"snapshot":"outgoing-secret-marker"}' "$private_key_begin" 'not-a-real-key' "$private_key_end")"
write_snapshot_stub "$secret_payload"
secret_output="$WORK/secret.out"
remote_before="$(git --git-dir="$REMOTE_REPO" rev-parse refs/heads/main)"
if run_snapshot >"$secret_output" 2>&1; then
    echo "expected secret-bearing snapshot push to fail closed" >&2
    exit 1
fi
[[ "$(git --git-dir="$REMOTE_REPO" rev-parse refs/heads/main)" == "$remote_before" ]]
if grep -Fq "$secret_value" "$secret_output"; then
    echo "secret scanner output exposed the rejected value" >&2
    exit 1
fi
grep -q "secret scan rejected outgoing snapshot history" "$secret_output"

init_backup_repo
git -C "$BACKUP_REPO" checkout -q --orphan rewritten
git -C "$BACKUP_REPO" rm -q -rf .
mkdir -p "$BACKUP_REPO/backup/test-host"
printf '%s\n' '{"snapshot":"rewritten"}' > "$BACKUP_REPO/backup/test-host/disk_snapshot.json"
git -C "$BACKUP_REPO" add backup/test-host/disk_snapshot.json
git -C "$BACKUP_REPO" commit -q -m rewritten
git -C "$BACKUP_REPO" branch -M main
write_snapshot_stub '{"snapshot":"new-after-rewrite"}'
rewrite_output="$WORK/rewrite.out"
remote_before="$(git --git-dir="$REMOTE_REPO" rev-parse refs/heads/main)"
if run_snapshot >"$rewrite_output" 2>&1; then
    echo "expected rewritten snapshot history to fail closed" >&2
    exit 1
fi
[[ "$(git --git-dir="$REMOTE_REPO" rev-parse refs/heads/main)" == "$remote_before" ]]
grep -q "does not descend from origin/main" "$rewrite_output"

init_backup_repo
git -C "$BACKUP_REPO" branch archive/pre-reset-20260711
git -C "$BACKUP_REPO" checkout -q --orphan rewritten
git -C "$BACKUP_REPO" rm -q -rf .
mkdir -p "$BACKUP_REPO/backup/test-host"
printf '%s\n' '{"snapshot":"remote-also-rewritten"}' > "$BACKUP_REPO/backup/test-host/disk_snapshot.json"
git -C "$BACKUP_REPO" add backup/test-host/disk_snapshot.json
git -C "$BACKUP_REPO" commit -q -m remote-also-rewritten
git -C "$BACKUP_REPO" branch -M main
git -C "$BACKUP_REPO" push -q origin HEAD:refs/heads/rewritten-fixture
git --git-dir="$REMOTE_REPO" update-ref refs/heads/main "$(git -C "$BACKUP_REPO" rev-parse HEAD)"
git -C "$BACKUP_REPO" update-ref -d refs/remotes/origin/main
write_snapshot_stub '{"snapshot":"new-after-remote-rewrite"}'
archive_output="$WORK/archive.out"
if run_snapshot >"$archive_output" 2>&1; then
    echo "expected archived history loss to fail closed" >&2
    exit 1
fi
grep -q "no longer contains archive/pre-reset-20260711" "$archive_output"

init_backup_repo
credential_marker="credential-marker"
git -C "$BACKUP_REPO" remote set-url origin "https://user:${credential_marker}@example.invalid/disk_backup.git"
write_snapshot_stub '{"snapshot":"credential-url"}'
credential_output="$WORK/credential.out"
if run_snapshot >"$credential_output" 2>&1; then
    echo "expected credential-bearing remote URL to fail closed" >&2
    exit 1
fi
if grep -Fq "$credential_marker" "$credential_output"; then
    echo "credential guard output exposed the rejected value" >&2
    exit 1
fi
grep -q "embedded credentials" "$credential_output"

echo "snapshot git guard tests passed"
