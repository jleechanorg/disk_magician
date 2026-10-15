#!/usr/bin/env bash
# test_birth_audit.sh — birth audit, the `diskm govern` tick phase (plan Task 9, spec C7): detection only.
#
# Governed roots are confined to a temp tree: DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE
# (/private/tmp/<repo>/*), TMPDIR ($TMPDIR/*), HOME (~/Documents/Codex/<date>/* and
# ~/.worktrees/*/*). Admit attempts and confirms are written straight into
# admission/events.jsonl in the shape disk_budget.py writes them.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DISKM="$REPO_ROOT/disk_magician.sh"

PASS=0
FAIL=0
ok() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
assert_eq() { if [[ "$1" == "$2" ]]; then ok "$3 (= $2)"; else bad "$3 — expected '$2', got '$1'"; fi; }

T="$(mktemp -d /tmp/dm-birth-audit.XXXXXX)" || { echo "FATAL: could not allocate /tmp fixture root" >&2; exit 2; }
[[ -n "$T" && -d "$T" && ! -L "$T" ]] || { echo "FATAL: invalid fixture root '$T'" >&2; exit 2; }
case "$T" in
  /tmp/dm-birth-audit.*|/private/tmp/dm-birth-audit.*) ;;
  *) echo "FATAL: fixture root not under /tmp: '$T'" >&2; exit 2 ;;
esac
T="$(cd "$T" && pwd -P)" || exit 2
cleanup_birth_audit() {
  case "$T" in
    /tmp/dm-birth-audit.*|/private/tmp/dm-birth-audit.*) chmod -R u+rwx "$T" 2>/dev/null; rm -rf "$T" ;;
  esac
}
trap cleanup_birth_audit EXIT
mkdir -p "$T/bin"
export HOME="$T/home" DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$T/ptmp" TMPDIR="$T/tdir"

fresh() {  # fresh <name>: empty state and empty governed roots
  export DISK_MAGICIAN_STATE_DIR="$T/state.$1"
  rm -rf "${T:?}/ptmp" "${T:?}/tdir" "${T:?}/home"; mkdir -p "$DISK_MAGICIAN_STATE_DIR/admission" "$T/ptmp" "$T/tdir" "$T/home"
}
audit() { bash "$REPO_ROOT/scripts/birth_audit.sh" >/dev/null 2>"$T/audit.err"; }  # a govern phase; section 9 runs it via diskm govern
# b <python expression over the budget.json "births" dict d>
b() { python3 -c 'import json,os,sys;d=json.load(open(os.environ["DISK_MAGICIAN_STATE_DIR"]+"/budget.json"))["births"];print(eval(sys.argv[1]))' "$1" 2>/dev/null; }
leases() { find "$DISK_MAGICIAN_STATE_DIR/worktree_leases" -name '*.json' 2>/dev/null | wc -l | tr -d ' '; }
lease_kinds() { python3 -c 'import json,glob,os;print(",".join(sorted(json.load(open(f))["kind"] for f in glob.glob(os.environ["DISK_MAGICIAN_STATE_DIR"]+"/worktree_leases/*.json"))))'; }
# ev admit <id> <dest> [decision] [ci_job] | ev confirm <id> <dest> [inode-override]
ev() {
  python3 - "$@" <<'PY' >> "$DISK_MAGICIAN_STATE_DIR/admission/events.jsonl"
import json, os, sys, time
kind, aid, dest = sys.argv[1:4]
if kind == "admit":
    print(json.dumps(dict(event="admit", admit_id=aid, at=time.time(), decision=int((sys.argv[4:5] or ["0"])[0]),
                          producer="hook:git-clone:example", dest=dest, ci_job=(sys.argv[5:6] or [None])[0])))
else:
    st = os.stat(dest)
    print(json.dumps(dict(event="admit_confirm", admit_id=aid, at=time.time(), dest=dest, dev=st.st_dev,
                          inode=int(sys.argv[4]) if len(sys.argv) > 4 else st.st_ino)))
PY
}

ev_est() {  # ev_est <id> <dest> <est_bytes>: admit (0/10) with an est_bytes + confirm
  python3 - "$@" <<'PY' >> "$DISK_MAGICIAN_STATE_DIR/admission/events.jsonl"
import json, os, sys, time
aid, dest, est = sys.argv[1:4]
st = os.stat(dest)
print(json.dumps(dict(event="admit", admit_id=aid, at=time.time(), est_bytes=int(est), decision=0,
                      producer="hook:git-clone:example", dest=dest, degraded=None)))
print(json.dumps(dict(event="admit_confirm", admit_id=aid, at=time.time(), dest=dest, dev=st.st_dev, inode=st.st_ino)))
PY
}

# ---- Task 9 size/calibration fixtures: a fixed-budget config and a du stub
# dispatched by basename from $DU_SIZES (<base> <kb>|FAIL|SLEEP).
export DISK_MAGICIAN_CONFIG="$T/config.json" DU_SIZES="$T/du_sizes" DISK_MAGICIAN_DU_BIN="$T/bin/du"
cat > "$DISK_MAGICIAN_CONFIG" <<'JSON'
{"budgets":{"enforcement":"observe","concurrency_margin_gb":10,"classes":{
  "tmp_containers":{"budget_gb":15,"measure":"du","trigger":"overage","act":"tmp_containers","unit_budget_s":30},
  "tmpdir_scratch":{"budget_gb":10,"measure":"df_delta_only","trigger":"zone","act":"tmpdir_scratch","unit_budget_s":30},
  "codex_documents":{"budget_gb":3,"measure":"df_delta_only","trigger":"zone","act":"codex_documents","unit_budget_s":30},
  "worktrees":{"budget_gb":35,"measure":"du","trigger":"overage","act":"worktree_reap_remove","unit_budget_s":60}}}}
JSON
cat > "$DISK_MAGICIAN_DU_BIN" <<'SH'
#!/usr/bin/env bash
p="${@: -1}"; base="$(basename "$p")"
val="$(awk -v b="$base" '$1==b{print $2; exit}' "$DU_SIZES" 2>/dev/null)"
case "$val" in
  FAIL) exit 1 ;;
  SLEEP) sleep 30 ;;
  SLEEPCHILD) sleep 30 & echo "$!" > "$DU_CHILD_PID"; sleep 30 ;;
  *) echo "${val:-1}	$p" ;;
esac
SH
chmod +x "$DISK_MAGICIAN_DU_BIN"
: > "$DU_SIZES"
du_set() { : > "$DU_SIZES"; while (( $# )); do echo "$1 $2" >> "$DU_SIZES"; shift 2; done; }
bg() { python3 -c 'import json,os,sys;g=json.load(open(os.environ["DISK_MAGICIAN_STATE_DIR"]+"/admission/births.json"))["gens"];x=[v for v in g.values() if os.path.basename(v["path"])==sys.argv[1]][0];print(eval(sys.argv[2]))' "$1" "$2"; }
pending() { python3 -c 'import json,os,sys;print(json.load(open(os.environ["DISK_MAGICIAN_STATE_DIR"]+"/admission/estimates.pending.json"))["producers"].get(sys.argv[1],"MISSING"))' "$1"; }
largest() { python3 -c 'import json,os,sys;print(json.load(open(os.environ["DISK_MAGICIAN_STATE_DIR"]+"/admission/births.json")).get("largest_bytes",{}).get(sys.argv[1],0))' "$1"; }

echo "== 1. unleased fixtures: admitted by confirm, bypass per class, foreign, adoption, idempotent, nothing deleted"
fresh main
mkdir -p "$T/ptmp/r/advice-src-x" "$T/tdir/advice-primary-pair-abc/.git" "$T/tdir/com.apple.foo" \
  "$HOME/Documents/Codex/2026-10-11/task-1" "$T/ptmp/r/confirmed"
echo data > "$T/ptmp/r/confirmed/f"
ev admit a1 "$T/ptmp/r/confirmed"; ev confirm a1 "$T/ptmp/r/confirmed"
audit; rc=$?
assert_eq "$rc" 0 "audit rc"
assert_eq "$(b 'd["admitted"]')" 1 "confirmed entry is an admitted birth"
assert_eq "$(b 'd["bypass"]["tmp_containers"]["births"]')" 1 "bypass.tmp_containers.births"
assert_eq "$(b 'd["bypass"]["tmpdir_scratch"]["births"]')" 1 "bypass.tmpdir_scratch.births"
assert_eq "$(b 'd["bypass"]["codex_documents"]["births"]')" 1 "bypass.codex_documents.births"
assert_eq "$(b 'd["foreign"]')" 1 "foreign"
assert_eq "$(leases)" 3 "three adopted leases (none for foreign or the admitted entry)"
assert_eq "$(lease_kinds)" "scratch,scratch,scratch" "adopted lease kind"
python3 -c 'import json,os,sys
g=json.load(open(os.environ["DISK_MAGICIAN_STATE_DIR"]+"/admission/births.json"))["gens"].values()
a=[x for x in g if x["status"]=="admitted"][0]
sys.exit(0 if a["producer"]=="hook:git-clone:example" else 1)' \
  && ok "admitted birth producer recorded" || bad "admitted birth producer recorded"
assert_eq "$(b 'd["coverage"]')" "births that persist >= one tick" "coverage statement"
audit
assert_eq "$(b 'd["admitted"]'),$(b 'sum(v["births"] for v in d["bypass"].values())'),$(b 'd["foreign"]'),$(leases)" "1,3,1,3" "second audit adds nothing"
n=0; for p in "$T/ptmp/r/advice-src-x" "$T/tdir/advice-primary-pair-abc" "$T/tdir/com.apple.foo" \
  "$HOME/Documents/Codex/2026-10-11/task-1" "$T/ptmp/r/confirmed/f"; do [[ -e "$p" ]] && n=$((n + 1)); done
assert_eq "$n" 5 "every fixture still exists"

echo "== 2. TMPDIR unset -> getconf DARWIN_USER_TEMP_DIR"
fresh getconf
mkdir -p "$T/utmp/advice-y"
printf '#!/bin/sh\n[ "$1" = DARWIN_USER_TEMP_DIR ] && echo "%s/utmp/"\n' "$T" > "$T/bin/getconf"; chmod +x "$T/bin/getconf"
(unset TMPDIR; PATH="$T/bin:$PATH" audit)
assert_eq "$(b 'd["bypass"]["tmpdir_scratch"]["births"]')" 1 "entry under the getconf root counted"

echo "== 3. birth identity: repeats, spellings, recreate"
fresh ident
mkdir -p "$T/ptmp/r/x" "$T/ptmp/r/z"; ln -s "$T/ptmp/r" "$T/rlink"
ev admit a1 "$T/ptmp/r/x"; ev confirm a1 "$T/ptmp/r/x"
ev admit a2 "$T/ptmp/r/x"; ev confirm a2 "$T/ptmp/r/x"
ev admit h1 "$T/ptmp/r/../r/z"; ev admit s1 "$T/rlink/z"; ev confirm s1 "$T/rlink/z"
audit
assert_eq "$(b 'd["admitted"]'),$(b 'd["bypass"]["tmp_containers"]["births"]')" "2,0" "two confirmed attempts + realpath-equal spellings -> one birth each"
rmdir "$T/ptmp/r/x"; mkdir "$T/ptmp/r/x"
audit
assert_eq "$(b 'd["admitted"]'),$(b 'd["bypass"]["tmp_containers"]["births"]')" "2,1" "recreate with no new attempt -> bypass birth"
assert_eq "$(leases)" 0 "a destination with an attempt is not adopted"

echo "== 4. failure then foreign create; inode mismatch; failed && chain; transient tree"
fresh fail
ev admit a1 "$T/ptmp/r/x"
mkdir -p "$T/ptmp/r/x" "$T/ptmp/r/w"
ev admit a2 "$T/ptmp/r/w"; ev confirm a2 "$T/ptmp/r/w" 999999999
ev admit a3 "$T/ptmp/r/c1"; ev admit a4 "$T/ptmp/r/c2"
audit
assert_eq "$(b 'd["bypass"]["tmp_containers"]["births"]'),$(b 'd["admitted"]')" "2,0" "match_unconfirmed and wrong-inode confirm are bypass"
python3 -c 'import json,os,sys
g=json.load(open(os.environ["DISK_MAGICIAN_STATE_DIR"]+"/admission/births.json"))["gens"].values()
sys.exit(0 if sorted(x["match"] for x in g)==["match_unconfirmed","match_unconfirmed"] else 1)' \
  && ok "both labelled match_unconfirmed" || bad "both labelled match_unconfirmed"
assert_eq "$(b 'd["attempt_unconfirmed"]')" 2 "never-sighted attempts are attempt_unconfirmed, not births"
mkdir "$T/ptmp/r/gone"; rmdir "$T/ptmp/r/gone"
audit
assert_eq "$(b 'sum(v["births"] for v in d["bypass"].values())+d["admitted"]')" 2 "tree created and deleted between audits -> zero births"

echo "== 5. CI attempts stay out of births"
fresh ci
ev admit c1 "$T/ci-ws/a" 0 run-1-1-build; ev admit c2 "$T/ci-ws/a" 0 run-1-1-build
mkdir -p "$T/ptmp/r/ci-dest"; ev admit c3 "$T/ptmp/r/ci-dest" 0 run-2-1-test
audit
assert_eq "$(b 'd["ci_admission"]["jobs"]')" 2 "ci_admission counts distinct ci_job"
assert_eq "$(b 'd["admitted"]'),$(b 'd["bypass"]["tmp_containers"]["births"]')" "0,1" "CI dest sighted without confirm -> one bypass filesystem birth"
assert_eq "$(b 'd["attempt_unconfirmed"]')" 0 "CI attempts are never attempt_unconfirmed"

echo "== 6. births ratio"
fresh ratio
for i in $(seq 1 100); do ev admit "c$i" "$T/ci/$i" 0 "job-$i"; done
for i in $(seq 1 10); do mkdir -p "$T/ptmp/r/b$i"; done
audit
assert_eq "$(b 'd["ratio"]'),$(b 'd["slo_ok"]')" "1.0,False" "100 CI jobs + 10 bypass -> 100%, fails"
fresh ratio2
for i in $(seq 1 10); do mkdir -p "$T/ptmp/r/b$i"; done
for i in $(seq 1 40); do mkdir -p "$T/ptmp/r/a$i"; ev admit "a$i" "$T/ptmp/r/a$i"; ev confirm "a$i" "$T/ptmp/r/a$i"; done
for i in $(seq 1 60); do ev admit "u$i" "$T/ptmp/r/u$i"; done
audit
assert_eq "$(b 'd["ratio"]'),$(b 'd["slo_ok"]'),$(b 'd["attempt_unconfirmed"]')" "0.2,False,60" "10 bypass + 40 admitted + 60 unconfirmed -> 20%, fails"

echo "== 7. nested evidence"
fresh evidence
mkdir -p "$T/ptmp/r/evidence/p-20261011T000000Z" "$T/ptmp/r/evidence/q"
ev admit e1 "$T/ptmp/r/evidence/p-20261011T000000Z"; ev confirm e1 "$T/ptmp/r/evidence/p-20261011T000000Z"
audit
assert_eq "$(b 'd["admitted"]'),$(b 'd["bypass"]["tmp_containers"]["births"]')" "1,1" "evidence child admitted, unattempted child bypass, container never a birth"

echo "== 8. entries born before the audit window are preexisting, not births"
fresh pre
mkdir -p "$T/ptmp/r/old"
python3 -c 'import json,os,time;json.dump(dict(since=time.time()+100,gens={}),open(os.environ["DISK_MAGICIAN_STATE_DIR"]+"/admission/births.json","w"))'
audit
assert_eq "$(b 'sum(v["births"] for v in d["bypass"].values())'),$(leases)" "0,0" "preexisting entry: no birth, no lease"

echo "== 9. govern tick runs the audit"
fresh govern
mkdir -p "$T/ptmp/r/g1"
printf '#!/bin/sh\necho "Filesystem 1024-blocks Used Available Capacity Mounted"\necho "/dev/disk3s5 999999999 1 %s 1%% /"\n' \
  "$((150 * 1024 * 1024))" > "$T/bin/df"; chmod +x "$T/bin/df"
DISK_MAGICIAN_DF_BIN="$T/bin/df" "$DISKM" govern --mode observe >/dev/null 2>&1
assert_eq "$(b 'd["bypass"]["tmp_containers"]["births"]')" 1 "govern wrote births into budget.json"

echo "== 10. size measurement, pending-only calibration and the default floor"
fresh size
printf '{"producers":{"hook:git-clone:example":9.9}}' > "$DISK_MAGICIAN_STATE_DIR/admission/estimates.json"
v=(); for i in $(seq -w 1 20); do mkdir -p "$T/ptmp/r/s$i"; ev admit "s$i" "$T/ptmp/r/s$i"; ev confirm "s$i" "$T/ptmp/r/s$i"; v+=("s$i" 3145728); done
du_set "${v[@]}"
audit
assert_eq "$(pending hook:git-clone:example)" "3.75" "20 measured admitted births at 3 GiB -> 1.25 x p95 = 3.75 GiB pending"
assert_eq "$(cat "$DISK_MAGICIAN_STATE_DIR/admission/estimates.json")" '{"producers":{"hook:git-clone:example":9.9}}' "effective estimates untouched by calibration"
assert_eq "$(bg s01 'x["charge"]'),$(bg s01 'x["bytes"]')" "measured,3221225472" "admitted birth measured (3 GiB)"
assert_eq "$(b 'd["bytes"]["measured"] > 0 and d["bytes"]["estimate"] is True')" "True" "measured bytes labelled estimate"
assert_eq "$(largest tmp_containers)" "3221225472" "class largest measured birth recorded"
fresh default
for i in 1 2 3 4 5; do mkdir -p "$T/ptmp/r/d$i"; ev admit "d$i" "$T/ptmp/r/d$i"; ev confirm "d$i" "$T/ptmp/r/d$i"; done
du_set d1 3145728 d2 3145728 d3 3145728 d4 3145728 d5 3145728
audit
assert_eq "$(pending hook:git-clone:example)" "2.0" "fewer than 20 measured -> documented default (2.0 GiB)"

echo "== 11. unknown size charged estimate, retried, replaced; largest raises the charge"
fresh unknown
mkdir -p "$T/ptmp/r/u1"; du_set u1 FAIL
audit
assert_eq "$(bg u1 'x["charge"]')" "estimate" "failed du -> estimate"
assert_eq "$(bg u1 'x["estimate_bytes"]')" "$((15 * 1024 * 1024 * 1024))" "charged max(class budget 15 GiB, largest 0)"
assert_eq "$(bg u1 'x["unknown_retries"]')" "1" "failed attempt counted for retry"
assert_eq "$(b 'd["bytes"]["unknown"]')" "1" "bytes_unknown counted"
du_set u1 1024; audit
assert_eq "$(bg u1 'x["charge"]'),$(bg u1 'x["bytes"]'),$(bg u1 'x["unknown_retries"]')" "measured,1048576,0" "replaced when known"
fresh retry
mkdir -p "$T/ptmp/r/h1"; du_set h1 FAIL
for _ in 1 2 3 4 5 6; do audit; done
assert_eq "$(bg h1 'x["unknown_retries"]')" "4" "retried on the next three audits, then left as an estimate"
fresh largest
mkdir -p "$T/ptmp/r/abig" "$T/ptmp/r/bfail" "$T/ptmp/r/cfail"; du_set abig 47185920 bfail FAIL cfail FAIL
audit
assert_eq "$(largest tmp_containers)" "48318382080" "a measured 45 GiB birth becomes the class largest"
assert_eq "$(bg bfail 'x["estimate_bytes"]'),$(bg cfail 'x["estimate_bytes"]')" "48318382080,48318382080" "later unknowns charged the raised 45 GiB"

echo "== 12. audit du budget stops and charges estimates without consuming a failed retry"
fresh budget
mkdir -p "$T/ptmp/r/a1" "$T/ptmp/r/a2" "$T/ptmp/r/a3"; du_set a1 SLEEP a2 SLEEP a3 SLEEP
bash "$REPO_ROOT/scripts/birth_audit.sh" --budget-seconds 1 >/dev/null 2>"$T/audit.err"
assert_eq "$(bg a1 'x["charge"]'),$(bg a1 'x["unknown_retries"]')" "estimate,1" "first entry attempted within the 1s budget counts one failed retry"
assert_eq "$(bg a2 'x["charge"]'),$(bg a2 'x["unknown_retries"]'),$(bg a3 'x["unknown_retries"]')" "estimate,0,0" "budget-exhausted births are charged an estimate without a failed retry"
du_set a1 1 a2 1 a3 1; audit
assert_eq "$(bg a1 'x["charge"]'),$(bg a2 'x["charge"]'),$(bg a3 'x["charge"]')" "measured,measured,measured" "next tick finishes the rest"

echo "== 13. births ratio is a 24h window, not the retained registry"
fresh ratio24
mkdir -p "$T/ptmp/r/oldbypass" "$T/ptmp/r/newadm"
python3 - "$T/ptmp/r/oldbypass" "$DISK_MAGICIAN_STATE_DIR" <<'PY'
import json,os,sys,time
p,state=sys.argv[1],sys.argv[2]; st=os.lstat(p); now=time.time()
gen={f"{st.st_dev}:{st.st_ino}":{"path":p,"cls":"tmp_containers","status":"bypass","first_seen":now-2*86400,"producer":None,"match":"none","bytes":None,"charge":None,"estimate_bytes":None,"unknown_retries":0}}
json.dump({"since":now-3*86400,"gens":gen,"largest_bytes":{}},open(os.path.join(state,"admission","births.json"),"w"))
PY
du_set oldbypass 100 newadm 100
ev admit n1 "$T/ptmp/r/newadm"; ev confirm n1 "$T/ptmp/r/newadm"
audit
assert_eq "$(b 'd["ratio"]'),$(b 'd["ratio_window_s"]')" "0.0,86400" "old bypass excluded from the 24h ratio"
assert_eq "$(b 'd["bypass"]["tmp_containers"]["births"]')" "1" "the old bypass is still in the retained registry"
assert_eq "$(b 'd["bypass_24h"]["tmp_containers"]["births"]')" "0" "but not in the 24h window"

echo "== 14. a malformed existing registry fails closed and is preserved"
fresh malformed
mkdir -p "$T/ptmp/r/m1"; du_set m1 FAIL
printf 'not json at all' > "$DISK_MAGICIAN_STATE_DIR/admission/births.json"
audit; rc=$?
[[ "$rc" -ne 0 ]] && ok "malformed registry exits nonzero (rc=$rc)" || bad "malformed registry exits nonzero"
assert_eq "$(cat "$DISK_MAGICIAN_STATE_DIR/admission/births.json")" 'not json at all' "original malformed registry preserved"
[[ -f "$DISK_MAGICIAN_STATE_DIR/budget.json" ]] && bad "no births SLO published for a malformed registry" || ok "no births SLO published for a malformed registry"
fresh malformed2
mkdir -p "$T/ptmp/r/m2"; du_set m2 1
before='{"since":1710000000,"gens":{"bad":"not-a-dict","also":42}}'
printf '%s' "$before" > "$DISK_MAGICIAN_STATE_DIR/admission/births.json"
audit; rc=$?
[[ "$rc" -ne 0 ]] && ok "a bad gens entry exits nonzero (rc=$rc)" || bad "a bad gens entry exits nonzero"
assert_eq "$(cat "$DISK_MAGICIAN_STATE_DIR/admission/births.json")" "$before" "bad-entry registry preserved, never silently dropped"

fresh malformed3
mkdir -p "$T/ptmp/r/m3"; du_set m3 1
python3 - "$T/ptmp/r/m3" "$DISK_MAGICIAN_STATE_DIR" <<'PY'
import json, os, sys, time
p, state = sys.argv[1:3]; st = os.lstat(p); now = time.time()
legacy = {f"{st.st_dev}:{st.st_ino}": dict(path=p, cls="tmp_containers", status="bypass", first_seen=now,
                                          producer=None, match="none", bytes=None, charge=None)}
json.dump({"since": now - 600, "gens": legacy}, open(os.path.join(state, "admission", "births.json"), "w"))
PY
audit; rc=$?
assert_eq "$rc" 0 "a legacy registry migrates without a zero reset"
assert_eq "$(bg m3 'x["status"]')" "bypass" "legacy birth history preserved by stored path"
assert_eq "$(b 'sum(v["births"] for v in d["bypass"].values())')" "1" "migration does not double-count the legacy birth"

echo "== 15. a shared deadline already past charges estimates without du"
fresh deadline
mkdir -p "$T/ptmp/r/w1"; du_set w1 1
bash "$REPO_ROOT/scripts/birth_audit.sh" --deadline-at "$(date +%s)" >/dev/null 2>&1
assert_eq "$(bg w1 'x["charge"]'),$(bg w1 'x["unknown_retries"]')" "estimate,0" "no du attempted, charged an estimate with no failed retry"

echo "== 16. birth identity is path+dev+inode: renaming the same inode is a new bypass birth"
fresh identity2
mkdir -p "$T/ptmp/r/ren"
ev admit r1 "$T/ptmp/r/ren"; ev confirm r1 "$T/ptmp/r/ren"
audit
assert_eq "$(b 'd["admitted"]')" "1" "confirmed generation admitted"
mv "$T/ptmp/r/ren" "$T/ptmp/r/ren2"
audit
assert_eq "$(b 'd["admitted"]'),$(b 'sum(v["births"] for v in d["bypass"].values())')" "1,1" "same inode at a new destination is a new bypass birth"
assert_eq "$(bg ren2 'x["status"]')" "bypass" "the renamed destination is bypass"

echo "== 17. a degraded admission is bypass even with a matching confirm"
fresh degraded
mkdir -p "$T/ptmp/r/deg"
python3 - "$T/ptmp/r/deg" "$DISK_MAGICIAN_STATE_DIR" <<'PY'
import json, os, sys, time
dest, state = sys.argv[1:3]; st = os.stat(dest)
with open(os.path.join(state, "admission", "events.jsonl"), "a") as f:
    f.write(json.dumps(dict(event="admit", admit_id="deg1", at=time.time(), decision=0,
                            producer="hook:git-clone:example", dest=dest, degraded="blind")) + "\n")
    f.write(json.dumps(dict(event="admit_confirm", admit_id="deg1", at=time.time(), dest=dest,
                            dev=st.st_dev, inode=st.st_ino)) + "\n")
PY
audit
assert_eq "$(bg deg 'x["status"]'),$(b 'd["admitted"]'),$(b 'd["bypass"]["tmp_containers"]["births"]')" "bypass,0,1" "degraded admit+confirm is bypass, not admitted"
assert_eq "$(bg deg 'x["match"]'),$(b 'd["attempt_unconfirmed"]')" "match_unconfirmed,0" "the degraded attempt is preserved as a diagnostic, not lost"

echo "== 18. bypass bytes ratio (estimate) and estimate_unbounded"
fresh bytesratio
v=()
for i in $(seq -w 1 90); do d="$T/ptmp/r/ad$i"; mkdir -p "$d"; ev_est "ad$i" "$d" 536870912; v+=("ad$i" 1); done
for i in 1 2 3; do d="$T/ptmp/r/bp$i"; mkdir -p "$d"; v+=("bp$i" 1048576); done
for i in 4 5 6 7 8 9; do d="$T/ptmp/r/bp$i"; mkdir -p "$d"; v+=("bp$i" 0); done
mkdir -p "$T/ptmp/r/unk"; v+=("unk" FAIL)
du_set "${v[@]}"
audit
assert_eq "$(b 'd["admitted_est_bytes"]')" "$((45 * 1024 * 1024 * 1024))" "admitted est_bytes denominator = 45 GiB"
assert_eq "$(b 'd["bypass_bytes_estimate"]')" "$((18 * 1024 * 1024 * 1024))" "bypass bytes estimate = 18 GiB"
python3 -c 'import json,os,sys;d=json.load(open(os.environ["DISK_MAGICIAN_STATE_DIR"]+"/budget.json"))["births"];sys.exit(0 if abs(d["bytes_ratio"]-18/63)<1e-9 else 1)' \
  && ok "bytes ratio = 18/63 = 28.6% (labelled estimate)" || bad "bytes ratio 18/63"
assert_eq "$(b 'd["estimate_unbounded"]')" "False" "1 unknown of 100 births is within the 5% bound"
fresh unbounded
v=()
for i in $(seq 1 94); do d="$T/ptmp/r/y$i"; mkdir -p "$d"; v+=("y$i" 1); done
for i in $(seq 1 6); do d="$T/ptmp/r/x$i"; mkdir -p "$d"; v+=("x$i" FAIL); done
du_set "${v[@]}"
audit
assert_eq "$(b 'd["estimate_unbounded"]')" "True" "6 unknown of 100 births exceeds 5%"

echo "== 19. a du timeout kills descendants, not just the direct child"
fresh duchild
mkdir -p "$T/ptmp/r/k1"; du_set k1 SLEEPCHILD
export DU_CHILD_PID="$T/du_child.pid"; rm -f "$DU_CHILD_PID"
elapsed=$(python3 - "$REPO_ROOT/scripts/birth_audit.sh" "$T/audit.err" <<'PYTIME'
import subprocess, sys, time
with open(sys.argv[2], "w") as errors:
    start = time.monotonic()
    result = subprocess.run(["bash", sys.argv[1], "--budget-seconds", "1"],
                            stdout=subprocess.DEVNULL, stderr=errors, timeout=10)
    print(time.monotonic() - start)
    sys.exit(result.returncode)
PYTIME
) || bad "birth audit completed successfully within outer timeout"
unset DU_CHILD_PID
childpid="$(cat "$T/du_child.pid" 2>/dev/null || true)"
assert_eq "$(bg k1 'x["charge"]')" "estimate" "timed-out du charged an estimate"
[[ -n "$childpid" ]] && ! kill -0 "$childpid" 2>/dev/null && ok "grandchild is gone after the du timeout" || bad "grandchild is gone after the du timeout (pid=$childpid)"
# Allow scheduling overhead while remaining well below the stub's 30s lifetime.
python3 -c 'import sys;sys.exit(0 if float(sys.argv[1]) < 5 else 1)' "$elapsed" \
  && ok "audit returned under 5s (no descendant held the pipe)" || bad "audit took ${elapsed}s (limit 5s)"

echo "== 20. --budget-seconds validation: 0 stays 0, hard cap 120, invalid falls back"
fresh zerobudget
mkdir -p "$T/ptmp/r/z1" "$T/ptmp/r/z2"; du_set z1 1 z2 1
bash "$REPO_ROOT/scripts/birth_audit.sh" --budget-seconds 0 >/dev/null 2>&1
assert_eq "$(bg z1 'x["charge"]'),$(bg z1 'x["unknown_retries"]')" "estimate,0" "budget 0 attempts no du and consumes no retry"
budget_check="$(python3 - "$REPO_ROOT/scripts" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import birth_audit as b
assert b._budget_seconds(0.0, 120.0) == 0.0
assert b._budget_seconds(9999.0, 120.0) == 120.0
assert b._budget_seconds(-1, 120.0) == 120.0
assert b._budget_seconds(float("inf"), 120.0) == 120.0
assert b._budget_seconds(float("nan"), 120.0) == 120.0
assert b._budget_seconds("x", 120.0) == 120.0
print("ok")
PY
)"
assert_eq "$budget_check" "ok" "0 keeps 0, hard cap 120, invalid/inf/nan fall back"

echo "== 21. negative file bytes in an existing registry are preserved unchanged"
fresh negbytes
mkdir -p "$T/ptmp/r/nb"; du_set nb 1
python3 - "$T/ptmp/r/nb" "$DISK_MAGICIAN_STATE_DIR" <<'PY'
import json, os, sys, time
p, state = sys.argv[1:3]; st = os.lstat(p); now = time.time()
rows = {f"{st.st_dev}:{st.st_ino}": dict(path=p, cls="tmp_containers", status="bypass", first_seen=now,
                                        producer=None, match="none", bytes=-5, charge="measured",
                                        estimate_bytes=None, unknown_retries=0)}
json.dump({"since": now - 600, "gens": rows}, open(os.path.join(state, "admission", "births.json"), "w"))
PY
audit; rc=$?
assert_eq "$rc" 0 "a negative bytes value is not treated as malformed"
assert_eq "$(bg nb 'x["bytes"]'),$(bg nb 'x["charge"]')" "-5,measured" "negative file bytes preserved unchanged"

echo
echo "test_birth_audit: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
