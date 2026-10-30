#!/usr/bin/env bash
# Non-repo semantics for has_hidden_state.
#
# A directory that is not a git repository has no index, so nothing can be
# assume-unchanged or skip-worktree. Before this change has_hidden_state fail-closed
# on every such directory, which made agent scratch unremovable: 13 of the 14 largest
# /tmp scratch dirs were blocked on 2026-10-29 purely because `git ls-files` failed.
# The fallthrough must still block real secret-like names, and must still fail closed
# when the scan cannot complete.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$REPO_ROOT/scripts/lib/worktree_ignored.sh"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/hs-nonrepo.XXXXXX")" || exit 1
trap 'chmod -R u+rwX "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { echo "  PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

mk() { local d="$TMP/$1"; mkdir -p "$d"; echo "$d"; }

# 1. Ordinary non-repo dir with no secret-like names -> clean
d="$(mk plain)"; echo hello >"$d/notes.txt"; mkdir -p "$d/src"; echo x >"$d/src/app.py"
has_hidden_state "$d" && bad "plain non-repo dir read as hidden" || ok "plain non-repo dir -> clean"

# 2. Real secret-like names still block
d="$(mk withsecrets)"; echo k >"$d/secrets.txt"
has_hidden_state "$d" && ok "non-repo secrets.txt -> hidden" || bad "non-repo secrets.txt read as clean"
d="$(mk withenv)"; echo k >"$d/.env"
has_hidden_state "$d" && ok "non-repo .env -> hidden" || bad "non-repo .env read as clean"
d="$(mk withkey)"; echo k >"$d/server.key"
has_hidden_state "$d" && ok "non-repo server.key -> hidden" || bad "non-repo server.key read as clean"
d="$(mk withcreds)"; echo k >"$d/credentials.py"
has_hidden_state "$d" && ok "non-repo credentials.py (exact stem) -> hidden" || bad "non-repo credentials.py read as clean"
# A compound identifier is code, not secret material: inside a git repo it is tracked
# and never reaches this gate at all, so a non-repo scratch copy must not be blocked by it.
d="$(mk withcompound)"; echo k >"$d/openrouter_credentials.py"
has_hidden_state "$d" && bad "non-repo openrouter_credentials.py treated as secret" || ok "non-repo compound *credentials*.py -> clean"

# 3. Vendored public CA bundle under a dependency dir is exempt (PR #290 semantics)
d="$(mk withca)"; mkdir -p "$d/venv/lib/python3.12/site-packages/pip/_vendor/certifi"
: >"$d/venv/lib/python3.12/site-packages/pip/_vendor/certifi/cacert.pem"
has_hidden_state "$d" && bad "vendored cacert.pem still blocks non-repo dir" || ok "vendored cacert.pem exempt in non-repo dir"

# 4. ... but a private key inside a dependency dir still blocks
d="$(mk withvendorkey)"; mkdir -p "$d/venv/lib/site-packages"
: >"$d/venv/lib/site-packages/deploy.pem"
has_hidden_state "$d" && ok "non-repo venv deploy.pem -> hidden" || bad "non-repo venv deploy.pem read as clean"

# 5. Fail closed when the scan cannot complete (unreadable subdir)
d="$(mk unreadable)"; mkdir -p "$d/locked"; echo k >"$d/locked/secrets.txt"; chmod 000 "$d/locked"
has_hidden_state "$d" && ok "unreadable non-repo dir -> hidden (fail closed)" || bad "unreadable non-repo dir read as clean"
chmod 755 "$d/locked"

# 6. Repo semantics unchanged: assume-unchanged still hidden, clean repo still clean
d="$(mk repoassume)"; git init -q "$d"; echo x >"$d/a.txt"
git -C "$d" add a.txt; git -C "$d" -c user.name=t -c user.email=t@e commit -qm i
git -C "$d" update-index --assume-unchanged a.txt
has_hidden_state "$d" && ok "repo assume-unchanged still hidden" || bad "repo assume-unchanged regressed to clean"
d="$(mk repoclean)"; git init -q "$d"; echo x >"$d/a.txt"
git -C "$d" add a.txt; git -C "$d" -c user.name=t -c user.email=t@e commit -qm i
has_hidden_state "$d" && bad "clean repo read as hidden" || ok "clean repo -> clean"

echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
