#!/usr/bin/env bash
# test_c14_playwright_secret.sh — c14_probe secrets: WebCore *Credentials*.h headers inside a
# Playwright webkit-<n> build (INSTALLATION_COMPLETE present) are not secrets; a real
# secret-like file in that build, or the same header outside that layout, still is.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROBE="${C14_PROBE:-$ROOT/scripts/c14_probe.py}"
PASS=0; FAIL=0
TMP="$(mktemp -d "${TMPDIR:-/tmp}/dm-pw-secret.XXXXXX")" || exit 2
case "$TMP" in */dm-pw-secret.*) ;; *) exit 2 ;; esac
trap 'python3 -c "import shutil,sys; shutil.rmtree(sys.argv[1], True)" "$TMP"' EXIT
H=WebCore.framework/Versions/A/PrivateHeaders

# expect <secret|clean> <root-name> <marker yes|no> <rel path>...
expect() {
    local want="$1" name="$2" marker="$3" got exp rows r
    shift 3
    rows="{\"path\":\".\",\"name\":\"$name\"}"
    [[ "$marker" == yes ]] && rows="$rows,{\"path\":\"INSTALLATION_COMPLETE\"}"
    for r in "$@"; do rows="$rows,{\"path\":\"$r\"}"; done
    printf '[%s]' "$rows" >"$TMP/inv.json"
    got="$(python3 "$PROBE" secrets "$TMP/inv.json" rebuildable)"
    exp=no; [[ "$want" == secret ]] && exp=yes
    if [[ "$got" == "$exp" ]]; then PASS=$((PASS + 1)); echo "  PASS: $name marker=$marker $* -> $got"
    else FAIL=$((FAIL + 1)); echo "  FAIL: $name marker=$marker $* expected $exp got $got"; fi
}
for n in StoredCredentialsPolicy.h FetchRequestCredentials.h DigitalCredentialsProtocols.h; do
    expect clean webkit-2311 yes "$H/$n"
done
expect clean webkit-2311 yes "$H/StoredCredentialsPolicy.h" "$H/WebCore.h"
# Same header outside the verified layout stays secret-like.
expect secret webkit-2311 no "$H/StoredCredentialsPolicy.h"
expect secret my-project yes "$H/StoredCredentialsPolicy.h"
expect secret webkit-2311 yes "Other/StoredCredentialsPolicy.h"
expect secret webkit-2311 yes "StoredCredentialsPolicy.h"
# Real secrets inside a genuine browser build still protect it.
expect secret webkit-2311 yes "$H/StoredCredentialsPolicy.h" ".env"
expect secret webkit-2311 yes "$H/StoredCredentialsPolicy.h" "$H/deploy.pem"
expect secret webkit-2311 yes "credentials.json"
expect secret webkit-2311 yes "$H/credentials.h"
echo "passed=$PASS failed=$FAIL"
[[ $FAIL -eq 0 ]]
