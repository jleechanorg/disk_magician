# Deploy Guard Implementation Plan (disk_magician-tli)

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Route the repo's canonical deploy procedure through the existing
`tools/deploy_uv_tool.sh` fail-closed guard (instead of a bare
`uv tool install`), add a sanctioned branch-override, and record what is
actually deployed so `check_launchd_fleet.sh` can report it.

**Root cause (see design doc, same date, same directory):**
`tools/deploy_uv_tool.sh` already refuses a dirty tree and already refuses
`HEAD` != `origin/main` (PR #31/#37, 2026-07-26). PR #68's branch build
reached production on 2026-09-11 not because that logic failed, but
because `CLAUDE.md` § Deployment's own checked-in text instructs a bare
`uv tool install --force --reinstall <repo path>`, bypassing the guard
entirely. This plan fixes the documentation and adds the two capabilities
`disk_magician-tli` names that don't exist yet: a sanctioned override, and
a durable deployed-state record.

**Architecture:** All logic changes live in `tools/deploy_uv_tool.sh`
(existing file, not owned by any other in-flight lane). `CLAUDE.md` gets
one paragraph replaced verbatim. `check_launchd_fleet.sh` gets a
read-only reporting snippet handed off to its owning lane, not applied
here.

**Tech Stack:** Bash, git, `uv`, Python 3 (stdlib `json` only, no new deps).

---

### Task 1: Add `DEPLOY_FROM_BRANCH_APPROVED` override with a loud warning

**Files:**
- Modify: `tools/deploy_uv_tool.sh`
- Test: `tests/test_deploy_uv_tool.sh`

**Current relevant block in `tools/deploy_uv_tool.sh`** (for exact
context — do not change anything outside what's described below):

```bash
head_sha="$(git -C "$REPO_ROOT" rev-parse HEAD)"
main_sha="$(git -C "$REPO_ROOT" rev-parse refs/remotes/origin/main)"
if [[ "$head_sha" != "$main_sha" ]]; then
  echo "deploy_uv_tool: refusing HEAD $head_sha; expected origin/main $main_sha" >&2
  exit 1
fi
```

1. **Restructure the existing "ahead" test case first (TDD: make the
   fixture realistic before adding new assertions).** In
   `tests/test_deploy_uv_tool.sh`, the block that currently does:

   ```bash
   echo '# ahead' >> "$TREE/pyproject.toml"
   git -C "$TREE" add pyproject.toml
   git -C "$TREE" commit -qm "local branch ahead"
   ```

   creates the "ahead" commit directly on `main`, so
   `git rev-parse --abbrev-ref HEAD` still reports `main` even though
   `HEAD` has diverged from `origin/main` — that hides the real-world
   shape of the incident (branch `fix/harness-snapshot-floor-gate`, not
   `main`). Change it to commit on a realistically-named branch:

   ```bash
   git -C "$TREE" checkout -q -b feature/branch-test
   echo '# ahead' >> "$TREE/pyproject.toml"
   git -C "$TREE" add pyproject.toml
   git -C "$TREE" commit -qm "local branch ahead"
   ```

   Leave the existing "branch-ahead source is refused" assertion
   immediately after this unchanged — it must still pass unmodified,
   proving the override doesn't weaken the default-refuse behavior. Run
   `bash tests/test_deploy_uv_tool.sh`; this restructuring alone must
   still be green (no new behavior yet, just a more realistic fixture).

2. **Add the failing test for the override**, inserted directly after the
   existing "branch-ahead source is refused" block, still on
   `feature/branch-test` (do not reset/checkout yet):

   ```bash
   OVERRIDE_OUT="$WORK/override.out"
   if DEPLOY_FROM_BRANCH_APPROVED=1 "$TREE/scripts/deploy_uv_tool.sh" --check \
     >"$OVERRIDE_OUT" 2>&1; then
     if grep -qi "WARNING" "$OVERRIDE_OUT" && grep -q "feature/branch-test" "$OVERRIDE_OUT"; then
       ok "DEPLOY_FROM_BRANCH_APPROVED=1 overrides with a WARNING naming the branch"
     else
       bad "DEPLOY_FROM_BRANCH_APPROVED=1 overrides with a WARNING naming the branch" \
         "missing WARNING/branch name: $(cat "$OVERRIDE_OUT")"
     fi
   else
     bad "DEPLOY_FROM_BRANCH_APPROVED=1 overrides with a WARNING naming the branch" \
       "command unexpectedly failed: $(cat "$OVERRIDE_OUT")"
   fi
   ```

   Run `bash tests/test_deploy_uv_tool.sh`; expect this new case to FAIL
   (env var doesn't exist yet, script still refuses).

3. **Implement in `tools/deploy_uv_tool.sh`.** Near the top, after the
   existing `CHECK_ONLY` parsing, add:

   ```bash
   BRANCH_OVERRIDE=false
   [[ "${DEPLOY_FROM_BRANCH_APPROVED:-0}" == "1" ]] && BRANCH_OVERRIDE=true
   ```

   Replace the `head_sha`/`main_sha` block quoted above with:

   ```bash
   head_sha="$(git -C "$REPO_ROOT" rev-parse HEAD)"
   main_sha="$(git -C "$REPO_ROOT" rev-parse refs/remotes/origin/main)"
   current_branch="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD)"
   if [[ "$head_sha" != "$main_sha" ]]; then
     if [[ "$BRANCH_OVERRIDE" != true ]]; then
       echo "deploy_uv_tool: refusing HEAD $head_sha ($current_branch); expected origin/main $main_sha. Set DEPLOY_FROM_BRANCH_APPROVED=1 for an explicitly-approved branch deploy." >&2
       exit 1
     fi
     echo "deploy_uv_tool: WARNING — deploying from branch '$current_branch' ($head_sha), NOT origin/main ($main_sha). DEPLOY_FROM_BRANCH_APPROVED=1 was set." >&2
   fi
   ```

   Also update the file's top-of-file comment block to document the new
   env var (mirror the existing terse style, e.g. add a line: `# Env:
   DEPLOY_FROM_BRANCH_APPROVED=1 — deploy from a non-origin/main HEAD`).

4. Re-run `bash tests/test_deploy_uv_tool.sh`; expect all cases green,
   including the restructured "ahead" case and the new override case.

5. Run `shellcheck --severity=error --external-sources tools/deploy_uv_tool.sh`;
   fix any error-level findings before proceeding.

6. Commit the focused change.

---

### Task 2: Record deployed SHA/version/branch/approval to state JSON

**Files:**
- Modify: `tools/deploy_uv_tool.sh`
- Test: `tests/test_deploy_uv_tool.sh`

**Current relevant tail of `tools/deploy_uv_tool.sh`** (for exact
context):

```bash
smoke_bin="$tool_root/bin/disk-magician"
if [[ -x "$smoke_bin" ]]; then
  if ! "$smoke_bin" --help >/dev/null 2>&1; then
    echo "deploy_uv_tool: SMOKE FAILED — $smoke_bin --help did not execute cleanly" >&2
    exit 1
  fi
else
  echo "deploy_uv_tool: SMOKE FAILED — deployed entrypoint missing/not executable: $smoke_bin" >&2
  exit 1
fi

echo "deploy_uv_tool: deployed head=$head_sha version=$version smoke=ok verified_root=$deployed_root"
```

1. **Write the failing test first.** After the existing "installed-only
   stale package file is refused" block in `tests/test_deploy_uv_tool.sh`
   (which intentionally leaves `TOOL_ROOT`/`UV_STUB` in a failed state —
   do not reuse them for the new cases below; create fresh
   `TOOL_ROOT2`/`UV_STUB_CLEAN` directories under `$WORK`), add, still
   with `TREE` checked out to `main` at `origin/main` (i.e. after
   restoring from `feature/branch-test`):

   ```bash
   git -C "$TREE" checkout -q main

   TOOL_ROOT2="$WORK/tool-root-clean"
   UV_STUB_CLEAN="$WORK/uv-clean"
   mkdir -p "$TOOL_ROOT2/bin" "$TOOL_ROOT2/lib/python3.13/site-packages/disk_magician"
   cp "$TOOL_ROOT/bin/python" "$TOOL_ROOT2/bin/python"
   cat > "$UV_STUB_CLEAN" <<'EOF'
   #!/usr/bin/env bash
   repo="${!#}"
   deployed="$DISK_MAGICIAN_TOOL_ROOT/lib/python3.13/site-packages/disk_magician"
   mkdir -p "$deployed"
   cp -R "$repo/src/disk_magician/." "$deployed/"
   EOF
   chmod +x "$UV_STUB_CLEAN"

   DEPLOYED_JSON="$WORK/deployed.json"
   CLEAN_OUT="$WORK/clean.out"
   if DISK_MAGICIAN_UV_BIN="$UV_STUB_CLEAN" DISK_MAGICIAN_TOOL_ROOT="$TOOL_ROOT2" \
     DISK_MAGICIAN_DEPLOYED_JSON="$DEPLOYED_JSON" \
     "$TREE/scripts/deploy_uv_tool.sh" >"$CLEAN_OUT" 2>&1; then
     ok "clean full deploy succeeds"
   else
     bad "clean full deploy succeeds" "$(cat "$CLEAN_OUT")"
   fi

   EXPECTED_SHA="$(git -C "$TREE" rev-parse HEAD)"
   if [[ -f "$DEPLOYED_JSON" ]] \
     && grep -q "\"sha\": \"$EXPECTED_SHA\"" "$DEPLOYED_JSON" \
     && grep -q '"branch": "main"' "$DEPLOYED_JSON" \
     && grep -q '"approved_from_branch": false' "$DEPLOYED_JSON" \
     && grep -q '"version": "9.9.9"' "$DEPLOYED_JSON"; then
     ok "deployed.json records sha/branch/version/approved_from_branch=false"
   else
     bad "deployed.json records sha/branch/version/approved_from_branch=false" \
       "$(cat "$DEPLOYED_JSON" 2>&1 || echo MISSING)"
   fi
   ```

   Run `bash tests/test_deploy_uv_tool.sh`; expect the two new assertions
   to FAIL (`DISK_MAGICIAN_DEPLOYED_JSON` is not yet read/written).

2. **Write the failing test for the override path**, appended directly
   after the above, reusing the `feature/branch-test` branch shape by
   recreating it (the earlier checkout back to `main` already discarded
   the working branch tip, but the branch ref itself may still exist —
   recreate cleanly to be independent of Task 1's cleanup choices):

   ```bash
   git -C "$TREE" checkout -q -B feature/branch-test-2 main
   echo '# ahead2' >> "$TREE/pyproject.toml"
   git -C "$TREE" add pyproject.toml
   git -C "$TREE" commit -qm "local branch ahead 2"

   TOOL_ROOT3="$WORK/tool-root-override"
   mkdir -p "$TOOL_ROOT3/bin" "$TOOL_ROOT3/lib/python3.13/site-packages/disk_magician"
   cp "$TOOL_ROOT/bin/python" "$TOOL_ROOT3/bin/python"
   DEPLOYED_JSON2="$WORK/deployed-override.json"
   OVERRIDE_DEPLOY_OUT="$WORK/override-deploy.out"
   if DEPLOY_FROM_BRANCH_APPROVED=1 \
     DISK_MAGICIAN_UV_BIN="$UV_STUB_CLEAN" DISK_MAGICIAN_TOOL_ROOT="$TOOL_ROOT3" \
     DISK_MAGICIAN_DEPLOYED_JSON="$DEPLOYED_JSON2" \
     "$TREE/scripts/deploy_uv_tool.sh" >"$OVERRIDE_DEPLOY_OUT" 2>&1; then
     ok "approved branch full deploy succeeds"
   else
     bad "approved branch full deploy succeeds" "$(cat "$OVERRIDE_DEPLOY_OUT")"
   fi
   if [[ -f "$DEPLOYED_JSON2" ]] \
     && grep -q '"branch": "feature/branch-test-2"' "$DEPLOYED_JSON2" \
     && grep -q '"approved_from_branch": true' "$DEPLOYED_JSON2"; then
     ok "deployed.json records approved_from_branch=true and real branch name"
   else
     bad "deployed.json records approved_from_branch=true and real branch name" \
       "$(cat "$DEPLOYED_JSON2" 2>&1 || echo MISSING)"
   fi
   git -C "$TREE" checkout -q main
   ```

   Run the test file; expect these two assertions to also FAIL.

3. **Implement in `tools/deploy_uv_tool.sh`.** Replace the tail block
   quoted at the top of this task with:

   ```bash
   smoke_bin="$tool_root/bin/disk-magician"
   if [[ -x "$smoke_bin" ]]; then
     if ! "$smoke_bin" --help >/dev/null 2>&1; then
       echo "deploy_uv_tool: SMOKE FAILED — $smoke_bin --help did not execute cleanly" >&2
       exit 1
     fi
   else
     echo "deploy_uv_tool: SMOKE FAILED — deployed entrypoint missing/not executable: $smoke_bin" >&2
     exit 1
   fi

   deployed_json="${DISK_MAGICIAN_DEPLOYED_JSON:-$HOME/.disk_magician_state/deployed.json}"
   mkdir -p "$(dirname "$deployed_json")"
   deployed_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
   python3 - "$deployed_json" "$version" "$head_sha" "$current_branch" "$BRANCH_OVERRIDE" "$deployed_at" <<'EOF_PY'
   import json
   import sys

   path, version, sha, branch, approved, deployed_at = sys.argv[1:7]
   with open(path, "w") as f:
       json.dump(
           {
               "version": version,
               "sha": sha,
               "branch": branch,
               "approved_from_branch": approved == "true",
               "deployed_at": deployed_at,
           },
           f,
           indent=2,
       )
       f.write("\n")
   EOF_PY

   echo "deploy_uv_tool: deployed head=$head_sha version=$version smoke=ok verified_root=$deployed_root state=$deployed_json"
   ```

   Note: this write is the **last** statement in the script and every
   preceding line already `exit 1`s on failure, so a failed deploy (dirty
   tree, branch refusal, version mismatch, file-diff mismatch, smoke
   failure) never reaches it and never touches `deployed.json` — no
   separate negative test is needed beyond the existing "installed-only
   stale package file is refused" case, which already exits before this
   point.

4. Re-run `bash tests/test_deploy_uv_tool.sh`; expect all cases green.

5. Run `shellcheck --severity=error --external-sources tools/deploy_uv_tool.sh`
   again (the heredoc is Python, shellcheck will treat it as an opaque
   here-doc body — confirm it doesn't misparse the surrounding bash).

6. Commit the focused change.

---

### Task 3: Route `CLAUDE.md`'s canonical deploy procedure through the guard

**Files:**
- Modify: `CLAUDE.md` (repo root)

No test — this is a documentation-only change; `/es` documentation-only
proportionality applies (no CI required for prose).

1. In the `## Deployment — commit is NOT deploy (two consumers, two
   paths)` section, replace this exact paragraph:

   ```
   After changing root scripts: run `scripts/sync_package_tree.sh` (use
   `--check` in review), **bump the version in pyproject.toml** (uv caches
   wheels by version), then `uv tool install --force --reinstall <repo path>`.
   Verify the deployed tree, not the repo, before claiming production behavior
   (stale-deploy incident 2026-07-11: v2 code was committed for hours while
   production ran v1).
   ```

   with:

   ```
   After changing root scripts: run `scripts/sync_package_tree.sh` (use
   `--check` in review), **bump the version in pyproject.toml** (uv caches
   wheels by version), commit and merge to `main`, then deploy with
   `tools/deploy_uv_tool.sh` — never a bare `uv tool install`. The script
   fails closed unless the source checkout is a clean `HEAD` exactly
   matching `origin/main` (set `DEPLOY_FROM_BRANCH_APPROVED=1` only for an
   intentional, explicitly-approved branch-testing deploy; it is recorded
   as such and is never silent), then verifies the installed version, diffs
   every deployed file against `src/disk_magician/`, and smoke-tests the
   installed entrypoint before reporting success. It records the deployed
   SHA/version/branch to `~/.disk_magician_state/deployed.json`
   (`check_launchd_fleet.sh` reports this line). Verify the deployed tree,
   not the repo, before claiming production behavior (stale-deploy incident
   2026-07-11: v2 code was committed for hours while production ran v1;
   recurrence 2026-09-11: a PR branch build reached production because this
   section's own prior text told agents to run `uv tool install` directly,
   bypassing the guard — bead `disk_magician-tli`).
   ```

2. Commit the focused change (documentation only).

---

### Task 4: Hand off `check_launchd_fleet.sh` reporting line (do not apply here)

**Files:** none in this worktree — `check_launchd_fleet.sh` is owned by a
concurrent lane. Deliver the exact snippet below to the integrator.

Insert immediately after the existing
`echo "  Fleet: $ok/$total loaded and valid."` line and before the
`if [[ $((missing + not_loaded + invalid)) -gt 0 ]]; then` exit-code
decision, so it can never change the script's exit code:

```bash
deployed_json="${DISK_MAGICIAN_DEPLOYED_JSON:-$HOME/.disk_magician_state/deployed.json}"
if [[ -f "$deployed_json" ]]; then
  python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
print(f"  Deployed: version={d[\"version\"]} sha={d[\"sha\"][:12]} branch={d[\"branch\"]} approved_from_branch={d[\"approved_from_branch\"]} at={d[\"deployed_at\"]}")
' "$deployed_json" 2>/dev/null || echo "  Deployed: $deployed_json exists but is unreadable/malformed"
else
  echo "  Deployed: no record at $deployed_json (never deployed via tools/deploy_uv_tool.sh since this guard shipped)"
fi
```

Suggested follow-up test for that lane's own test file
(`tests/test_check_launchd_fleet.sh`): write a fixture `deployed.json` via
`DISK_MAGICIAN_DEPLOYED_JSON=<tmp path>` and assert the new "Deployed:"
line appears in output, plus a case with no file present asserting the
"no record" line and unchanged exit code.

---

### Task 5: Final local verification

**Files:** none (verification only).

1. `bash tests/test_deploy_uv_tool.sh` — all PASS, `FAIL=0`.
2. `bash scripts/sync_package_tree.sh --check` — must report "0 drifted
   files" (this change never touches anything inside `PATTERNS`).
3. `shellcheck --severity=error --external-sources tools/deploy_uv_tool.sh`
   — zero error-level findings.
4. `python3 -m unittest discover -s tests -p 'test_*.py' -v` — unaffected,
   confirm still green (no Python test targets this script, but the full
   suite is cheap insurance against an unrelated regression).
5. Grep confirmation: `grep -rn "uv tool install --force --reinstall <repo" CLAUDE.md`
   returns nothing (old bare-command text fully replaced); `grep -n "tools/deploy_uv_tool.sh" CLAUDE.md`
   returns at least one hit.
6. Do **not** bump `pyproject.toml`'s version (see design doc rationale —
   `tools/deploy_uv_tool.sh` is outside the packaged tree).
