#!/usr/bin/env bash
# test_evict_fileprovider.sh — evict-fileprovider: dispatch, dry-run default, approval gate,
# recency skip, provider-not-ready skip, open-file skip, root guard, deletion logging.
# The FileProvider helper is mocked (macOS-only API); real eviction is verified manually.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0
ok() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

T="$(mktemp -d /tmp/disk-magician-evictfp.XXXXXX)" || exit 2
T="$(cd "$T" && pwd -P)"
trap 'rm -rf -- "${T:?}"' EXIT
export DISK_MAGICIAN_DELETION_LOG="$T/del.log" DM_FILEPROVIDER_ALLOW_ANY_ROOT=1 TMPDIR="$T"

# Mock helper: probe -> READY unless the name contains "pending"; evict -> sparse file of equal size.
cat >"$T/helper.sh" <<'EOF'
#!/usr/bin/env bash
mode="$1"
while IFS= read -r -d '' p; do
  if [[ "$mode" == probe ]]; then
    case "$p" in *pending*) printf 'SKIP:not_uploaded\t%s\n' "$p" ;; *) printf 'READY\t%s\n' "$p" ;; esac
  else
    sz="$(stat -c %s "$p" 2>/dev/null || stat -f %z "$p")"; : >"$p"; truncate -s "$sz" "$p"; printf 'EVICTED\t%s\n' "$p"
  fi
done
EOF
chmod +x "$T/helper.sh"
export DM_FILEPROVIDER_HELPER="$T/helper.sh"

D="$T/cloud"
fixture() {
  rm -rf -- "${D:?}"; mkdir -p "$D/sub"
  head -c 65536 /dev/urandom >"$D/old.bin";          touch -t 202601010000 "$D/old.bin"
  head -c 65536 /dev/urandom >"$D/sub/old2.bin";     touch -t 202601010000 "$D/sub/old2.bin"
  head -c 65536 /dev/urandom >"$D/recent.bin"
  head -c 65536 /dev/urandom >"$D/pending.bin";      touch -t 202601010000 "$D/pending.bin"
  : >"$D/dataless.bin"; truncate -s 65536 "$D/dataless.bin"; touch -t 202601010000 "$D/dataless.bin"
  rm -f "$DISK_MAGICIAN_DELETION_LOG"
}
if stat --version >/dev/null 2>&1; then blocks() { stat -c %b "$1"; }; fsize() { stat -c %s "$1"; }; else blocks() { stat -f %b "$1"; }; fsize() { stat -f %z "$1"; }; fi
SH_=("$ROOT/scripts/evict_fileprovider.sh" --root "$D")

fixture
out="$(bash "${SH_[@]}" 2>&1)"; rc=$?
[[ $rc -eq 0 ]] && ok "dry-run default exits 0" || bad "dry-run rc=$rc: $out"
grep -q '^\[DRY-RUN\]' <<<"$out" && ok "dry-run labelled" || bad "dry-run label missing: $out"
grep -q 'would evict.*: 2 files' <<<"$out" && ok "dry-run counts 2 evictable" || bad "evictable count: $out"
grep -q 'skipped recent.*: 1 files' <<<"$out" && ok "dry-run reports recent skip" || bad "recent skip: $out"
grep -q 'not_uploaded' <<<"$out" && ok "dry-run reports not_uploaded reason" || bad "not_uploaded reason: $out"
[[ "$(blocks "$D/old.bin")" -gt 0 && ! -f "$DISK_MAGICIAN_DELETION_LOG" ]] && ok "dry-run changes nothing, logs nothing" || bad "dry-run mutated state"

fixture
out="$(bash "${SH_[@]}" --clean 2>&1)"; rc=$?
[[ $rc -eq 2 && "$(blocks "$D/old.bin")" -gt 0 ]] && ok "--clean without approval env is refused" || bad "gate rc=$rc: $out"
out="$(FILEPROVIDER_EVICT_APPROVED=0 bash "${SH_[@]}" --clean 2>&1)"; rc=$?
[[ $rc -eq 2 ]] && ok "approval value other than 1 refused" || bad "gate (=0) rc=$rc"

fixture
out="$(FILEPROVIDER_EVICT_APPROVED=1 bash "${SH_[@]}" --clean 2>&1)"; rc=$?
[[ $rc -eq 0 ]] && ok "approved --clean exits 0" || bad "clean rc=$rc: $out"
[[ "$(blocks "$D/old.bin")" -eq 0 && "$(blocks "$D/sub/old2.bin")" -eq 0 ]] && ok "aged uploaded files evicted" || bad "old files not evicted: $out"
[[ "$(fsize "$D/old.bin")" -eq 65536 ]] && ok "logical size preserved" || bad "size changed"
[[ "$(blocks "$D/recent.bin")" -gt 0 ]] && ok "recent file skipped" || bad "recent file evicted"
[[ "$(blocks "$D/pending.bin")" -gt 0 ]] && ok "not-uploaded file skipped" || bad "pending file evicted"
n="$(awk -F'\t' '$2=="evict_fileprovider.sh" && $3=="evict_fileprovider"' "$DISK_MAGICIAN_DELETION_LOG" | wc -l | tr -d ' ')"
[[ "$n" == 2 ]] && grep -q "$D/old.bin" "$DISK_MAGICIAN_DELETION_LOG" && ok "each eviction logged to deletion log" || bad "deletion log: $(cat "$DISK_MAGICIAN_DELETION_LOG" 2>&1)"
awk -F'\t' '$4>0' "$DISK_MAGICIAN_DELETION_LOG" | grep -q . && ok "log records reclaimed KiB" || bad "log kb missing"

fixture
exec 9<"$D/old.bin"
out="$(FILEPROVIDER_EVICT_APPROVED=1 bash "${SH_[@]}" --clean 2>&1)"
exec 9<&-
[[ "$(blocks "$D/old.bin")" -gt 0 && "$(blocks "$D/sub/old2.bin")" -eq 0 ]] && ok "file open by a process is skipped" || bad "open-file skip: $out"

fixture
out="$(bash "${SH_[@]}" --min-age-hours 100000 2>&1)"
grep -q 'would evict.*: 0 files' <<<"$out" && ok "--min-age-hours widens recency skip" || bad "min-age: $out"

out="$(env -u DM_FILEPROVIDER_ALLOW_ANY_ROOT bash "$ROOT/scripts/evict_fileprovider.sh" --root "$D" 2>&1)"; rc=$?
[[ $rc -eq 2 ]] && ok "root outside ~/Library/CloudStorage refused" || bad "root guard rc=$rc"

fixture
out="$(bash "$ROOT/disk_magician.sh" evict-fileprovider --root "$D" 2>&1)"
grep -q '^\[DRY-RUN\]' <<<"$out" && ok "disk_magician.sh dispatches evict-fileprovider" || bad "dispatch: $out"
helpout="$(bash "$ROOT/disk_magician.sh" help 2>&1)"
grep -q 'evict-fileprovider' <<<"$helpout" && ok "help lists evict-fileprovider" || bad "help missing entry"

echo "evict_fileprovider: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
