#!/usr/bin/env bash
# Fail-closed contracts for scripts/lib/worktree_ignored.sh and c14_probe
# secrets(): names that can hold user data or secrets keep a worktree.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/worktree_ignored.sh
source "$REPO_ROOT/scripts/lib/worktree_ignored.sh"
PASS=0; FAIL=0
ok() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null

echo "== ignored_entry_rebuildable: user-data names are not rebuildable =="
mkdir -p "$TMP/wt"
for e in .beads/issues.db .br_recovery/x logs/run.txt .tmp/notes.md .superpowers/s.md .dark-factory/state .codex-worktrees/a/b debug.log; do
  ignored_entry_rebuildable "$TMP/wt" "$e" && bad "$e treated as rebuildable" || ok "$e is user data"
done
for e in node_modules/x/index.js __pycache__/a.pyc .pytest_cache/v; do
  ignored_entry_rebuildable "$TMP/wt" "$e" && ok "$e rebuildable" || bad "$e not rebuildable"
done

echo "== has_ignored_user_data: unresolvable gitdir fails closed =="
mkdir -p "$TMP/orphan"; printf 'gitdir: %s/gone/.git/worktrees/orphan\n' "$TMP" >"$TMP/orphan/.git"
has_ignored_user_data "$TMP/orphan" && ok "orphaned worktree preserved" || bad "orphaned worktree read as no user data"

echo "== has_hidden_state: secret-like names with template-ish suffixes still count =="
for name in credentials.test secrets.dst; do
  r="$TMP/repo-$name"; git init -q "$r"; printf '%s\n' "$name" >"$r/.gitignore"
  git -C "$r" add .gitignore; git -C "$r" -c user.name=t -c user.email=t@e commit -qm i
  printf 'x' >"$r/$name"
  has_hidden_state "$r" && ok "ignored $name keeps the worktree" || bad "ignored $name ignored"
done

echo "== has_hidden_state: vendored source names are not hidden state; real secrets stay (even in dependency dirs) =="
hh() { # <hidden|clean> <relpath> [extra .gitignore line]
  local want="$1" rel="$2" r got
  r="$(mktemp -d "$TMP/hh.XXXXXX")"; git init -q "$r"
  printf 'node_modules/\n__pycache__/\n%s\n' "${3:-}" >"$r/.gitignore"
  git -C "$r" add .gitignore; git -C "$r" -c user.name=t -c user.email=t@e commit -qm i
  mkdir -p "$r/$(dirname "$rel")"; printf 'x' >"$r/$rel"
  if has_hidden_state "$r"; then got=hidden; else got=clean; fi
  [[ "$got" == "$want" ]] && ok "$rel -> $got" || bad "$rel expected $want got $got"
}
for rel in node_modules/pkg/credentials.js node_modules/pkg/credentials.d.ts node_modules/pkg/gcredentials.h \
    node_modules/pkg/credentials.js.map node_modules/pkg/credentials.d.ts.map; do hh clean "$rel"; done
hh clean .env.example '.env.example'
for rel in node_modules/pkg/.env node_modules/pkg/credentials.json node_modules/pkg/credentials \
    node_modules/pkg/deploy.pem __pycache__/id_rsa venv/secrets.toml; do hh hidden "$rel" "venv/"; done
hh clean __pycache__/openrouter_credentials.cpython-312.pyc
r="$(mktemp -d "$TMP/hh.XXXXXX")"; git init -q "$r"; printf 'a' >"$r/f"; git -C "$r" add f
git -C "$r" -c user.name=t -c user.email=t@e commit -qm i; git -C "$r" update-index --skip-worktree f
has_hidden_state "$r" && ok "skip-worktree -> hidden" || bad "skip-worktree not hidden"
has_hidden_state "$TMP/not-a-repo-xyz" && ok "probe failure -> hidden" || bad "probe failure not hidden"

echo "== c14_probe secrets(): only source/template names exempt =="
for rel in credentials.yaml secrets.toml .env.test Build/credentials.json node_modules/p/.env; do
  printf '[{"path":".","name":"wt"},{"path":"%s"}]' "$rel" >"$TMP/inv.json"
  out="$(python3 "$REPO_ROOT/scripts/c14_probe.py" secrets "$TMP/inv.json")"
  [[ "$out" == yes ]] && ok "$rel is secret-like" || bad "$rel -> $out"
done

echo "== _av_secret_like: config/key names and dependency dirs are not exempt =="
(
  # shellcheck source=scripts/lib/artifact_verdict.sh
  source "$REPO_ROOT/scripts/lib/artifact_verdict.sh"
  for rel in credentials.json example/.env node_modules/pkg/.env Build/secrets.json app_credentials.toml; do
    d="$TMP/av-${rel//\//_}"; mkdir -p "$d/$(dirname "$rel")"; printf 'x' >"$d/$rel"
    _av_secret_like "$d" && echo "  PASS: $rel is secret-like" || echo "  FAIL: $rel not secret-like"
  done
) >"$TMP/av.out" 2>&1
cat "$TMP/av.out"
PASS=$((PASS + $(grep -c '  PASS:' "$TMP/av.out"))); FAIL=$((FAIL + $(grep -c '  FAIL:' "$TMP/av.out")))
[[ $(grep -c '  PASS:' "$TMP/av.out") -eq 5 ]] || { echo "  FAIL: artifact_verdict.sh did not load"; FAIL=$((FAIL + 1)); }

for rel in node_modules/p/credentials.js a/gcredentials.h x/credentials.d.ts.map .env.example; do
  printf '[{"path":".","name":"wt"},{"path":"%s"}]' "$rel" >"$TMP/inv.json"
  out="$(python3 "$REPO_ROOT/scripts/c14_probe.py" secrets "$TMP/inv.json")"
  [[ "$out" == no ]] && ok "$rel is not secret-like (probe)" || bad "$rel -> $out (probe)"
done

echo "== parity table: exempt-name, secrets, has_hidden_state (ignored file) agree on every row =="
TABLE="$REPO_ROOT/tests/secret_name_table.tsv"
while IFS=$'\t' read -r want rel; do
  [[ -z "$want" || "$want" == \#* ]] && continue
  exp_ex=no; [[ "$want" == clean ]] && exp_ex=yes
  got_ex="$(python3 "$REPO_ROOT/scripts/c14_probe.py" exempt-name "$rel")"
  [[ "$got_ex" == "$exp_ex" ]] || bad "exempt-name $rel expected $exp_ex got $got_ex"
  printf '[{"path":".","name":"wt"},{"path":"%s"}]' "$rel" >"$TMP/inv.json"
  got_s="$(python3 "$REPO_ROOT/scripts/c14_probe.py" secrets "$TMP/inv.json")"
  exp_s=yes; [[ "$want" == clean ]] && exp_s=no
  [[ "$got_s" == "$exp_s" ]] || bad "secrets $rel expected $exp_s got $got_s"
  r="$(mktemp -d "$TMP/tb.XXXXXX")"; git init -q "$r"; printf '*\n' >"$r/.gitignore"
  git -C "$r" add -f .gitignore; git -C "$r" -c user.name=t -c user.email=t@e commit -qm i
  mkdir -p "$r/$(dirname "$rel")"; printf x >"$r/$rel"
  if has_hidden_state "$r"; then got_h=secret; else got_h=clean; fi
  [[ "$got_h" == "$want" ]] || bad "has_hidden_state $rel expected $want got $got_h"
done <"$TABLE"

echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
