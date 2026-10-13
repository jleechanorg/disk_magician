# shellcheck shell=bash
# admit_contract.sh — shared caller-contract cases for `diskm admit` callers
# (spec §7.1 exit-code channel). Source after defining ok/bad/assert_eq.
#
#   run_admit_contract "<caller command with {n} placeholder>" [class]
#
# class defaults to worktrees.
# {n} is replaced by a unique token per case. A stub admit
# (DISK_MAGICIAN_ADMIT_BIN) replays a scripted rc sequence, and a `git` shim
# on PATH stands in for the caller's command: it logs `worktree add` calls to
# $CONTRACT_DIR/cmd.log and exits $CONTRACT_CMD_RC when set (else runs git).

CONTRACT_DIR="$(mktemp -d "${TMPROOT:-${TMPDIR:-/tmp}}/admit_contract.XXXXXX")"
REAL_GIT="$(command -v git)"
mkdir -p "$CONTRACT_DIR/bin"
cat >"$CONTRACT_DIR/bin/admit" <<'EOF'
#!/usr/bin/env bash
d="$(dirname "$0")/.."
echo "$*" >>"$d/admit.log"
n="$(wc -l <"$d/admit.log" | tr -d ' ')"
rc="$(sed -n "${n}p" "$d/admit.rcs")"
echo "admit_id=stub-$n"
exit "${rc:-0}"
EOF
cat >"$CONTRACT_DIR/bin/git" <<EOF
#!/usr/bin/env bash
if [[ " \$* " == *" worktree add "* ]]; then
    echo "\$*" >>"$CONTRACT_DIR/cmd.log"
    [[ -n "\${CONTRACT_CMD_RC:-}" ]] && exit "\$CONTRACT_CMD_RC"
fi
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$CONTRACT_DIR/bin/admit" "$CONTRACT_DIR/bin/git"

# _contract_case <token> <admit rcs (space-separated)> <cmd rc or ""> <caller>
# Sets C_RC, C_ERR (stderr text), C_ADMITS, C_CMDS.
_contract_case() {
    local rcs="$2" cmd_rc="$3" caller="${4//\{n\}/$1}"
    : >"$CONTRACT_DIR/admit.log"; : >"$CONTRACT_DIR/cmd.log"
    tr ' ' '\n' <<<"$rcs" >"$CONTRACT_DIR/admit.rcs"
    PATH="$CONTRACT_DIR/bin:$PATH" DISK_MAGICIAN_ADMIT_BIN="$CONTRACT_DIR/bin/admit" \
        DISK_MAGICIAN_ADMIT_RETRY_S=0 CONTRACT_CMD_RC="$cmd_rc" \
        bash -c "$caller" >/dev/null 2>"$CONTRACT_DIR/err"
    C_RC=$?
    C_ERR="$(cat "$CONTRACT_DIR/err")"
    C_ADMITS="$(wc -l <"$CONTRACT_DIR/admit.log" | tr -d ' ')"
    C_CMDS="$(wc -l <"$CONTRACT_DIR/cmd.log" | tr -d ' ')"
}

_refused_line() { grep -q "disk-admission: refused class=$1 rc=$2" <<<"$C_ERR"; }

run_admit_contract() {
    local caller="$1" cls="${2:-worktrees}"
    echo "== contract: admit 0 -> command runs, caller rc 0 =="
    _contract_case c0 "0" "" "$caller"
    assert_eq "$C_RC" "0" "rc"; assert_eq "$C_CMDS" "1" "command ran once"
    grep -q -- "--class $cls" "$CONTRACT_DIR/admit.log" && ok "admit got --class" || bad "admit args: $(cat "$CONTRACT_DIR/admit.log")"

    echo "== contract: admit 10 -> warn, command runs =="
    _contract_case c10 "10" "" "$caller"
    assert_eq "$C_RC" "0" "rc"; assert_eq "$C_CMDS" "1" "command ran once"
    grep -q "disk-admission: warn" <<<"$C_ERR" && ok "stderr warns" || bad "no warn line: $C_ERR"

    echo "== contract: admit 75 -> caller 75, command never started =="
    _contract_case c75 "75" "" "$caller"
    assert_eq "$C_RC" "75" "rc"; assert_eq "$C_CMDS" "0" "command never ran"
    _refused_line "$cls" 75 && ok "refused line rc=75" || bad "refused line missing: $C_ERR"

    echo "== contract: admit 76 then 0 -> one retry, command runs =="
    _contract_case c760 "76 0" "" "$caller"
    assert_eq "$C_RC" "0" "rc"; assert_eq "$C_ADMITS" "2" "admit called twice"; assert_eq "$C_CMDS" "1" "command ran once"

    echo "== contract: admit 76 twice -> caller 75, no third try =="
    _contract_case c7676 "76 76 0" "" "$caller"
    assert_eq "$C_RC" "75" "rc"; assert_eq "$C_ADMITS" "2" "admit called exactly twice"; assert_eq "$C_CMDS" "0" "command never ran"
    _refused_line "$cls" 76 && ok "refused line rc=76" || bad "refused line missing: $C_ERR"

    echo "== contract: unexpected admit rc 3 -> admission_degraded, command runs =="
    _contract_case cx "3" "" "$caller"
    assert_eq "$C_RC" "0" "rc"; assert_eq "$C_CMDS" "1" "command ran once"
    grep -q "admission_degraded:caller" <<<"$C_ERR" && ok "degraded logged" || bad "no degraded line: $C_ERR"

    echo "== contract: admit 0, command exits 3 -> caller exits 3 =="
    _contract_case ce3 "0" 3 "$caller"
    assert_eq "$C_RC" "3" "rc is the command's"; assert_eq "$C_ADMITS" "1" "no retry after the command started"

    echo "== contract: admit 0, command exits 75 -> 75 without a refused line =="
    _contract_case ce75 "0" 75 "$caller"
    assert_eq "$C_RC" "75" "rc is the command's"
    grep -q "disk-admission: refused" <<<"$C_ERR" && bad "refused line on a command failure" || ok "no refused line"
}
