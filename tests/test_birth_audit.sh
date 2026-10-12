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

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
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

echo
echo "test_birth_audit: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
