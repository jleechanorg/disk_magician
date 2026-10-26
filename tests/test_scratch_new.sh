#!/usr/bin/env bash
# test_scratch_new.sh — `diskm scratch-new` (plan Task 6, spec C3).
# Everything lives in a private temp dir: HOME, the worktree root, the
# evidence root and the state dir. Admission is stubbed via
# DISK_MAGICIAN_ADMIT_BIN except for one case that runs the real `diskm admit`
# against a fake df.
set -uo pipefail
export DISK_MAGICIAN_ADMIT_RETRY_S=0

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DISKM="$REPO_ROOT/disk_magician.sh"
PASS=0 FAIL=0
ok() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
assert_eq() { if [[ "$1" == "$2" ]]; then ok "$3 (= $2)"; else bad "$3 — expected '$2', got '$1'"; fi; }
assert_contains() { if [[ "$1" == *"$2"* ]]; then ok "$3"; else bad "$3 — missing '$2' in: $1"; fi; }

T="$(mktemp -d /tmp/dm-scratch-new.XXXXXX)" || exit 1
[[ "$T" == /tmp/dm-scratch-new.* && -d "$T" && ! -L "$T" ]] || exit 1
T="$(cd -- "$T" && pwd -P)" || exit 1
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/home" "$T/bin" "$T/tmp" "$T/bucket" "$T/state" "$T/elsewhere"
export HOME="$T/home" STANDARD_WORKTREE_ROOT="$T/home/.worktrees" EVIDENCE_TMP_ROOT="$T/tmp"
export DISK_MAGICIAN_STATE_DIR="$T/state" EVIDENCE_GCS_PREFIX="gs://bkt/ev"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

git init -q "$T/myrepo" && git -C "$T/myrepo" commit -q --allow-empty -m init
git -C "$T/myrepo" remote add origin https://example.invalid/o/myrepo.git
SHA="$(git -C "$T/myrepo" rev-parse HEAD)"

# Fake admit: logs argv, exits with the next rc from $T/admit_rcs (one per line).
cat > "$T/bin/admit" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$T/admit.log"
rc="\$(head -n 1 "$T/admit_rcs")"; tail -n +2 "$T/admit_rcs" > "$T/admit_rcs.n"; mv "$T/admit_rcs.n" "$T/admit_rcs"
echo admit_id=fake
exit "\${rc:-0}"
EOF
chmod +x "$T/bin/admit"
export DISK_MAGICIAN_ADMIT_BIN="$T/bin/admit"

# run <admit rcs> <args...> — sets OUT (stdout), ERR, RC.
run() {
    printf '%s\n' $1 > "$T/admit_rcs"; : > "$T/admit.log"; shift
    OUT="$(bash "$DISKM" scratch-new "$@" 2>"$T/err")"; RC=$?; ERR="$(cat "$T/err")"
}
admits() { wc -l < "$T/admit.log" | tr -d ' '; }
lease_field() {  # lease_field <path> <key>
    (source "$REPO_ROOT/scripts/lib/worktree_lease.sh"; _lease_get "$(lease_path_for "$1")" "$2")
}
wt_count() { find "$STANDARD_WORKTREE_ROOT/myrepo" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' '; }

echo "== admit contract: 0 / 10 / unexpected rc run the command; 75 refuses; 76 retries once =="
for rc in 0 10 3; do
    run "$rc" "$T/myrepo" "c$rc" --detach HEAD
    assert_eq "$RC" 0 "admit rc $rc: exit 0"
    [[ -d "$OUT" && -f "$OUT/.git" ]] && ok "admit rc $rc: detached worktree created" || bad "admit rc $rc: no worktree at '$OUT'"
done
assert_contains "$ERR" "admission_degraded:caller" "unexpected admit rc counted as degraded"
before="$(wt_count)"
run 75 "$T/myrepo" refused --detach HEAD
assert_eq "$RC" 75 "admit 75: exit 75"
assert_contains "$ERR" "disk-admission: refused" "admit 75: refusal line"
assert_eq "$(wt_count)" "$before" "admit 75: nothing created"
run "76 0" "$T/myrepo" retry --detach HEAD
assert_eq "$RC" 0 "admit 76 then 0: exit 0"
assert_eq "$(admits)" 2 "admit 76: retried exactly once"
run "76 76 0" "$T/myrepo" retry2 --detach HEAD
assert_eq "$RC" 75 "admit 76 twice: exit 75"
assert_eq "$(admits)" 2 "admit 76 twice: no third call"
assert_eq "$(wt_count)" "$((before + 1))" "admit 76 twice: nothing created"
run 0 "$T/myrepo" badsha --detach deadbeefdeadbeef
if [[ "$RC" != 0 && "$RC" != 75 ]]; then ok "command failure keeps its own rc ($RC)"; else bad "command failure rc $RC"; fi

echo "== detached scratch worktree: path, .git file, lease kind + source =="
run 0 "$T/myrepo" gate-prep --detach HEAD --est-gb 3
assert_eq "$RC" 0 "exit 0"
assert_contains "$OUT" "$STANDARD_WORKTREE_ROOT/myrepo/scratch-gate-prep-" "path under ~/.worktrees/<repo>/scratch-<purpose>-<ts>"
assert_eq "$(git -C "$OUT" rev-parse HEAD)" "$SHA" "checked out at the sha"
assert_eq "$(stat -c %a "$OUT")" 700 "new scratch directory is mode 0700"
assert_eq "$(git -C "$OUT" symbolic-ref -q HEAD || echo detached)" detached "HEAD is detached"
assert_eq "$(lease_field "$OUT" kind)" scratch "lease kind"
assert_eq "$(lease_field "$OUT" source)" "git:https://example.invalid/o/myrepo.git@$SHA" "lease source = repo URL + sha"
assert_contains "$(cat "$T/admit.log")" "--class worktrees --est-gb 3" "admit class worktrees with --est-gb"
assert_eq "$(lease_field "$OUT" producer)" scratch-new "default producer"
# The production call shape is command substitution; the caller survives while
# the short-lived CLI process exits, so the lease must retain the caller/runtime
# owner rather than the CLI PID. Explicit owner PID covers detached workers.
echo "== command-substitution caller and explicit detached owner =="
sleep 300 & DETACHED_OWNER=$!
OUT="$(bash "$DISKM" scratch-new "$T/myrepo" detached-owner --detach HEAD --owner-pid "$DETACHED_OWNER" 2>"$T/err")"; RC=$?
if [[ "$RC" != 0 ]]; then cat "$T/err" >&2; fi
assert_eq "$RC" 0 "explicit detached owner scratch-new succeeds"
assert_eq "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(any(int(o.get("pid",-1)) == int(sys.argv[2]) for o in d.get("owners",[])))' "$(python3 -c 'import json,glob,os,sys; print(next(p for p in glob.glob(os.path.join(os.environ["DISK_MAGICIAN_STATE_DIR"],"worktree_leases","*.json")) if json.load(open(p)).get("path")==sys.argv[1]))' "$OUT")" "$DETACHED_OWNER")" True "explicit detached owner is persisted"
kill "$DETACHED_OWNER" 2>/dev/null || true

echo "== lease failure: scratch-new fails closed without handing out path =="
OUT="$(DISK_MAGICIAN_LEASE_TTL_HOURS=bad bash "$DISKM" scratch-new "$T/myrepo" lease-fail --detach HEAD 2>"$T/err")"; RC=$?
[[ "$RC" != 0 ]] && ok "lease failure is non-zero" || bad "lease failure returned success"
ERR="$(cat "$T/err")"
assert_eq "$OUT" "" "lease failure emits no path"
assert_contains "$ERR" "lease write failed" "lease failure diagnosed"
LEASE_FAIL_PATH="$(find "$STANDARD_WORKTREE_ROOT/myrepo" -mindepth 1 -maxdepth 1 -type d -name 'scratch-lease-fail-*' | head -n 1)"
[[ -n "$LEASE_FAIL_PATH" && -d "$LEASE_FAIL_PATH" ]] && ok "failed lease leaves created worktree available for recovery" || bad "failed lease worktree missing"

echo "== bad purpose / escaping root -> rc 2, nothing admitted =="
for p in ../x Bad_Purpose "" "$(printf 'a%.0s' {1..41})"; do
    run 0 "$T/myrepo" "$p" --detach HEAD
    assert_eq "$RC" 2 "purpose '$p' rejected"
done
assert_eq "$(admits)" 0 "rejected purpose never admitted"
mkdir -p "$STANDARD_WORKTREE_ROOT" && ln -s "$T/elsewhere" "$STANDARD_WORKTREE_ROOT/linked"
git clone -q "$T/myrepo" "$T/linked"
run 0 "$T/linked" esc --detach HEAD
assert_eq "$RC" 2 "repo dir symlinked outside the root -> rc 2"
assert_eq "$(find "$T/elsewhere" -mindepth 1 | wc -l | tr -d ' ')" 0 "nothing created outside the root"

echo "== --kind evidence: dir under the evidence root, evidence lease, tmp_containers class =="
run 0 "$T/myrepo" ui-proof --kind evidence
assert_eq "$RC" 0 "exit 0"
EV="$OUT"
assert_contains "$EV" "$T/tmp/myrepo/evidence/ui-proof-" "evidence path"
[[ -d "$EV" ]] && ok "evidence dir exists" || bad "evidence dir missing"
assert_eq "$(lease_field "$EV" kind)" evidence "evidence lease kind"
assert_contains "$(cat "$T/admit.log")" "--class tmp_containers" "admit class tmp_containers"

echo "== real diskm admit (observe, fake df) admits and logs one event =="
cat > "$T/bin/df" <<'EOF'
#!/usr/bin/env bash
echo "Filesystem 1024-blocks Used Available Capacity Mounted"
echo "/dev/x 1000000000 1 900000000 1% /"
EOF
chmod +x "$T/bin/df"
OUT="$(env -u DISK_MAGICIAN_ADMIT_BIN DISK_MAGICIAN_DF_BIN="$T/bin/df" bash "$DISKM" scratch-new "$T/myrepo" real --detach HEAD 2>"$T/err")"; RC=$?
assert_eq "$RC" 0 "real admit: exit 0"
[[ -d "$OUT" && "$(printf '%s' "$OUT" | wc -l | tr -d ' ')" == 0 ]] && ok "real admit: stdout is exactly the path" || bad "real admit: stdout '$OUT'"
assert_eq "$(python3 -c 'import json,sys; print(sum(e.get("event") == "admit" and e.get("producer") == "scratch-new:myrepo" for e in map(json.loads, open(sys.argv[1]))))' "$T/state/admission/events.jsonl")" 1 "one admit event"

echo "== evidence-push upload manifest =="
# Fake gcloud rsync copies the tree into $T/bucket/<repo>/<slug>/; knobs:
# SKIP=<file> not uploaded, PRE=<file> rewritten after hashing and before upload,
# POST=<file> rewritten locally after upload.
cat > "$T/bin/gcloud" <<EOF
#!/usr/bin/env bash
[[ "\$1 \$2" == "storage rsync" ]] || exit 9
src="\$4" dst="$T/bucket/\${5#gs://bkt/ev/}"
[[ -n "\${PRE:-}" ]] && echo changed > "\$src/\$PRE"
mkdir -p "\$dst" && (cd "\$src" && find . -type f ! -name "\${SKIP:-/}" -exec sh -c 'mkdir -p "\$2/\$(dirname "\$1")" && cp "\$1" "\$2/\$1"' _ {} "\$dst" \;)
[[ -n "\${POST:-}" ]] && echo later > "\$src/\$POST"
exit 0
EOF
cat > "$T/bin/gcs-stat" <<EOF
#!/usr/bin/env bash
[[ -n "\${STAT_SLEEP:-}" ]] && sleep "\$STAT_SLEEP"
[[ -n "\${STAT_FAIL:-}" ]] && exit 1
python3 - "$T/bucket/\${1#gs://bkt/ev/}" <<'PY'
import base64, hashlib, json, sys
try: data = open(sys.argv[1], "rb").read()
except OSError: sys.exit(1)
print(json.dumps({"md5_hash": base64.b64encode(hashlib.md5(data).digest()).decode(), "generation": "1700", "size": len(data)}))
PY
EOF
chmod +x "$T/bin/gcloud" "$T/bin/gcs-stat"
export DISK_MAGICIAN_STAT_BIN="$T/bin/gcs-stat"
# The cloud-object fake must never be reachable as `stat`: the lease library
# shells out to the real platform-specific stat birth-time call for the git admin dir. Probe that
# under the same PATH evidence-push uses. A shadowing `stat` loses the birth.
echo "== lease birth uses the OS stat, not the cloud-object fake =="
git -C "$T/myrepo" worktree add -q -b birth-probe "$T/birth-wt" HEAD 2>/dev/null || bad "admin-birth fixture setup"
birth_info="$(PATH="$T/bin:/usr/bin:/bin" bash -c 'source "$1"; _lease_admin_info "$2"' _ "$REPO_ROOT/scripts/lib/worktree_lease.sh" "$T/birth-wt")"
assert_contains "$birth_info" "birth-wt" "OS stat reaches the git admin dir"
[[ "$(printf '%s' "$birth_info" | cut -f2)" =~ ^[1-9][0-9]*$ ]] && ok "admin birth is a positive epoch under the evidence PATH" || bad "admin birth lost to a PATH stat shadow: '$birth_info'"
manifest() { (source "$REPO_ROOT/scripts/lib/worktree_lease.sh"; python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1])).get("upload_manifest")))' "$(lease_path_for "$1")"); }
push() {  # push <dir> <slug> [ENV=V...]
    local d="$1" s="$2"; shift 2
    OUT="$(env "$@" PATH="$T/bin:/usr/bin:/bin" bash "$DISKM" evidence-push "$d" --repo myrepo --slug "$s" 2>"$T/err")"; RC=$?; ERR="$(cat "$T/err")"
}
mkev() { run 0 "$T/myrepo" "$1" --kind evidence; echo report > "$OUT/report.md"; mkdir -p "$OUT/sub"; echo shot > "$OUT/sub/a.png"; EV="$OUT"; }

mkev full; push "$EV" full
assert_eq "$RC" 0 "verified upload: exit 0"
assert_eq "$(lease_field "$EV" published)" True "published"
[[ -n "$(lease_field "$EV" published_at)" && -n "$(lease_field "$EV" verified_at)" ]] && ok "published_at + verified_at set" || bad "published_at/verified_at missing"
assert_eq "$(lease_field "$EV" kind)" evidence "kind preserved"
M="$(manifest "$EV")"
assert_eq "$(python3 -c 'import json,sys; m=json.loads(sys.argv[1]); print(len(m), sorted(m[0]))' "$M")" \
    "2 ['crc32c', 'generation', 'md5', 'object', 'path', 'sha256', 'size']" "one entry per file with every key"
assert_contains "$M" '"object": "gs://bkt/ev/myrepo/full/sub/a.png"' "object name"
assert_contains "$M" '"generation": "1700"' "generation"

mkev subset; push "$EV" subset SKIP=report.md
if [[ "$RC" != 0 ]]; then ok "subset upload: non-zero ($RC)"; else bad "subset upload exited 0"; fi
assert_eq "$(lease_field "$EV" published_at)" "" "subset upload: no published_at"
assert_contains "$ERR" "evidence_publish_unverified" "subset upload logged"

mkev mutpre; push "$EV" mutpre PRE=report.md
assert_eq "$(lease_field "$EV" published_at)" "" "rewritten before upload: not published"
assert_contains "$ERR" "evidence_publish_unverified" "rewritten before upload logged"

mkev mutpost; ORIG="$(shasum -a 256 "$EV/report.md" | cut -d' ' -f1)"; push "$EV" mutpost POST=report.md
assert_eq "$RC" 0 "rewritten after upload: exit 0"
M="$(manifest "$EV")"
assert_contains "$M" "\"sha256\": \"$ORIG\"" "entry carries the uploaded hash"
[[ "$(shasum -a 256 "$EV/report.md" | cut -d' ' -f1)" != "$ORIG" ]] && ok "local file no longer matches the manifest" || bad "local file unchanged"

mkev statfail; push "$EV" statfail STAT_FAIL=1
if [[ "$RC" != 0 ]]; then ok "stat failure: non-zero ($RC)"; else bad "stat failure exited 0"; fi
assert_eq "$(lease_field "$EV" published_at)" "" "stat failure: no published_at"
assert_contains "$ERR" "evidence_publish_unverified" "stat failure logged"

mkev statslow; s=$SECONDS; push "$EV" statslow STAT_SLEEP=5 DISK_MAGICIAN_STAT_TIMEOUT=1
if [[ "$RC" != 0 ]]; then ok "stat past timeout: non-zero ($RC)"; else bad "stat timeout exited 0"; fi
(( SECONDS - s < 5 )) && ok "stat timeout bounded" || bad "stat timeout not enforced ($((SECONDS - s))s)"
assert_eq "$(lease_field "$EV" published_at)" "" "stat timeout: no published_at"

echo "== crc32c known vector =="
mkdir -p "$T/vec" && printf 123456789 > "$T/vec/v"
assert_eq "$(python3 "$REPO_ROOT/scripts/evidence_manifest.py" hash "$T/vec" 2>/dev/null | python3 -c 'import json,sys,base64; print(base64.b64decode(json.load(sys.stdin)[0]["crc32c"]).hex())')" e3069283 "crc32c(123456789)"

echo
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
