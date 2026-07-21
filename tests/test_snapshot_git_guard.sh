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
# Snapshot dispatch now delegates to scripts/snapshot_commit.sh (design:
# roadmap/2026-07-21-generic-split-state-repo-design.md §Snapshot/commit
# flow), which in turn needs the state-repo helper scripts — copy the whole
# scripts/ dir rather than hand-picking files that could silently drift.
cp "$REPO_ROOT"/scripts/*.sh "$APP/scripts/"
cp "$REPO_ROOT"/scripts/*.py "$APP/scripts/"

# Grandfather $BACKUP_REPO via state_repo_path (same one-time setup
# README.md's "Grandfathering an existing backup repo" section documents)
# so the new state-repo write path targets the exact directory this test's
# init_backup_repo()/REMOTE_REPO fixtures already manage, instead of a fresh
# unrelated state dir under .local/state.
mkdir -p "$HOME_DIR/.config/disk-magician"
printf '{"state_repo_path": "%s"}\n' "$BACKUP_REPO" > "$HOME_DIR/.config/disk-magician/config.json"

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

run_snapshot_launchd() {
    HOME="$HOME_DIR" \
        PATH="$BIN_DIR:/usr/bin:/bin:/usr/sbin:/sbin" \
        HOMEBREW_PREFIX="${HOMEBREW_PREFIX:-}" \
        DISK_MAGICIAN_GITLEAKS_BIN="${DISK_MAGICIAN_GITLEAKS_BIN:-}" \
        bash "$APP/disk_magician.sh" snapshot
}

init_backup_repo
write_snapshot_stub '{"snapshot":"clean"}'
clean_output="$WORK/clean.out"
run_snapshot >"$clean_output" 2>&1
[[ "$(git -C "$BACKUP_REPO" rev-parse HEAD)" == "$(git --git-dir="$REMOTE_REPO" rev-parse refs/heads/main)" ]]
grep -q "Snapshot history guard passed" "$clean_output"

init_backup_repo
write_snapshot_stub '{"snapshot":"homebrew-only"}'
real_gitleaks="$(command -v gitleaks)"
fake_homebrew="$WORK/homebrew"
gitleaks_marker="$WORK/homebrew-gitleaks-called"
mkdir -p "$fake_homebrew/bin"
cat > "$fake_homebrew/bin/gitleaks" <<SH
#!/usr/bin/env bash
printf '%s\n' called > "$gitleaks_marker"
exec "$real_gitleaks" "\$@"
SH
chmod +x "$fake_homebrew/bin/gitleaks"
homebrew_output="$WORK/homebrew.out"
HOMEBREW_PREFIX="$fake_homebrew" run_snapshot_launchd >"$homebrew_output" 2>&1
[[ -s "$gitleaks_marker" ]]
grep -q "Snapshot history guard passed" "$homebrew_output"

init_backup_repo
write_snapshot_stub '{"snapshot":"missing-gitleaks"}'
missing_output="$WORK/missing.out"
remote_before="$(git --git-dir="$REMOTE_REPO" rev-parse refs/heads/main)"
# Fail-safe contract (design: roadmap/2026-07-21-generic-split-state-repo-design.md
# §Snapshot/commit flow): a rejected push is never fatal to the overall
# snapshot process (the commit already landed locally and must not be lost),
# but the rejection itself still has to hold — nothing reaches the remote,
# and the reason is still logged.
if ! DISK_MAGICIAN_GITLEAKS_BIN="$WORK/absent-gitleaks" run_snapshot_launchd >"$missing_output" 2>&1; then
    echo "expected fail-safe snapshot to exit 0 even when the push guard rejects (commit stays local, never fatal)" >&2
    exit 1
fi
[[ "$(git --git-dir="$REMOTE_REPO" rev-parse refs/heads/main)" == "$remote_before" ]]
grep -q "gitleaks is unavailable" "$missing_output"

secret_value="outgoing-secret-marker"
private_key_begin="$(printf '%s%s' '-----BEGIN PRIVATE' ' KEY-----')"
private_key_end="$(printf '%s%s' '-----END PRIVATE' ' KEY-----')"
secret_payload="$(printf '%s\n' '{"snapshot":"outgoing-secret-marker"}' "$private_key_begin" 'not-a-real-key' "$private_key_end")"
write_snapshot_stub "$secret_payload"
secret_output="$WORK/secret.out"
rejecting_gitleaks="$WORK/rejecting-gitleaks"
rejecting_gitleaks_marker="$WORK/rejecting-gitleaks-called"
cat > "$rejecting_gitleaks" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" > "$rejecting_gitleaks_marker"
exit 1
SH
chmod +x "$rejecting_gitleaks"
remote_before="$(git --git-dir="$REMOTE_REPO" rev-parse refs/heads/main)"
if ! DISK_MAGICIAN_GITLEAKS_BIN="$rejecting_gitleaks" run_snapshot >"$secret_output" 2>&1; then
    echo "expected fail-safe snapshot to exit 0 even when the push guard rejects (commit stays local, never fatal)" >&2
    exit 1
fi
[[ "$(git --git-dir="$REMOTE_REPO" rev-parse refs/heads/main)" == "$remote_before" ]]
grep -q -- '--redact=100' "$rejecting_gitleaks_marker"
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
if ! run_snapshot >"$rewrite_output" 2>&1; then
    echo "expected fail-safe snapshot to exit 0 even when the push guard rejects (commit stays local, never fatal)" >&2
    exit 1
fi
[[ "$(git --git-dir="$REMOTE_REPO" rev-parse refs/heads/main)" == "$remote_before" ]]
# state_repo.sh's cmd_push resolves ordinary divergence via an automatic
# rebase BEFORE the push guard runs (pre-existing, separately-tested
# contract: tests/test_state_repo.sh Test 10 "conflicting divergence").
# Since this fixture's rewritten local history has no shared content with
# origin/main, the rebase itself conflicts and cmd_push aborts there — a
# different message than the old inline guard's direct ancestor check, but
# the same safety property: local history that doesn't descend from origin
# is never pushed, and nothing is lost.
grep -q "diverged from origin/main with conflicts" "$rewrite_output"

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
if ! run_snapshot >"$archive_output" 2>&1; then
    echo "expected fail-safe snapshot to exit 0 even when the push guard rejects (commit stays local, never fatal)" >&2
    exit 1
fi
grep -q "no longer contains archive/pre-reset-20260711" "$archive_output"

init_backup_repo
credential_marker="credential-marker"
git -C "$BACKUP_REPO" remote set-url origin "https://user:${credential_marker}@example.invalid/disk_backup.git"
write_snapshot_stub '{"snapshot":"credential-url"}'
credential_output="$WORK/credential.out"
if ! run_snapshot >"$credential_output" 2>&1; then
    echo "expected fail-safe snapshot to exit 0 even when the push guard rejects (commit stays local, never fatal)" >&2
    exit 1
fi
if grep -Fq "$credential_marker" "$credential_output"; then
    echo "credential guard output exposed the rejected value" >&2
    exit 1
fi
grep -q "embedded credentials" "$credential_output"

echo "snapshot git guard tests passed"
