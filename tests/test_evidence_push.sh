#!/usr/bin/env bash
# test_evidence_push.sh — `diskm evidence-push` (plan A7, spec D8).
#
# A fake `gcloud` on PATH logs its argv; nothing ever reaches real GCS. Sources
# live under a private temp dir that the test points EVIDENCE_TMP_ROOT at, so
# the /tmp gate is exercised without depending on where mktemp lands.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/evidence_push.sh"

PASS=0
FAIL=0

ok() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

assert_eq() {
    local actual="$1" expected="$2" what="$3"
    if [[ "$actual" == "$expected" ]]; then ok "$what (= $expected)"; else bad "$what — expected '$expected', got '$actual'"; fi
}
assert_contains() {
    local hay="$1" needle="$2" what="$3"
    if [[ "$hay" == *"$needle"* ]]; then ok "$what"; else bad "$what — missing '$needle' in: $hay"; fi
}

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/allowed" "$T/outside" "$T/home"
GLOG="$T/gcloud.log"
cat > "$T/bin/gcloud" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$GLOG"
EOF
chmod +x "$T/bin/gcloud"

export HOME="$T/home"
export EVIDENCE_TMP_ROOT="$T/allowed"
export EVIDENCE_GCS_PREFIX="gs://wa-test-evidence/agent-evidence"
FAKE_PATH="$T/bin:/usr/bin:/bin"

# run <args...> — sets OUT and RC.
run() {
    : > "$GLOG"
    OUT="$(PATH="$FAKE_PATH" bash "$SCRIPT" "$@" 2>&1)"
    RC=$?
}
uploads() { if [[ -s "$GLOG" ]]; then wc -l < "$GLOG" | tr -d ' '; else echo 0; fi; }

SRC="$T/allowed/r/evidence/s"
mkdir -p "$SRC"
echo ok > "$SRC/result.txt"

echo "== case 1: happy path uploads and prints URIs =="
run "$SRC" --repo r --slug s
assert_eq "$RC" "0" "exit code"
REAL_SRC="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$SRC")"
assert_eq "$(cat "$GLOG")" "storage rsync -r $REAL_SRC gs://wa-test-evidence/agent-evidence/r/s/" "gcloud argv"
assert_contains "$OUT" "gs://wa-test-evidence/agent-evidence/r/s/" "prints gs:// URI"
assert_contains "$OUT" "https://console.cloud.google.com/storage/browser/wa-test-evidence/agent-evidence/r/s" "prints console URL"

echo "== case 2: source outside the evidence tmp root -> exit 2, no upload =="
echo x > "$T/outside/f.txt"
run "$T/outside" --repo r --slug s
assert_eq "$RC" "2" "outside source exit code"
assert_eq "$(uploads)" "0" "no upload for outside source"

echo "== case 3: symlink under root pointing outside is resolved -> exit 2 =="
ln -s "$T/outside" "$T/allowed/link"
run "$T/allowed/link" --repo r --slug s
assert_eq "$RC" "2" "symlink escape exit code"
assert_eq "$(uploads)" "0" "no upload via symlink escape"

echo "== case 4: '..' escape -> exit 2 =="
run "$T/allowed/../outside" --repo r --slug s
assert_eq "$RC" "2" "dot-dot escape exit code"

echo "== case 5: secret-shaped filenames -> exit 3, no upload =="
for name in .env .env.local server.pem tls.key id_rsa id_rsa.pub id_ed25519 gcp-credentials.json; do
    D="$T/allowed/secret_$name"
    mkdir -p "$D/nested"
    echo ok > "$D/ok.txt"
    echo s > "$D/nested/$name"
    run "$D" --repo r --slug s
    assert_eq "$RC" "3" "refuses $name"
    assert_eq "$(uploads)" "0" "no upload with $name present"
done

echo "== case 6: missing gcloud -> exit 1 =="
OUT="$(PATH="/usr/bin:/bin" bash "$SCRIPT" "$SRC" --repo r --slug s 2>&1)"; RC=$?
assert_eq "$RC" "1" "missing gcloud exit code"

echo "== case 7: --repo/--slug required and single path components =="
for args in "--slug s" "--repo r" "--repo a/b --slug s" "--repo r --slug .." "--repo . --slug s" "--repo r --slug ''"; do
    eval "run \"\$SRC\" $args"
    if [[ "$RC" != "0" ]]; then ok "rejects: $args (rc=$RC)"; else bad "accepted invalid args: $args"; fi
    assert_eq "$(uploads)" "0" "no upload for: $args"
done

echo "== case 8: source must be an existing directory =="
run "$T/allowed/nope" --repo r --slug s
if [[ "$RC" != "0" ]]; then ok "missing source rejected (rc=$RC)"; else bad "missing source accepted"; fi

echo "== case 9: default root is /tmp =="
D="$(mktemp -d /tmp/test_evidence_push.XXXXXX)"
echo ok > "$D/f.txt"
: > "$GLOG"
OUT="$(env -u EVIDENCE_TMP_ROOT PATH="$FAKE_PATH" bash "$SCRIPT" "$D" --repo r --slug s 2>&1)"; RC=$?
rm -rf "$D"
assert_eq "$RC" "0" "/tmp source accepted with default root"
OUT="$(env -u EVIDENCE_TMP_ROOT PATH="$FAKE_PATH" bash "$SCRIPT" "$T/outside" --repo r --slug s 2>&1)"; RC=$?
if [[ "$T" == /tmp/* || "$T" == /private/tmp/* ]]; then
    ok "skip: mktemp landed under /tmp, outside-default case not observable"
else
    assert_eq "$RC" "2" "non-/tmp source rejected with default root"
fi

echo "== case 10: secret-shaped content (no gitleaks on PATH) -> exit 3, no upload, secret not echoed =="
# Assembled from fragments so this test file itself carries no literal secret.
i=0
for secret in \
    "-----BEGIN RSA ""PRIVATE KEY-----" \
    "-----BEGIN ""PRIVATE KEY-----" \
    "AKIA""ABCDEFGHIJKLMNOP" \
    "ghp_""abcdefghijklmnopqrstuvwxyzABCDEFGHIJ" \
    "github_pat_""11ABCDEFG0abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUV" \
    "xoxb-""1234567890-abcdef" \
    "sk-""abcdefghijklmnopqrstuvwx" \
    '{"private_''key" : "x"}'; do
    i=$((i + 1))
    D="$T/allowed/content_$i"
    mkdir -p "$D/nested"
    echo ok > "$D/ok.txt"
    printf 'prefix %s suffix\n' "$secret" > "$D/nested/log.txt"
    run "$D" --repo r --slug s
    assert_eq "$RC" "3" "content pattern $i refused"
    assert_eq "$(uploads)" "0" "no upload for content pattern $i"
    assert_contains "$OUT" "nested/log.txt" "names offending file for pattern $i"
    if [[ "$OUT" == *"$secret"* ]]; then bad "secret $i echoed in output"; else ok "secret $i not echoed"; fi
done

echo "== case 11: files > 20 MB are skipped (logged), clean otherwise -> uploads =="
D="$T/allowed/big"
mkdir -p "$D"
echo ok > "$D/ok.txt"
python3 -c 'import sys; f=open(sys.argv[1],"wb"); f.truncate(21*1024*1024)' "$D/blob.bin"
run "$D" --repo r --slug s
assert_eq "$RC" "0" "big clean dir uploads"
assert_contains "$OUT" "blob.bin" "logs skipped big file"

GLBIN="$T/glbin"
mkdir -p "$GLBIN"
GL_LOG="$T/gitleaks.log"
fake_gitleaks() {
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s"\nexit %s\n' "$GL_LOG" "$1" > "$GLBIN/gitleaks"
    chmod +x "$GLBIN/gitleaks"
}
run_gl() {
    : > "$GLOG"; : > "$GL_LOG"
    OUT="$(PATH="$GLBIN:$FAKE_PATH" bash "$SCRIPT" "$@" 2>&1)"
    RC=$?
}

echo "== case 12: gitleaks exit 1 (leaks) -> exit 3, no upload =="
fake_gitleaks 1
run_gl "$SRC" --repo r --slug s
assert_eq "$RC" "3" "gitleaks leak exit code"
assert_eq "$(uploads)" "0" "no upload when gitleaks finds leaks"
assert_eq "$(cat "$GL_LOG")" "detect --no-git --source $REAL_SRC --no-banner --redact" "gitleaks argv"

echo "== case 13: gitleaks other non-zero -> fail closed exit 3 =="
fake_gitleaks 2
run_gl "$SRC" --repo r --slug s
assert_eq "$RC" "3" "gitleaks error exit code"
assert_eq "$(uploads)" "0" "no upload when gitleaks errors"

echo "== case 14: gitleaks exit 0 -> proceeds to gcloud (python scan not used) =="
fake_gitleaks 0
run_gl "$T/allowed/content_3" --repo r --slug s
assert_eq "$RC" "0" "gitleaks clean exit code"
assert_eq "$(uploads)" "1" "uploads when gitleaks is clean"

echo
echo "evidence_push: $PASS passed, $FAIL failed"
(( FAIL == 0 ))
