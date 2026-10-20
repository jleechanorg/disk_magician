#!/usr/bin/env bash
# test_av_secret_like.sh — _av_secret_like false-positive refinement: vendored
# source/derived-code names and git-tracked files are not secrets; untracked
# config/key/credential names stay secret-like; git failure fails closed.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0
TMP="$(mktemp -d /tmp/dm-av-secret.XXXXXX)" || exit 2
case "$TMP" in /tmp/dm-av-secret.*|/private/tmp/dm-av-secret.*) ;; *) exit 2 ;; esac
trap '/bin/rm -rf "${TMP:?}"' EXIT
export HOME="$TMP/home"; mkdir -p "$HOME" "$TMP/state"
export DISK_MAGICIAN_STATE_DIR="$TMP/state" GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@invalid
# shellcheck source=scripts/lib/artifact_verdict.sh
source "$ROOT/scripts/lib/artifact_verdict.sh"

# expect <secret|clean> <name> [tracked]
expect() {
    local want="$1" name="$2" tracked="${3:-}" d got
    d="$(mktemp -d "$TMP/c.XXXXXX")"
    git -C "$d" init -q
    mkdir -p "$d/$(dirname "$name")"; echo x >"$d/$name"
    [[ -n "$tracked" ]] && git -C "$d" add -f -- "$name" && git -C "$d" commit -qm t
    if _av_secret_like "$d"; then got=secret; else got=clean; fi
    if [[ "$got" == "$want" ]]; then PASS=$((PASS + 1)); echo "  PASS: $name ${tracked:+(tracked) }-> $got"
    else FAIL=$((FAIL + 1)); echo "  FAIL: $name ${tracked:+(tracked) }expected $want got $got"; fi
}
for n in credentials.js credentials.d.ts credentials.js.map gcredentials.h \
    defaultawssecuritycredentialssupplier.js gunixcredentialsmessage.h credentials.d.ts.map; do
    expect clean "third-party/$n"
done
for n in credentials credentials.json credentials.yaml .env .env.local id_rsa deploy.pem app.key secrets.toml \
    secrets.yml a.p12 x.pfx .npmrc credentials.plist; do
    expect secret "$n"
done
expect clean .env.example
expect clean credentials.json tracked
expect clean .env.example tracked

# Parity table shared with test_worktree_ignored_fail_closed.sh (plain untracked files).
TABLE="$ROOT/tests/secret_name_table.tsv"
while IFS=$'\t' read -r want rel; do
    [[ -z "$want" || "$want" == \#* ]] && continue
    d="$(mktemp -d "$TMP/t.XXXXXX")"; mkdir -p "$d/$(dirname "$rel")"; echo x >"$d/$rel"
    if _av_secret_like "$d"; then got=secret; else got=clean; fi
    if [[ "$got" == "$want" ]]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "  FAIL: table $rel expected $want got $got"; fi
done <"$TABLE"

# git failure (corrupt .git) -> fail closed
d="$(mktemp -d "$TMP/c.XXXXXX")"; mkdir "$d/.git"; echo garbage >"$d/.git/HEAD"; echo x >"$d/credentials.json"
if _av_secret_like "$d"; then PASS=$((PASS + 1)); echo "  PASS: corrupt .git -> secret"
else FAIL=$((FAIL + 1)); echo "  FAIL: corrupt .git expected secret"; fi

echo "passed=$PASS failed=$FAIL"
[[ $FAIL -eq 0 ]]
