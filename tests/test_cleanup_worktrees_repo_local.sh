#!/usr/bin/env bash
# test_cleanup_worktrees_repo_local.sh — Fixture tests for repo-local worktree governance.
#
# Run: bash tests/test_cleanup_worktrees_repo_local.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CLEANUP_SCRIPT="$REPO_ROOT/scripts/cleanup_worktrees.sh"

TMP_ROOT=$(mktemp -d -t cleanup_wt_repo_local.XXXXXX)
FAKE_BIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/lsof" <<SH
#!/bin/sh
echo "p1"
echo "fcwd"
echo "n$TMP_ROOT/unrelated-cwd"
SH
chmod +x "$FAKE_BIN/lsof"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0

record_pass() { echo "  PASS  $1"; PASS=$(( PASS + 1 )); }
record_fail() { echo "  FAIL  $1"; echo "        $2"; FAIL=$(( FAIL + 1 )); }

assert_contains() {
  local name="$1" needle="$2" haystack="$3"
  if grep -qF "$needle" <<<"$haystack"; then
    record_pass "$name"
  else
    record_fail "$name" "expected output to contain: $needle"
    sed 's/^/        | /' <<<"$haystack"
  fi
}

run_dry_run() {
  local out_file="$1" repo_path="$2" min_age="${3:-0}"
  env -i HOME="$TMP_ROOT/home" PATH="$FAKE_BIN:/usr/bin:/bin" \
    HERMES_SKIP_EXAMPLE_COM_GUARD=1 \
    bash "$CLEANUP_SCRIPT" --dry-run --repos "$repo_path" --min-age "$min_age" \
    >"$out_file" 2>&1
}

# Backdate every signal scripts/lib/worktree_recency.sh reads: the worktree's
# own files, the dir itself, the .git pointer, AND the git admin dir (HEAD /
# index / logs/HEAD). Touching only "$wt_path/.git" — as this helper used to —
# no longer ages a worktree, because that pointer file is written once at
# `git worktree add` time and is not evidence of when work last happened.
age_worktree_days_ago() {
  local wt_path="$1" days="$2"
  local ts gitdir
  if ts=$(date -v-"${days}"d +%Y%m%d%H%M 2>/dev/null); then :; else
    ts=$(date -d "${days} days ago" +%Y%m%d%H%M)
  fi

  # Content + the worktree root. -print0/xargs -0 so paths with spaces (the
  # "wt spaced path" fixture) survive.
  find "$wt_path" -name .git -prune -o -print0 2>/dev/null \
    | xargs -0 touch -t "$ts" 2>/dev/null || true
  touch -t "$ts" "$wt_path"

  # Backdate either a linked-worktree pointer and its git admin dir, or a
  # standalone checkout's .git directory.
  if [[ -f "$wt_path/.git" ]]; then
    touch -t "$ts" "$wt_path/.git"
    gitdir=$(sed -n 's/^gitdir: *//p' "$wt_path/.git" 2>/dev/null | head -1)
    if [[ -n "$gitdir" ]]; then
      [[ "$gitdir" == /* ]] || gitdir="$wt_path/$gitdir"
      find "$gitdir" -print0 2>/dev/null | xargs -0 touch -t "$ts" 2>/dev/null || true
    fi
  elif [[ -d "$wt_path/.git" ]]; then
    find "$wt_path/.git" -print0 2>/dev/null | xargs -0 touch -t "$ts" 2>/dev/null || true
  fi
}

setup_fixture_repo() {
  local main_repo="$TMP_ROOT/fixture-repo"
  mkdir -p "$main_repo/.claude/worktrees"
  export HERMES_SKIP_EXAMPLE_COM_GUARD=1
  git -C "$main_repo" init -b main >/dev/null
  git -C "$main_repo" config user.email "fixture@users.noreply.github.com"
  git -C "$main_repo" config user.name "Fixture User"
  printf 'base\n' > "$main_repo/README.md"
  git -C "$main_repo" add README.md
  git -C "$main_repo" commit -m "base" >/dev/null
  BASE_SHA=$(git -C "$main_repo" rev-parse HEAD)

  git -C "$main_repo" branch merged-tip
  printf 'merged\n' >> "$main_repo/README.md"
  git -C "$main_repo" add README.md
  git -C "$main_repo" commit -m "merged change" >/dev/null
  MERGED_SHA=$(git -C "$main_repo" rev-parse HEAD)
  git -C "$main_repo" checkout main >/dev/null
  git -C "$main_repo" merge --ff-only merged-tip >/dev/null

  git -C "$main_repo" branch ahead-tip
  git -C "$main_repo" checkout ahead-tip >/dev/null
  printf 'ahead\n' >> "$main_repo/README.md"
  git -C "$main_repo" add README.md
  git -C "$main_repo" commit -m "ahead change" >/dev/null
  AHEAD_SHA=$(git -C "$main_repo" rev-parse HEAD)
  git -C "$main_repo" checkout main >/dev/null

  git -C "$main_repo" worktree add -B wt-ancestor "$main_repo/.claude/worktrees/wt-ancestor" "$BASE_SHA" >/dev/null
  git -C "$main_repo" worktree add -B wt-dirty "$main_repo/.claude/worktrees/wt-dirty" "$BASE_SHA" >/dev/null
  printf 'dirty\n' >> "$main_repo/.claude/worktrees/wt-dirty/README.md"

  git -C "$main_repo" worktree add -B wt-untracked "$main_repo/.claude/worktrees/wt-untracked" "$BASE_SHA" >/dev/null
  printf 'stray\n' > "$main_repo/.claude/worktrees/wt-untracked/stray.txt"

  git -C "$main_repo" worktree add -B wt-ahead "$main_repo/.claude/worktrees/wt-ahead" "$AHEAD_SHA" >/dev/null

  git -C "$main_repo" worktree add -B wt-locked "$main_repo/.claude/worktrees/wt-locked" "$BASE_SHA" >/dev/null
  git -C "$main_repo" worktree lock wt-locked >/dev/null

  git -C "$main_repo" worktree add -B wt-young "$main_repo/.claude/worktrees/wt-young" "$BASE_SHA" >/dev/null

  local spaced_dir="$main_repo/.claude/worktrees/wt spaced path"
  git -C "$main_repo" worktree add -B wt-spaced "$spaced_dir" "$BASE_SHA" >/dev/null

  local ao_wt_dir="$TMP_ROOT/home/.ao/data/worktrees/main-repo/wt-ao-young"
  mkdir -p "$(dirname "$ao_wt_dir")"
  git -C "$main_repo" worktree add -B wt-ao-young "$ao_wt_dir" "$BASE_SHA" >/dev/null
  age_worktree_days_ago "$ao_wt_dir" 3

  # Antigravity orphan worktree (unregistered in git, but modified 2 days ago)
  local ag_orphan_dir="$TMP_ROOT/home/.gemini/antigravity/worktrees/project/orphan-recent"
  mkdir -p "$ag_orphan_dir/src"
  echo "code" > "$ag_orphan_dir/src/app.py"
  age_worktree_days_ago "$ag_orphan_dir" 2

  for wt in wt-ancestor wt-dirty wt-untracked wt-ahead wt-locked "wt spaced path"; do
    age_worktree_days_ago "$main_repo/.claude/worktrees/$wt" 30
  done
  age_worktree_days_ago "$main_repo/.claude/worktrees/wt-young" 3

  printf '%s\n' "$main_repo"
}

echo "=== repo-local worktree cleanup fixture tests ==="

MAIN_REPO=$(setup_fixture_repo)
OUT="$TMP_ROOT/dry-run.out"
run_dry_run "$OUT" "$MAIN_REPO" 14
OUT_CONTENT=$(cat "$OUT")

assert_contains "dry-run banner" "=== WORKTREE CLEANUP (DRY-RUN) ===" "$OUT_CONTENT"
assert_contains "ancestor worktree eligible" "repo-local   ELIGIBLE" "$OUT_CONTENT"
assert_contains "ancestor path fragment" ".claude/worktrees/wt-ancestor" "$OUT_CONTENT"
assert_contains "dirty worktree preserved" "repo-local   PRESERVE" "$OUT_CONTENT"
assert_contains "dirty reason" ".claude/worktrees/wt-dirty | dirty" "$OUT_CONTENT"
assert_contains "untracked reason" ".claude/worktrees/wt-untracked | untracked" "$OUT_CONTENT"
assert_contains "ahead reason" ".claude/worktrees/wt-ahead | ahead-of-main" "$OUT_CONTENT"
assert_contains "locked reason" ".claude/worktrees/wt-locked | locked" "$OUT_CONTENT"
assert_contains "young reason" ".claude/worktrees/wt-young | young" "$OUT_CONTENT"
assert_contains "ao young worktree preserved by 14d floor" ".ao/data/worktrees/main-repo/wt-ao-young | young" "$OUT_CONTENT"
assert_contains "antigravity recent orphan preserved by 14d floor" "antigravity  PRESERVE" "$OUT_CONTENT"
assert_contains "spaced path eligible" ".claude/worktrees/wt spaced path" "$OUT_CONTENT"
assert_contains "summary eligible count" "Repo-local:  2 eligible" "$OUT_CONTENT"
assert_contains "summary preserved count" "Repo-local:  2 eligible, 6 preserved." "$OUT_CONTENT"

echo "Test: --clean without WORKTREE_APPROVED refuses before deletion"
OUT_REFUSE="$TMP_ROOT/refuse.out"
set +e
env -i HOME="$TMP_ROOT/home" PATH="/usr/bin:/bin" \
  bash "$CLEANUP_SCRIPT" --clean --repos "$MAIN_REPO" --min-age 0 >"$OUT_REFUSE" 2>&1
RC_REFUSE=$?
set -e
if [[ "$RC_REFUSE" -eq 0 ]]; then record_pass "refusal exits 0"; else record_fail "refusal exits 0" "rc=$RC_REFUSE"; fi
assert_contains "refusal message" "Refusing to delete worktrees: set WORKTREE_APPROVED=1" "$(cat "$OUT_REFUSE")"
if [[ -d "$MAIN_REPO/.claude/worktrees/wt-ancestor" ]]; then
  record_pass "ancestor worktree still on disk after refused clean"
else
  record_fail "ancestor worktree still on disk after refused clean" "worktree removed unexpectedly"
fi

assert_not_contains() {
  local name="$1" needle="$2" haystack="$3"
  if grep -qF "$needle" <<<"$haystack"; then
    record_fail "$name" "unexpected: $needle"
    sed 's/^/        | /' <<<"$haystack"
  else
    record_pass "$name"
  fi
}

echo "Test: standard root \$HOME/.worktrees is discovered and governed (spec D6)"
STD_HOME="$TMP_ROOT/home"
STD_ROOT="$STD_HOME/.worktrees"
STD_REPO="$TMP_ROOT/std-repo"
git init -q -b main "$STD_REPO"
git -C "$STD_REPO" config user.email "fixture@users.noreply.github.com"
git -C "$STD_REPO" config user.name "Fixture User"
printf 'base\n' > "$STD_REPO/README.md"
git -C "$STD_REPO" add README.md
git -C "$STD_REPO" commit -q -m base
for wt in r/old r/young r/busy ao-proj/sess-1 lazy/sess-2 lazyrepo/sess-3 sess-4; do
  mkdir -p "$(dirname "$STD_ROOT/$wt")"
  git -C "$STD_REPO" worktree add -q -B "std-${wt//\//-}" "$STD_ROOT/$wt" main
done
for wt in r/old r/busy ao-proj/sess-1 lazy/sess-2 lazyrepo/sess-3 sess-4; do age_worktree_days_ago "$STD_ROOT/$wt" 10; done
age_worktree_days_ago "$STD_ROOT/r/young" 2

AO_CFG="$TMP_ROOT/agent-orchestrator.yaml"
# Live-config shape: a top-level default worktreeDir equal to the standard root
# must not swallow the whole root; projects without their own worktreeDir fall
# back to it (as <root>/<projectId|repo basename>/... or <root>/<session>).
cat > "$AO_CFG" <<'YAML'
projects:
  demo:
    path: ~/src/demo
    worktreeDir: "~/.worktrees/ao-proj"  # AO sessions
  lazy:
    path: /x/lazyrepo
    repo: org/lazyrepo
pruneWorktrees: false
worktreeDir: ~/.worktrees
YAML

(cd "$STD_ROOT/r/busy" && exec sleep 300) &
SLEEP_PID=$!
trap 'kill "$SLEEP_PID" 2>/dev/null || true; rm -rf "$TMP_ROOT"' EXIT
sleep 0.5

run_std() {  # run_std <out_file> <PATH> — no --repos: exercises discovery
  env -i HOME="$STD_HOME" PATH="$2" HERMES_SKIP_EXAMPLE_COM_GUARD=1 \
    DISK_MAGICIAN_AO_CONFIG="$AO_CFG" \
    bash "$CLEANUP_SCRIPT" --dry-run >"$1" 2>&1
}

cat > "$FAKE_BIN/lsof" <<SH
#!/bin/sh
echo "p1"
echo "fcwd"
echo "n$STD_ROOT/r/busy"
SH
chmod +x "$FAKE_BIN/lsof"
run_std "$TMP_ROOT/std.out" "$FAKE_BIN:/usr/bin:/bin"
STD_OUT=$(cat "$TMP_ROOT/std.out")
if grep -F '.worktrees/r/old | age=' <<<"$STD_OUT" | grep -qF 'ELIGIBLE  '; then
  record_pass "std root: 10d merged clean worktree eligible"
else
  record_fail "std root: 10d merged clean worktree eligible" "no ELIGIBLE ledger line for .worktrees/r/old"
fi
assert_contains "std root: old path listed" ".worktrees/r/old | age=" "$STD_OUT"
assert_contains "std root: 2d worktree protected" ".worktrees/r/young | young" "$STD_OUT"
assert_contains "std root: AO worktreeDir skipped" ".worktrees/ao-proj/sess-1 | ao-owned" "$STD_OUT"
assert_contains "std root: live-cwd worktree skipped" ".worktrees/r/busy | live-cwd" "$STD_OUT"
assert_contains "std root: project w/o worktreeDir (key) skipped" ".worktrees/lazy/sess-2 | ao-owned" "$STD_OUT"
assert_contains "std root: project w/o worktreeDir (path basename) skipped" ".worktrees/lazyrepo/sess-3 | ao-owned" "$STD_OUT"
assert_contains "std root: depth-1 session under default worktreeDir skipped" ".worktrees/sess-4 | ao-owned" "$STD_OUT"

FAKE_BIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKE_BIN"
printf '#!/bin/sh\nexit 1\n' > "$FAKE_BIN/lsof"
chmod +x "$FAKE_BIN/lsof"
run_std "$TMP_ROOT/std-nolsof.out" "$FAKE_BIN:/usr/bin:/bin"
STD_NOLSOF=$(cat "$TMP_ROOT/std-nolsof.out")
assert_contains "lsof failure: old worktree preserved" ".worktrees/r/old | cwd-unknown" "$STD_NOLSOF"
assert_not_contains "lsof failure: nothing in std root eligible" "ELIGIBLE  " "$(grep -F "/.worktrees/" <<<"$STD_NOLSOF" || true)"

# Regression: Zero-status lsof with unresolved cwd record (Linux readlink/stat permission error)
cat > "$FAKE_BIN/lsof" <<'SH'
#!/bin/sh
echo "p999"
echo "fcwd"
echo "n/proc/999/cwd (readlink: Permission denied)"
exit 0
SH
chmod +x "$FAKE_BIN/lsof"
run_std "$TMP_ROOT/std-unresolved.out" "$FAKE_BIN:/usr/bin:/bin"
STD_UNRESOLVED=$(cat "$TMP_ROOT/std-unresolved.out")
assert_contains "lsof unresolved cwd record preserved" ".worktrees/r/old | cwd-unknown" "$STD_UNRESOLVED"
assert_not_contains "lsof unresolved: nothing in std root eligible" "ELIGIBLE  " "$(grep -F "/.worktrees/" <<<"$STD_UNRESOLVED" || true)"

# Regression: Zero-status lsof with empty output
printf '#!/bin/sh\nexit 0\n' > "$FAKE_BIN/lsof"
chmod +x "$FAKE_BIN/lsof"
run_std "$TMP_ROOT/std-empty.out" "$FAKE_BIN:/usr/bin:/bin"
STD_EMPTY=$(cat "$TMP_ROOT/std-empty.out")
assert_contains "lsof empty output preserved" ".worktrees/r/old | cwd-unknown" "$STD_EMPTY"
assert_not_contains "lsof empty: nothing in std root eligible" "ELIGIBLE  " "$(grep -F "/.worktrees/" <<<"$STD_EMPTY" || true)"

# Regression: Zero-status lsof with warning on stderr
cat > "$FAKE_BIN/lsof" <<'SH'
#!/bin/sh
echo "lsof: WARNING: can't stat() /proc/123/cwd: Permission denied" >&2
echo "n/"
exit 0
SH
chmod +x "$FAKE_BIN/lsof"
run_std "$TMP_ROOT/std-warning.out" "$FAKE_BIN:/usr/bin:/bin"
STD_WARNING=$(cat "$TMP_ROOT/std-warning.out")
assert_contains "lsof warning on stderr preserved" ".worktrees/r/old | cwd-unknown" "$STD_WARNING"
assert_not_contains "lsof warning: nothing in std root eligible" "ELIGIBLE  " "$(grep -F "/.worktrees/" <<<"$STD_WARNING" || true)"

# Regression: Zero-status lsof with large output (>64KB pipe buffer) and unresolved record near start
cat > "$FAKE_BIN/lsof" <<'SH'
#!/bin/sh
echo "p999"
echo "fcwd"
echo "n/proc/999/cwd (readlink: Permission denied)"
for i in $(seq 1 1000); do
  echo "p$i"
  echo "fcwd"
  echo "n/nonexistent/dummy/path/for/process/padding/number/$i"
done
exit 0
SH
chmod +x "$FAKE_BIN/lsof"
run_std "$TMP_ROOT/std-pipebuf.out" "$FAKE_BIN:/usr/bin:/bin"
STD_PIPEBUF=$(cat "$TMP_ROOT/std-pipebuf.out")
assert_contains "lsof large output pipe buffer preserved" ".worktrees/r/old | cwd-unknown" "$STD_PIPEBUF"
assert_not_contains "lsof large output: nothing in std root eligible" "ELIGIBLE  " "$(grep -F "/.worktrees/" <<<"$STD_PIPEBUF" || true)"

# Regression: mktemp failure (cannot allocate temp file for diagnostic capture under disk pressure)
cat > "$FAKE_BIN/mktemp" <<'SH'
#!/bin/sh
exit 1
SH
chmod +x "$FAKE_BIN/mktemp"
cat > "$FAKE_BIN/lsof" <<'SH'
#!/bin/sh
echo "lsof: WARNING: can't stat() /proc/123/cwd: Permission denied" >&2
echo "n/"
exit 0
SH
chmod +x "$FAKE_BIN/lsof"
run_std "$TMP_ROOT/std-nomktemp.out" "$FAKE_BIN:/usr/bin:/bin"
STD_NOMKTEMP=$(cat "$TMP_ROOT/std-nomktemp.out")
assert_contains "mktemp failure preserved" ".worktrees/r/old | cwd-unknown" "$STD_NOMKTEMP"
assert_not_contains "mktemp failure: nothing in std root eligible" "ELIGIBLE  " "$(grep -F "/.worktrees/" <<<"$STD_NOMKTEMP" || true)"
rm -f "$FAKE_BIN/mktemp"

kill "$SLEEP_PID" 2>/dev/null || true

echo "Test: custom configured STANDARD_WORKTREE_ROOT discovery and governance without --repos"
CUSTOM_WT_ROOT="$TMP_ROOT/custom_wt_root"
CUSTOM_REPO="$TMP_ROOT/custom_main_repo"
mkdir -p "$CUSTOM_REPO"
git -C "$CUSTOM_REPO" init -b main >/dev/null
git -C "$CUSTOM_REPO" config user.email "fixture@users.noreply.github.com"
git -C "$CUSTOM_REPO" config user.name "Fixture User"
echo "init" > "$CUSTOM_REPO/README.md"
git -C "$CUSTOM_REPO" add README.md
git -C "$CUSTOM_REPO" commit -m "init" >/dev/null
CUSTOM_BASE_SHA=$(git -C "$CUSTOM_REPO" rev-parse HEAD)

mkdir -p "$CUSTOM_WT_ROOT/custom_main_repo"
git -C "$CUSTOM_REPO" worktree add -B wt-custom-old "$CUSTOM_WT_ROOT/custom_main_repo/wt-custom-old" "$CUSTOM_BASE_SHA" >/dev/null
age_worktree_days_ago "$CUSTOM_WT_ROOT/custom_main_repo/wt-custom-old" 10

CUSTOM_HOME="$TMP_ROOT/custom_home"
mkdir -p "$CUSTOM_HOME"
CUSTOM_OUT="$TMP_ROOT/custom_std.out"
cat > "$FAKE_BIN/lsof" <<'SH'
#!/bin/sh
echo 'p1'
echo 'fcwd'
echo 'n/var/empty'
SH
chmod +x "$FAKE_BIN/lsof"
env -i HOME="$CUSTOM_HOME" PATH="$FAKE_BIN:/usr/bin:/bin" \
  STANDARD_WORKTREE_ROOT="$CUSTOM_WT_ROOT" \
  HERMES_SKIP_EXAMPLE_COM_GUARD=1 \
  bash "$CLEANUP_SCRIPT" --dry-run >"$CUSTOM_OUT" 2>&1

CUSTOM_TEXT=$(cat "$CUSTOM_OUT")
if grep -F "$CUSTOM_WT_ROOT/custom_main_repo/wt-custom-old" <<<"$CUSTOM_TEXT" | grep -qF 'ELIGIBLE  '; then
  record_pass "custom STANDARD_WORKTREE_ROOT discovered without --repos and eligible"
else
  record_fail "custom STANDARD_WORKTREE_ROOT discovered without --repos and eligible" "did not find ELIGIBLE for custom wt root"
fi
assert_contains "custom STANDARD_WORKTREE_ROOT summary eligible count" "Repo-local:  1 eligible, 0 preserved." "$CUSTOM_TEXT"

DISCOVERY_LIB="$REPO_ROOT/scripts/lib/worktree_repo_discovery.sh"
SCRIPT_TEXT=$(cat "$CLEANUP_SCRIPT" "$DISCOVERY_LIB" 2>/dev/null || cat "$CLEANUP_SCRIPT")
if grep -Eq '(_dwr_find_repos_from_worktrees|find_repos_from_worktrees) "\$HOME/wc-wt"' <<<"$SCRIPT_TEXT"; then
  record_pass "wc-wt discovery line kept"
else
  record_fail "wc-wt discovery line kept" "expected discovery to include \$HOME/wc-wt"
fi
if grep -Eq '(_dwr_find_repos_from_worktrees|find_repos_from_worktrees) "\$HOME/project_worldaiclaw"' <<<"$SCRIPT_TEXT"; then
  record_pass "project_worldaiclaw discovery line kept"
else
  record_fail "project_worldaiclaw discovery line kept" "expected discovery to include \$HOME/project_worldaiclaw"
fi

echo "Test: squash-merged PR worktree eligibility governance (bead disk_magician-ueh)"
SQUASH_REPO="$TMP_ROOT/squash-repo"
mkdir -p "$SQUASH_REPO/.claude/worktrees"
git init -q -b main "$SQUASH_REPO"
git -C "$SQUASH_REPO" config user.email "fixture@users.noreply.github.com"
git -C "$SQUASH_REPO" config user.name "Fixture User"
git -C "$SQUASH_REPO" remote add origin "https://github.com/example-org/squash-repo.git"
printf 'initial\n' > "$SQUASH_REPO/README.md"
git -C "$SQUASH_REPO" add README.md
git -C "$SQUASH_REPO" commit -q -m "initial commit"

# Branch feat-a (Case A: matching headRefOid -> ELIGIBLE)
git -C "$SQUASH_REPO" checkout -q -b feat-a
printf 'feature A\n' > "$SQUASH_REPO/feature_a.txt"
git -C "$SQUASH_REPO" add feature_a.txt
git -C "$SQUASH_REPO" commit -q -m "feature A commit"
SHA_A=$(git -C "$SQUASH_REPO" rev-parse HEAD)
git -C "$SQUASH_REPO" checkout -q main

# Branch feat-b (Case B: differing headRefOid -> PRESERVE merged-differing-head)
git -C "$SQUASH_REPO" checkout -q -b feat-b
printf 'feature B\n' > "$SQUASH_REPO/feature_b.txt"
git -C "$SQUASH_REPO" add feature_b.txt
git -C "$SQUASH_REPO" commit -q -m "feature B commit"
SHA_B=$(git -C "$SQUASH_REPO" rev-parse HEAD)
git -C "$SQUASH_REPO" checkout -q main

# Branch feat-c (Case C: gh exits 1 -> PRESERVE ahead-of-main)
git -C "$SQUASH_REPO" checkout -q -b feat-c
printf 'feature C\n' > "$SQUASH_REPO/feature_c.txt"
git -C "$SQUASH_REPO" add feature_c.txt
git -C "$SQUASH_REPO" commit -q -m "feature C commit"
SHA_C=$(git -C "$SQUASH_REPO" rev-parse HEAD)
git -C "$SQUASH_REPO" checkout -q main

# Branch feat-d (Case D: gh returns empty headRefOid -> PRESERVE ahead-of-main)
git -C "$SQUASH_REPO" checkout -q -b feat-d
printf 'feature D\n' > "$SQUASH_REPO/feature_d.txt"
git -C "$SQUASH_REPO" add feature_d.txt
git -C "$SQUASH_REPO" commit -q -m "feature D commit"
SHA_D=$(git -C "$SQUASH_REPO" rev-parse HEAD)
git -C "$SQUASH_REPO" checkout -q main

# Branch feat-e (Case E: gh emits matching SHA but exits 124 timeout -> PRESERVE ahead-of-main)
git -C "$SQUASH_REPO" checkout -q -b feat-e
printf 'feature E\n' > "$SQUASH_REPO/feature_e.txt"
git -C "$SQUASH_REPO" add feature_e.txt
git -C "$SQUASH_REPO" commit -q -m "feature E commit"
SHA_E=$(git -C "$SQUASH_REPO" rev-parse HEAD)
git -C "$SQUASH_REPO" checkout -q main

# Branch feat-f (Case F: matching SHA, but live process has cwd inside worktree -> PRESERVE live-cwd)
git -C "$SQUASH_REPO" checkout -q -b feat-f
printf 'feature F\n' > "$SQUASH_REPO/feature_f.txt"
git -C "$SQUASH_REPO" add feature_f.txt
git -C "$SQUASH_REPO" commit -q -m "feature F commit"
SHA_F=$(git -C "$SQUASH_REPO" rev-parse HEAD)
git -C "$SQUASH_REPO" checkout -q main

# Advance main so branches are ahead-of-main (not ancestors)
printf 'squashed commit\n' >> "$SQUASH_REPO/README.md"
git -C "$SQUASH_REPO" add README.md
git -C "$SQUASH_REPO" commit -q -m "main squashed commit"

# Add worktrees
git -C "$SQUASH_REPO" worktree add -q -B feat-a "$SQUASH_REPO/.claude/worktrees/wt-squash-a" "$SHA_A"
git -C "$SQUASH_REPO" worktree add -q -B feat-b "$SQUASH_REPO/.claude/worktrees/wt-squash-b" "$SHA_B"
git -C "$SQUASH_REPO" worktree add -q -B feat-c "$SQUASH_REPO/.claude/worktrees/wt-squash-c" "$SHA_C"
git -C "$SQUASH_REPO" worktree add -q -B feat-d "$SQUASH_REPO/.claude/worktrees/wt-squash-d" "$SHA_D"
git -C "$SQUASH_REPO" worktree add -q -B feat-e "$SQUASH_REPO/.claude/worktrees/wt-squash-e" "$SHA_E"
git -C "$SQUASH_REPO" worktree add -q -B feat-f "$SQUASH_REPO/.claude/worktrees/wt-squash-f" "$SHA_F"

age_worktree_days_ago "$SQUASH_REPO/.claude/worktrees/wt-squash-a" 30
age_worktree_days_ago "$SQUASH_REPO/.claude/worktrees/wt-squash-b" 30
age_worktree_days_ago "$SQUASH_REPO/.claude/worktrees/wt-squash-c" 30
age_worktree_days_ago "$SQUASH_REPO/.claude/worktrees/wt-squash-d" 30
age_worktree_days_ago "$SQUASH_REPO/.claude/worktrees/wt-squash-e" 30
age_worktree_days_ago "$SQUASH_REPO/.claude/worktrees/wt-squash-f" 30

WT_F_REAL="$(cd "$SQUASH_REPO/.claude/worktrees/wt-squash-f" 2>/dev/null && pwd -P || printf '%s' "$SQUASH_REPO/.claude/worktrees/wt-squash-f")"
cat > "$FAKE_BIN/lsof" <<SH
#!/bin/sh
echo "n$WT_F_REAL"
SH
chmod +x "$FAKE_BIN/lsof"

# Provide fake timeout and fake gh on PATH
cat > "$FAKE_BIN/timeout" <<'SH'
#!/bin/sh
shift
exec "$@"
SH
chmod +x "$FAKE_BIN/timeout"

cat > "$FAKE_BIN/gh" <<SH
#!/bin/sh
case "\$*" in
  *feat-a*)
    echo "$SHA_A"
    exit 0
    ;;
  *feat-b*)
    echo "differing000000000000000000000000000000000"
    exit 0
    ;;
  *feat-c*)
    exit 1
    ;;
  *feat-d*)
    echo ""
    exit 0
    ;;
  *feat-e*)
    echo "$SHA_E"
    exit 124
    ;;
  *feat-f*)
    echo "$SHA_F"
    exit 0
    ;;
  *)
    exit 1
    ;;
esac
SH
chmod +x "$FAKE_BIN/gh"

OUT_SQUASH="$TMP_ROOT/squash-test.out"
env -i HOME="$TMP_ROOT/home" PATH="$FAKE_BIN:/usr/bin:/bin" \
  HERMES_SKIP_EXAMPLE_COM_GUARD=1 \
  bash "$CLEANUP_SCRIPT" --dry-run --repos "$SQUASH_REPO" --min-age 14 \
  >"$OUT_SQUASH" 2>&1
OUT_SQUASH_CONTENT=$(cat "$OUT_SQUASH")

# Case A: Squash-merged clean 30d worktree with fake gh returning matching headRefOid -> ELIGIBLE
assert_contains "Case A: squash-merged matching head is eligible" "repo-local   ELIGIBLE" "$OUT_SQUASH_CONTENT"
assert_contains "Case A path fragment" ".claude/worktrees/wt-squash-a" "$OUT_SQUASH_CONTENT"

# Case B: Squash-merged clean 30d worktree with fake gh returning differing headRefOid -> PRESERVE merged-differing-head
assert_contains "Case B: differing headRefOid preserved" ".claude/worktrees/wt-squash-b | merged-differing-head" "$OUT_SQUASH_CONTENT"

# Case C: Squash-merged clean 30d worktree with fake gh exiting 1 -> fail-closed PRESERVE ahead-of-main
assert_contains "Case C: gh exit 1 preserved as ahead-of-main" ".claude/worktrees/wt-squash-c | ahead-of-main" "$OUT_SQUASH_CONTENT"

# Case D: Squash-merged clean 30d worktree with fake gh returning empty headRefOid -> fail-closed PRESERVE ahead-of-main
assert_contains "Case D: empty headRefOid preserved as ahead-of-main" ".claude/worktrees/wt-squash-d | ahead-of-main" "$OUT_SQUASH_CONTENT"

# Case E: Squash-merged clean 30d worktree with fake gh emitting matching SHA but exiting 124 (timeout) -> PRESERVE ahead-of-main
assert_contains "Case E: gh exit 124 timeout preserved as ahead-of-main" ".claude/worktrees/wt-squash-e | ahead-of-main" "$OUT_SQUASH_CONTENT"

# Case F: Squash-merged clean 30d worktree with matching SHA, but live process in cwd -> PRESERVE live-cwd
assert_contains "Case F: repo-local live-cwd preserved" ".claude/worktrees/wt-squash-f | live-cwd" "$OUT_SQUASH_CONTENT"

# ---------------------------------------------------------------------------
# Test: Required git probes fail-closed regressions (dot P1 review on PR #109)
# ---------------------------------------------------------------------------
echo "Test: Required git probes fail-closed regressions"

export HERMES_SKIP_EXAMPLE_COM_GUARD=1

PROBE_REPO="$TMP_ROOT/probe-repo"
mkdir -p "$PROBE_REPO"
git -C "$PROBE_REPO" init --quiet -b main
git -C "$PROBE_REPO" config user.email "jleechan2015@users.noreply.github.com"
git -C "$PROBE_REPO" config user.name "Tester"
echo "hello main" > "$PROBE_REPO/file.txt"
echo "anchor content" > "$PROBE_REPO/anchor.txt"
git -C "$PROBE_REPO" add file.txt anchor.txt
git -C "$PROBE_REPO" commit -m "initial commit on main" --quiet

# 1. Repo-local candidate where git status fails (e.g. index corrupted)
git -C "$PROBE_REPO" worktree add -b wt-fail-status "$PROBE_REPO/.claude/worktrees/wt-fail-status" --quiet
echo "CORRUPTED" > "$PROBE_REPO/.git/worktrees/wt-fail-status/index"
age_worktree_days_ago "$PROBE_REPO/.claude/worktrees/wt-fail-status" 20

# 2. Repo-local candidate in a repo where main_ref is missing (branch is 'dev', no 'main' or 'origin/main')
DEV_REPO="$TMP_ROOT/dev-repo"
mkdir -p "$DEV_REPO"
git -C "$DEV_REPO" init --quiet -b dev
git -C "$DEV_REPO" config user.email "jleechan2015@users.noreply.github.com"
git -C "$DEV_REPO" config user.name "Tester"
echo "hello dev" > "$DEV_REPO/file.txt"
git -C "$DEV_REPO" add file.txt
git -C "$DEV_REPO" commit -m "initial commit on dev" --quiet
git -C "$DEV_REPO" worktree add -b wt-dev "$DEV_REPO/.claude/worktrees/wt-dev" --quiet
age_worktree_days_ago "$DEV_REPO/.claude/worktrees/wt-dev" 20

# 3. Antigravity orphan with failed git status (unregistered from main repo)
AG_FAIL_STATUS="$TMP_ROOT/home/.gemini/antigravity/worktrees/project/ag-fail-status"
mkdir -p "$AG_FAIL_STATUS"
git -C "$PROBE_REPO" worktree add -b wt-ag-fail "$AG_FAIL_STATUS" --quiet
echo "CORRUPTED" > "$PROBE_REPO/.git/worktrees/ag-fail-status/index"
age_worktree_days_ago "$AG_FAIL_STATUS" 20
rm -rf "$PROBE_REPO/.git/worktrees/ag-fail-status"

# 4. Antigravity orphan where main_ref is missing (repo with only dev branch)
AG_DEV="$TMP_ROOT/home/.gemini/antigravity/worktrees/project/ag-missing-main"
mkdir -p "$AG_DEV"
git -C "$AG_DEV" init --quiet -b dev
git -C "$AG_DEV" config user.email "jleechan2015@users.noreply.github.com"
git -C "$AG_DEV" config user.name "Tester"
echo "hello dev" > "$AG_DEV/file.txt"
git -C "$AG_DEV" add file.txt
git -C "$AG_DEV" commit -m "initial commit on dev" --quiet
age_worktree_days_ago "$AG_DEV" 20

# 5. Antigravity orphan where git status fails (dangling gitdir pointer)
AG_DANGLING="$TMP_ROOT/home/.gemini/antigravity/worktrees/project/ag-dangling-repo"
mkdir -p "$AG_DANGLING"
echo "gitdir: /nonexistent/path/to/.git/worktrees/ag-dangling-repo" > "$AG_DANGLING/.git"
echo "dangling content" > "$AG_DANGLING/file.txt"
if ts_old=$(date -v-20d +%Y%m%d%H%M 2>/dev/null); then :; else
  ts_old=$(date -d "20 days ago" +%Y%m%d%H%M)
fi
touch -t "$ts_old" "$AG_DANGLING" "$AG_DANGLING/.git" "$AG_DANGLING/file.txt"

# 6. Antigravity orphan positively verified clean + ancestor of main -> ELIGIBLE
AG_ELIGIBLE="$TMP_ROOT/home/.gemini/antigravity/worktrees/project/ag-clean-ancestor"
mkdir -p "$AG_ELIGIBLE"
git -C "$AG_ELIGIBLE" init --quiet -b main
git -C "$AG_ELIGIBLE" config user.email "jleechan2015@users.noreply.github.com"
git -C "$AG_ELIGIBLE" config user.name "Tester"
echo "hello main" > "$AG_ELIGIBLE/file.txt"
git -C "$AG_ELIGIBLE" add file.txt
git -C "$AG_ELIGIBLE" commit -m "initial commit on main" --quiet
age_worktree_days_ago "$AG_ELIGIBLE" 20

# 11. Registered Antigravity worktree must be recognized from porcelain paths.
AG_REGISTERED="$TMP_ROOT/home/.gemini/antigravity/worktrees/project/ag-registered"
git -C "$PROBE_REPO" worktree add -b wt-ag-registered "$AG_REGISTERED" --quiet
age_worktree_days_ago "$AG_REGISTERED" 20

# 12. An ignored file-like directory with user data must not be treated as a cache.
AG_IGNORED="$TMP_ROOT/home/.gemini/antigravity/worktrees/project/ag-ignored-data"
mkdir -p "$AG_IGNORED"
git -C "$AG_IGNORED" init --quiet -b main
git -C "$AG_IGNORED" config user.email "jleechan2015@users.noreply.github.com"
git -C "$AG_IGNORED" config user.name "Tester"
printf 'data.pyc\n' > "$AG_IGNORED/.gitignore"
printf 'clean\n' > "$AG_IGNORED/file.txt"
git -C "$AG_IGNORED" add .gitignore file.txt
git -C "$AG_IGNORED" commit -m "initial commit" --quiet
mkdir -p "$AG_IGNORED/data.pyc"
printf 'keep this\n' > "$AG_IGNORED/data.pyc/notes.txt"
age_worktree_days_ago "$AG_IGNORED" 20

# Antigravity candidates must remain protected when hidden state exists.
AG_HIDDEN_ENV="$TMP_ROOT/home/.gemini/antigravity/worktrees/project/ag-hidden-env"
mkdir -p "$AG_HIDDEN_ENV"
git -C "$AG_HIDDEN_ENV" init --quiet -b main
git -C "$AG_HIDDEN_ENV" config user.email "fixture@users.noreply.github.com"
git -C "$AG_HIDDEN_ENV" config user.name "Fixture User"
printf 'node_modules/\n' > "$AG_HIDDEN_ENV/.gitignore"
printf 'tracked\n' > "$AG_HIDDEN_ENV/file.txt"
git -C "$AG_HIDDEN_ENV" add .gitignore file.txt
git -C "$AG_HIDDEN_ENV" commit -m "ignore node modules" --quiet
mkdir -p "$AG_HIDDEN_ENV/node_modules"
printf 'SECRET=1\n' > "$AG_HIDDEN_ENV/node_modules/.env"
age_worktree_days_ago "$AG_HIDDEN_ENV" 20

AG_HIDDEN_INDEX="$TMP_ROOT/home/.gemini/antigravity/worktrees/project/ag-hidden-index"
mkdir -p "$AG_HIDDEN_INDEX"
git -C "$AG_HIDDEN_INDEX" init --quiet -b main
git -C "$AG_HIDDEN_INDEX" config user.email "fixture@users.noreply.github.com"
git -C "$AG_HIDDEN_INDEX" config user.name "Fixture User"
printf 'tracked\n' > "$AG_HIDDEN_INDEX/tracked.txt"
git -C "$AG_HIDDEN_INDEX" add tracked.txt
git -C "$AG_HIDDEN_INDEX" commit -m "tracked file" --quiet
git -C "$AG_HIDDEN_INDEX" update-index --assume-unchanged tracked.txt
printf 'hidden edit\n' > "$AG_HIDDEN_INDEX/tracked.txt"
age_worktree_days_ago "$AG_HIDDEN_INDEX" 20

AG_NON_GIT="$TMP_ROOT/home/.gemini/antigravity/worktrees/project/ag-non-git"
mkdir -p "$AG_NON_GIT"
printf 'keep user data\n' > "$AG_NON_GIT/notes.txt"
age_worktree_days_ago "$AG_NON_GIT" 20

# 7. Repo-local candidate with unstaged type-change T (tracked file replaced by symlink)
git -C "$PROBE_REPO" worktree add -b wt-type-unstaged "$PROBE_REPO/.claude/worktrees/wt-type-unstaged" --quiet
rm "$PROBE_REPO/.claude/worktrees/wt-type-unstaged/file.txt"
ln -s /dev/null "$PROBE_REPO/.claude/worktrees/wt-type-unstaged/file.txt"
age_worktree_days_ago "$PROBE_REPO/.claude/worktrees/wt-type-unstaged" 20

# 8. Repo-local candidate with staged type-change T (tracked file replaced by symlink and staged)
git -C "$PROBE_REPO" worktree add -b wt-type-staged "$PROBE_REPO/.claude/worktrees/wt-type-staged" --quiet
rm "$PROBE_REPO/.claude/worktrees/wt-type-staged/file.txt"
ln -s /dev/null "$PROBE_REPO/.claude/worktrees/wt-type-staged/file.txt"
git -C "$PROBE_REPO/.claude/worktrees/wt-type-staged" add file.txt
age_worktree_days_ago "$PROBE_REPO/.claude/worktrees/wt-type-staged" 20

# 9. Antigravity orphan with unstaged type-change T
AG_TYPE_UNSTAGED="$TMP_ROOT/home/.gemini/antigravity/worktrees/project/ag-type-unstaged"
mkdir -p "$AG_TYPE_UNSTAGED"
git -C "$AG_TYPE_UNSTAGED" init --quiet -b main
git -C "$AG_TYPE_UNSTAGED" config user.email "jleechan2015@users.noreply.github.com"
git -C "$AG_TYPE_UNSTAGED" config user.name "Tester"
echo "hello main" > "$AG_TYPE_UNSTAGED/file.txt"
echo "anchor" > "$AG_TYPE_UNSTAGED/anchor.txt"
git -C "$AG_TYPE_UNSTAGED" add file.txt anchor.txt
git -C "$AG_TYPE_UNSTAGED" commit -m "initial commit on main" --quiet
rm "$AG_TYPE_UNSTAGED/file.txt"
ln -s /dev/null "$AG_TYPE_UNSTAGED/file.txt"
age_worktree_days_ago "$AG_TYPE_UNSTAGED" 20

# 10. Antigravity orphan with staged type-change T
AG_TYPE_STAGED="$TMP_ROOT/home/.gemini/antigravity/worktrees/project/ag-type-staged"
mkdir -p "$AG_TYPE_STAGED"
git -C "$AG_TYPE_STAGED" init --quiet -b main
git -C "$AG_TYPE_STAGED" config user.email "jleechan2015@users.noreply.github.com"
git -C "$AG_TYPE_STAGED" config user.name "Tester"
echo "hello main" > "$AG_TYPE_STAGED/file.txt"
echo "anchor" > "$AG_TYPE_STAGED/anchor.txt"
git -C "$AG_TYPE_STAGED" add file.txt anchor.txt
git -C "$AG_TYPE_STAGED" commit -m "initial commit on main" --quiet
rm "$AG_TYPE_STAGED/file.txt"
ln -s /dev/null "$AG_TYPE_STAGED/file.txt"
git -C "$AG_TYPE_STAGED" add file.txt
age_worktree_days_ago "$AG_TYPE_STAGED" 20

OUT_PROBE="$TMP_ROOT/probe-test.out"
env -i HOME="$TMP_ROOT/home" PATH="$FAKE_BIN:/usr/bin:/bin" \
  HERMES_SKIP_EXAMPLE_COM_GUARD=1 \
  bash "$CLEANUP_SCRIPT" --dry-run --repos "$PROBE_REPO,$DEV_REPO" --min-age 14 \
  >"$OUT_PROBE" 2>&1
OUT_PROBE_CONTENT=$(cat "$OUT_PROBE")

assert_contains "repo-local git status failure preserved" ".claude/worktrees/wt-fail-status | status-failed" "$OUT_PROBE_CONTENT"
assert_not_contains "repo-local git status failure not eligible" "ELIGIBLE" "$(grep -F "wt-fail-status" <<<"$OUT_PROBE_CONTENT" || true)"

assert_contains "repo-local missing main ref preserved" ".claude/worktrees/wt-dev | main-ref-missing" "$OUT_PROBE_CONTENT"
assert_not_contains "repo-local missing main ref not eligible" "ELIGIBLE" "$(grep -F "wt-dev" <<<"$OUT_PROBE_CONTENT" || true)"

assert_contains "repo-local unstaged typechange T preserved" "wt-type-unstaged | dirty" "$OUT_PROBE_CONTENT"
assert_not_contains "repo-local unstaged typechange T not eligible" "ELIGIBLE" "$(grep -F "wt-type-unstaged" <<<"$OUT_PROBE_CONTENT" || true)"

assert_contains "repo-local staged typechange T preserved" "wt-type-staged | dirty" "$OUT_PROBE_CONTENT"
assert_not_contains "repo-local staged typechange T not eligible" "ELIGIBLE" "$(grep -F "wt-type-staged" <<<"$OUT_PROBE_CONTENT" || true)"

assert_contains "antigravity git status failure preserved" "ag-fail-status | status-failed" "$OUT_PROBE_CONTENT"
assert_not_contains "antigravity git status failure not eligible" "ELIGIBLE" "$(grep -F "ag-fail-status" <<<"$OUT_PROBE_CONTENT" || true)"

assert_contains "antigravity missing main ref preserved" "ag-missing-main | main-ref-missing" "$OUT_PROBE_CONTENT"
assert_not_contains "antigravity missing main ref not eligible" "ELIGIBLE" "$(grep -F "ag-missing-main" <<<"$OUT_PROBE_CONTENT" || true)"

assert_contains "antigravity dangling gitdir status failure preserved" "ag-dangling-repo | status-failed" "$OUT_PROBE_CONTENT"
assert_not_contains "antigravity dangling gitdir not eligible" "ELIGIBLE" "$(grep -F "ag-dangling-repo" <<<"$OUT_PROBE_CONTENT" || true)"

assert_contains "antigravity unstaged typechange T preserved" "ag-type-unstaged | dirty" "$OUT_PROBE_CONTENT"
assert_not_contains "antigravity unstaged typechange T not eligible" "ELIGIBLE" "$(grep -F "ag-type-unstaged" <<<"$OUT_PROBE_CONTENT" || true)"

assert_contains "antigravity staged typechange T preserved" "ag-type-staged | dirty" "$OUT_PROBE_CONTENT"
assert_not_contains "antigravity staged typechange T not eligible" "ELIGIBLE" "$(grep -F "ag-type-staged" <<<"$OUT_PROBE_CONTENT" || true)"

assert_contains "antigravity clean ancestor eligible" "ag-clean-ancestor" "$OUT_PROBE_CONTENT"
assert_contains "antigravity clean ancestor has ELIGIBLE" "antigravity  ELIGIBLE" "$(grep -F "ag-clean-ancestor" <<<"$OUT_PROBE_CONTENT" || true)"
assert_contains "registered Antigravity worktree preserved active" "ag-registered | active" "$OUT_PROBE_CONTENT"
assert_contains "ignored file-like directory preserved" "ag-ignored-data | ignored-data" "$OUT_PROBE_CONTENT"
assert_not_contains "ignored file-like directory not eligible" "ELIGIBLE" "$(grep -F "ag-ignored-data" <<<"$OUT_PROBE_CONTENT" || true)"
assert_contains "ignored .env under allowed node_modules preserved" "ag-hidden-env | hidden-state" "$OUT_PROBE_CONTENT"
assert_not_contains "hidden ignored .env not eligible" "ELIGIBLE" "$(grep -F "ag-hidden-env" <<<"$OUT_PROBE_CONTENT" || true)"
assert_contains "assume-unchanged tracked edit preserved" "ag-hidden-index | hidden-state" "$OUT_PROBE_CONTENT"
assert_not_contains "assume-unchanged worktree not eligible" "ELIGIBLE" "$(grep -F "ag-hidden-index" <<<"$OUT_PROBE_CONTENT" || true)"
assert_contains "non-Git Antigravity orphan preserved" "ag-non-git | not-git" "$OUT_PROBE_CONTENT"
assert_not_contains "non-Git Antigravity orphan not eligible" "ELIGIBLE" "$(grep -F "ag-non-git" <<<"$OUT_PROBE_CONTENT" || true)"

echo
echo "=== Result: $PASS pass, $FAIL fail ==="
[[ "$FAIL" -eq 0 ]]
