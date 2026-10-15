#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
FIXTURE="$(mktemp -d /tmp/dm-selftest-isolation.XXXXXX)" || exit 1
[[ -d "$FIXTURE" && "$FIXTURE" == /tmp/dm-selftest-isolation.* ]] || exit 1
trap 'rm -rf -- "$FIXTURE"' EXIT
export HOME="$FIXTURE/home" DISK_MAGICIAN_STATE_DIR="$FIXTURE/state"
mkdir -p "$HOME" "$FIXTURE/untouched"
printf 'preserve\n' >"$FIXTURE/untouched/sentinel"
LIB="$ROOT/scripts/lib/artifact_verdict.sh"

# A malformed allocator result must never become a cleanup target.
result="$(bash -c 'source "$1"; mktemp() { return 1; }; artifact_removal_verdict --self-test' _ "$LIB")"
[[ "$result" == incomplete ]]
result="$(BAD_ROOT="$FIXTURE/untouched" bash -c 'source "$1"; mktemp() { printf "%s\n" "$BAD_ROOT"; }; artifact_removal_verdict --self-test' _ "$LIB")"
[[ "$result" == incomplete && "$(cat "$FIXTURE/untouched/sentinel")" == preserve ]]
echo 'PASS: invalid allocation cannot remove caller data'

git init -q -b main "$FIXTURE/caller"
git -C "$FIXTURE/caller" -c user.name=test -c user.email=test@invalid commit -q --allow-empty -m caller
before="$(git -C "$FIXTURE/caller" rev-parse HEAD)"
printf '[core]\n hooksPath = %s\n' "$FIXTURE/hooks" >"$FIXTURE/global-config"
mkdir -p "$FIXTURE/hooks"
printf '#!/bin/sh\ntouch "%s"\n' "$FIXTURE/hook-ran" >"$FIXTURE/hooks/pre-commit"
chmod +x "$FIXTURE/hooks/pre-commit"
result="$(GIT_DIR="$FIXTURE/caller/.git" GIT_WORK_TREE="$FIXTURE/caller" GIT_CONFIG_GLOBAL="$FIXTURE/global-config" bash "$LIB" --self-test)"
[[ "$result" == ok ]]
[[ "$(git -C "$FIXTURE/caller" rev-parse HEAD)" == "$before" ]]
[[ -z "$(git -C "$FIXTURE/caller" status --porcelain)" && ! -e "$FIXTURE/hook-ran" ]]
echo 'PASS: real self-test ignores caller Git repository and hooks'
