# State-Repo PR 1 Implementation Plan — `state` module + config chain

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `disk-magician state init|status|remote|push` manages a per-machine git state repo (adopt-or-create, one-time `gh` repo-creation offer, local-only fallback) and all scripts resolve config through the env → XDG → state-repo → packaged-template chain.

**Architecture:** New `scripts/state_repo.sh` (bash, lifecycle) + `scripts/resolve_config.py` (python, config chain, prints the winning config path) + a `state` case in `src/disk_magician/disk_magician.sh`'s dispatcher. Spec: `roadmap/2026-07-21-generic-split-state-repo-design.md` (read it first).

**Tech stack / house rules (MANDATORY):** bash must pass `/bin/bash -n` AND run green under macOS `/bin/bash` 3.2 (no `mapfile`, no `declare -A`, guard empty arrays under `set -u` with `${arr[0]+"${arr[@]}"}`); `shellcheck --severity=error --external-sources` clean; every repo-root `scripts/`/`config.json.template` change synced via `bash scripts/sync_package_tree.sh` before commit (CI enforces `--check`); tests are sandboxed (never touch real `$HOME` — always `env -i HOME=<tmp>`); NEVER bump `pyproject.toml` version (integrator does); PR body must fill `.github/PULL_REQUEST_TEMPLATE.md` Evidence fields with REAL command output, values INLINE on the `**Field:**` line, `**Evidence SHA:**` = full 40-char head. Commit + push after EVERY green unit of work; never hold >30 minutes of uncommitted changes.

---

### Task 1: `state_repo.sh init` — fresh local-only creation

**Files:**
- Create: `scripts/state_repo.sh`
- Test: `tests/test_state_repo.sh`

- [ ] **Step 1: Write the failing test file**

```bash
#!/usr/bin/env bash
# test_state_repo.sh — lifecycle tests for scripts/state_repo.sh (sandboxed).
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SR="$REPO_ROOT/scripts/state_repo.sh"
TMP_ROOT=$(mktemp -d -t state_repo_test.XXXXXX)
trap 'rm -rf "$TMP_ROOT"' EXIT
PASS=0; FAIL=0
ok()  { echo "  PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $1 — $2"; FAIL=$((FAIL+1)); }
run_sr() { # run_sr <home> <fake_bin_or_-> <args...>
  local home="$1" fb="$2"; shift 2
  local path="/usr/bin:/bin"
  [[ "$fb" != "-" ]] && path="$fb:$path"
  env -i HOME="$home" PATH="$path" bash "$SR" "$@"
}

echo "Test 1: init creates a git state repo with MACHINE marker at XDG default"
H1="$TMP_ROOT/h1"; mkdir -p "$H1"
OUT1=$(run_sr "$H1" - init 2>&1); RC1=$?
SD1="$H1/.local/state/disk-magician"
[[ $RC1 -eq 0 ]] && ok "init exits 0" || bad "init exits 0" "rc=$RC1: $OUT1"
[[ -d "$SD1/.git" ]] && ok "git repo created" || bad "git repo created" "no $SD1/.git"
[[ -f "$SD1/MACHINE" ]] && ok "MACHINE marker written" || bad "MACHINE marker" "missing"
C1=$(git -C "$SD1" rev-list --count HEAD 2>/dev/null)
[[ "$C1" == "1" ]] && ok "first commit exists" || bad "first commit" "count=$C1"
echo "$OUT1" | grep -q "local-only" && ok "reports local-only (no gh)" || bad "local-only report" "$OUT1"

echo; echo "=== Result: $PASS pass, $FAIL fail ==="
[[ "$FAIL" -eq 0 ]]
```

- [ ] **Step 2: Run to verify it fails** — `/bin/bash tests/test_state_repo.sh` → expected: FAILs (state_repo.sh missing).

- [ ] **Step 3: Minimal implementation**

```bash
#!/usr/bin/env bash
# state_repo.sh — per-machine state-repo lifecycle (design:
# roadmap/2026-07-21-generic-split-state-repo-design.md).
# Subcommands: init | status | remote <url> | push
set -euo pipefail

STATE_DIR="${DISK_MAGICIAN_STATE_REPO:-${XDG_STATE_HOME:-$HOME/.local/state}/disk-magician}"
log() { echo "[state_repo] $*"; }

git_id() { git -C "$STATE_DIR" -c user.name=disk-magician -c user.email=disk-magician@localhost "$@"; }

cmd_init() {
  if [[ -f "$STATE_DIR/MACHINE" ]]; then
    log "adopted existing state repo: $STATE_DIR"
  else
    mkdir -p "$STATE_DIR"
    [[ -d "$STATE_DIR/.git" ]] || git -C "$STATE_DIR" init -q
    printf 'hostname: %s\ncreated: %s\ntool: disk-magician\n' \
      "$(hostname -s 2>/dev/null || echo unknown)" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$STATE_DIR/MACHINE"
    mkdir -p "$STATE_DIR/config" "$STATE_DIR/snapshots" "$STATE_DIR/ledger" "$STATE_DIR/evidence"
    git_id add -A
    git_id commit -q -m "state repo initialized ($(hostname -s 2>/dev/null || echo unknown))"
    log "initialized state repo: $STATE_DIR"
  fi
  offer_remote
}

offer_remote() {
  if git -C "$STATE_DIR" remote get-url origin >/dev/null 2>&1; then
    log "remote: $(git -C "$STATE_DIR" remote get-url origin)"; return 0
  fi
  log "running local-only (no remote configured)"
}

case "${1:-}" in
  init) cmd_init ;;
  *) echo "usage: state_repo.sh init|status|remote <url>|push" >&2; exit 2 ;;
esac
```

- [ ] **Step 4: Run to verify pass** — `/bin/bash tests/test_state_repo.sh` → `=== Result: 5 pass, 0 fail ===`. Also `shellcheck --severity=error --external-sources scripts/state_repo.sh tests/test_state_repo.sh` → clean.

- [ ] **Step 5: Sync + commit** — `bash scripts/sync_package_tree.sh && git add scripts/state_repo.sh tests/test_state_repo.sh src/disk_magician/scripts/state_repo.sh && git commit -m "feat(state): state_repo.sh init — local-only creation"`

### Task 2: idempotent adopt + `status`

**Files:** Modify `scripts/state_repo.sh`; Test: append to `tests/test_state_repo.sh` (before the Result block)

- [ ] **Step 1: Append failing tests**

```bash
echo "Test 2: second init adopts (no new commit), status reports"
OUT2=$(run_sr "$H1" - init 2>&1)
C2=$(git -C "$SD1" rev-list --count HEAD)
[[ "$C2" == "1" ]] && ok "re-init makes no new commit" || bad "idempotent init" "count=$C2"
echo "$OUT2" | grep -q "adopted existing" && ok "reports adoption" || bad "adoption report" "$OUT2"
OUT2b=$(run_sr "$H1" - status 2>&1); RC2b=$?
[[ $RC2b -eq 0 ]] && ok "status exits 0" || bad "status rc" "$RC2b"
echo "$OUT2b" | grep -q "$SD1" && ok "status names the state dir" || bad "status dir" "$OUT2b"
echo "$OUT2b" | grep -qi "remote: none" && ok "status shows no remote" || bad "status remote" "$OUT2b"
```

- [ ] **Step 2: Run — expect the new asserts FAIL** (`status` unknown).

- [ ] **Step 3: Implement** — add to the `case`: `status) cmd_status ;;` and:

```bash
cmd_status() {
  [[ -f "$STATE_DIR/MACHINE" ]] || { log "no state repo at $STATE_DIR (run: state init)"; exit 1; }
  log "state repo: $STATE_DIR"
  log "commits: $(git -C "$STATE_DIR" rev-list --count HEAD 2>/dev/null || echo 0)"
  local r; r=$(git -C "$STATE_DIR" remote get-url origin 2>/dev/null || true)
  log "remote: ${r:-none}"
}
```

- [ ] **Step 4: Run to pass** (expected `=== Result: 10 pass, 0 fail ===`); shellcheck clean.
- [ ] **Step 5: Sync + commit** — `git commit -m "feat(state): idempotent adopt + status"`

### Task 3: one-time `gh` offer (accept / decline / no-gh) with stubbed gh

**Files:** Modify `scripts/state_repo.sh`; Test: append to `tests/test_state_repo.sh`

- [ ] **Step 1: Append failing tests** (fake `gh` on PATH; `DISK_MAGICIAN_ASSUME_YES`/`NO` drive the prompt non-interactively)

```bash
echo "Test 3: gh present + accept -> creates repo and sets origin"
H3="$TMP_ROOT/h3"; FB3="$TMP_ROOT/fb3"; mkdir -p "$H3" "$FB3"
GH_LOG="$TMP_ROOT/gh3.log"
cat > "$FB3/gh" <<EOF
#!/usr/bin/env bash
echo "gh \$*" >> "$GH_LOG"
case "\$1" in
  auth) exit 0 ;;
  repo) exit 0 ;;
esac
exit 0
EOF
chmod +x "$FB3/gh"
OUT3=$(DISK_MAGICIAN_ASSUME_YES=1 run_sr "$H3" "$FB3" init 2>&1); RC3=$?
[[ $RC3 -eq 0 ]] && ok "init+offer exits 0" || bad "offer rc" "$RC3: $OUT3"
grep -q "repo create" "$GH_LOG" && ok "gh repo create invoked" || bad "gh repo create" "$(cat "$GH_LOG")"
echo "$OUT3" | grep -q "origin" && ok "reports origin wiring" || bad "origin report" "$OUT3"

echo "Test 4: decline is recorded and never re-asked"
H4="$TMP_ROOT/h4"; mkdir -p "$H4"
OUT4=$(DISK_MAGICIAN_ASSUME_NO=1 run_sr "$H4" "$FB3" init 2>&1)
SD4="$H4/.local/state/disk-magician"
[[ -f "$SD4/.offer-declined" ]] && ok "decline marker written" || bad "decline marker" "missing"
OUT4b=$(DISK_MAGICIAN_ASSUME_YES=1 run_sr "$H4" "$FB3" init 2>&1)
echo "$OUT4b" | grep -qi "declined earlier" && ok "no re-nag after decline" || bad "re-nag" "$OUT4b"

echo "Test 5: no gh on PATH -> silent local-only, no crash"
H5="$TMP_ROOT/h5"; mkdir -p "$H5"
OUT5=$(run_sr "$H5" - init 2>&1); RC5=$?
[[ $RC5 -eq 0 ]] && ok "no-gh init exits 0" || bad "no-gh rc" "$RC5"
echo "$OUT5" | grep -q "local-only" && ok "no-gh reports local-only" || bad "no-gh report" "$OUT5"
```

- [ ] **Step 2: Run — expect Test 3/4 FAIL** (no offer logic yet; Test 5 may pass).

- [ ] **Step 3: Implement** — replace `offer_remote` body:

```bash
offer_remote() {
  if git -C "$STATE_DIR" remote get-url origin >/dev/null 2>&1; then
    log "remote: $(git -C "$STATE_DIR" remote get-url origin)"; return 0
  fi
  if [[ -f "$STATE_DIR/.offer-declined" ]]; then
    log "remote offer declined earlier — running local-only (state_repo.sh remote <url> to wire one)"; return 0
  fi
  if ! command -v gh >/dev/null 2>&1 || ! gh auth status >/dev/null 2>&1; then
    log "running local-only (no gh auth; state_repo.sh remote <url> to wire one)"; return 0
  fi
  local host reply repo
  host="$(hostname -s 2>/dev/null || echo unknown)"
  repo="disk-magician-state-${host}"
  if [[ "${DISK_MAGICIAN_ASSUME_YES:-0}" == "1" ]]; then reply=y
  elif [[ "${DISK_MAGICIAN_ASSUME_NO:-0}" == "1" ]]; then reply=n
  else read -r -p "Create private GitHub repo ${repo} for snapshot history? [y/N] " reply || reply=n
  fi
  if [[ "$reply" == "y" || "$reply" == "Y" ]]; then
    if gh repo create "$repo" --private --source "$STATE_DIR" --remote origin --push >/dev/null 2>&1 \
       || { gh repo create "$repo" --private >/dev/null 2>&1 \
            && git -C "$STATE_DIR" remote add origin "https://github.com/$(gh api user --jq .login 2>/dev/null || echo me)/${repo}.git"; }; then
      log "origin wired to ${repo}"
    else
      log "gh repo create failed — running local-only"
    fi
  else
    touch "$STATE_DIR/.offer-declined"
    git_id add .offer-declined && git_id commit -q -m "record remote-offer decline" || true
    log "declined — running local-only"
  fi
}
```

- [ ] **Step 4: Run to pass** (expected `=== Result: 17 pass, 0 fail ===`); shellcheck clean.
- [ ] **Step 5: Sync + commit** — `git commit -m "feat(state): one-time gh remote offer (accept/decline/no-gh)"`

### Task 4: `remote <url>` + `push`

**Files:** Modify `scripts/state_repo.sh`; Test: append to `tests/test_state_repo.sh`

- [ ] **Step 1: Append failing tests** (local bare repo as remote — no network)

```bash
echo "Test 6: remote <url> wires origin; push publishes commits"
H6="$TMP_ROOT/h6"; mkdir -p "$H6"
BARE6="$TMP_ROOT/bare6.git"; git init -q --bare "$BARE6"
run_sr "$H6" - init >/dev/null 2>&1
SD6="$H6/.local/state/disk-magician"
run_sr "$H6" - remote "$BARE6" >/dev/null 2>&1; RC6=$?
[[ $RC6 -eq 0 ]] && ok "remote cmd exits 0" || bad "remote rc" "$RC6"
[[ "$(git -C "$SD6" remote get-url origin)" == "$BARE6" ]] && ok "origin set" || bad "origin" "$(git -C "$SD6" remote get-url origin 2>&1)"
run_sr "$H6" - push >/dev/null 2>&1; RC6b=$?
[[ $RC6b -eq 0 ]] && ok "push exits 0" || bad "push rc" "$RC6b"
[[ "$(git -C "$BARE6" rev-list --count HEAD 2>/dev/null)" == "1" ]] && ok "commit on remote" || bad "remote commits" "none"
```

- [ ] **Step 2: Run — expect FAIL** (`remote`/`push` unknown).
- [ ] **Step 3: Implement** — add cases + functions:

```bash
cmd_remote() {
  [[ -n "${1:-}" ]] || { echo "usage: state_repo.sh remote <url>" >&2; exit 2; }
  git -C "$STATE_DIR" remote remove origin 2>/dev/null || true
  git -C "$STATE_DIR" remote add origin "$1"
  rm -f "$STATE_DIR/.offer-declined"
  log "origin set: $1"
}
cmd_push() {
  git -C "$STATE_DIR" remote get-url origin >/dev/null 2>&1 || { log "no remote configured"; exit 1; }
  local branch; branch=$(git -C "$STATE_DIR" branch --show-current)
  git -C "$STATE_DIR" pull --rebase -q origin "$branch" 2>/dev/null || true
  git -C "$STATE_DIR" push -q -u origin "$branch"
  log "pushed $branch"
}
```
(case additions: `remote) shift; cmd_remote "$@" ;;` and `push) cmd_push ;;`)

- [ ] **Step 4: Run to pass** (`=== Result: 21 pass, 0 fail ===`); shellcheck clean.
- [ ] **Step 5: Sync + commit** — `git commit -m "feat(state): remote wiring + pull-rebase push"`

### Task 5: config chain resolver

**Files:**
- Create: `scripts/resolve_config.py`
- Test: `tests/test_resolve_config.py` (pytest-style module functions; CI's `python3 -m unittest discover` also runs — use unittest.TestCase)

- [ ] **Step 1: Write failing test**

```python
import os, subprocess, tempfile, unittest, pathlib
REPO = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = REPO / "scripts" / "resolve_config.py"

def resolve(env_extra):
    env = {"PATH": "/usr/bin:/bin"}
    env.update(env_extra)
    r = subprocess.run(["python3", str(SCRIPT)], capture_output=True, text=True, env=env)
    return r.returncode, r.stdout.strip()

class TestResolveConfig(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.home = os.path.join(self.tmp, "home"); os.makedirs(self.home)

    def _mk(self, rel):
        p = os.path.join(self.tmp, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        open(p, "w").write("{}")
        return p

    def test_env_override_wins(self):
        explicit = self._mk("explicit/config.json")
        xdg = self._mk("home/.config/disk-magician/config.json")
        rc, out = resolve({"HOME": self.home, "DISK_MAGICIAN_CONFIG": explicit})
        self.assertEqual((rc, out), (0, explicit))

    def test_xdg_beats_state_repo(self):
        xdg = self._mk("home/.config/disk-magician/config.json")
        self._mk("home/.local/state/disk-magician/config/config.json")
        rc, out = resolve({"HOME": self.home})
        self.assertEqual((rc, out), (0, xdg))

    def test_state_repo_beats_packaged(self):
        st = self._mk("home/.local/state/disk-magician/config/config.json")
        rc, out = resolve({"HOME": self.home})
        self.assertEqual((rc, out), (0, st))

    def test_packaged_template_is_last_resort(self):
        rc, out = resolve({"HOME": self.home})
        self.assertEqual(rc, 0)
        self.assertTrue(out.endswith("config.json.template"), out)

if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run to verify fail** — `python3 -m unittest tests.test_resolve_config -v` → errors (script missing).

- [ ] **Step 3: Implement**

```python
#!/usr/bin/env python3
"""Print the winning config path: env -> XDG config -> state repo -> packaged template.

Design: roadmap/2026-07-21-generic-split-state-repo-design.md (env-first is a repo-wide
contract; see LARGE_TMP_* precedent in scripts/cleanup_tmp.sh).
"""
import os, pathlib, sys

def resolve() -> str:
    explicit = os.environ.get("DISK_MAGICIAN_CONFIG")
    if explicit and os.path.isfile(explicit):
        return explicit
    home = pathlib.Path(os.environ.get("HOME", "/"))
    xdg_cfg = pathlib.Path(os.environ.get("XDG_CONFIG_HOME", home / ".config"))
    p = xdg_cfg / "disk-magician" / "config.json"
    if p.is_file():
        return str(p)
    state = pathlib.Path(os.environ.get("DISK_MAGICIAN_STATE_REPO",
             pathlib.Path(os.environ.get("XDG_STATE_HOME", home / ".local/state")) / "disk-magician"))
    p = state / "config" / "config.json"
    if p.is_file():
        return str(p)
    here = pathlib.Path(__file__).resolve().parent.parent
    for cand in (here / "config.json", here / "config.json.template"):
        if cand.is_file():
            return str(cand)
    return ""

if __name__ == "__main__":
    path = resolve()
    if not path:
        sys.exit(1)
    print(path)
```

- [ ] **Step 4: Run to pass** — 4/4. NOTE: `test_packaged_template_is_last_resort` resolves the repo's own template because the script lives in the repo — that's the intended dev-install behavior.
- [ ] **Step 5: Sync + commit** — `git commit -m "feat(config): env->xdg->state-repo->packaged resolution chain"`

### Task 6: dispatcher routing (`disk-magician state …`)

**Files:** Modify `src/disk_magician/disk_magician.sh` AND `disk_magician.sh` (repo root — find the subcommand `case` with `grep -n "audit" disk_magician.sh`); Test: append to `tests/test_state_repo.sh`

- [ ] **Step 1: Append failing test**

```bash
echo "Test 7: disk_magician.sh routes 'state' to state_repo.sh"
H7="$TMP_ROOT/h7"; mkdir -p "$H7"
OUT7=$(env -i HOME="$H7" PATH="/usr/bin:/bin" bash "$REPO_ROOT/disk_magician.sh" state init 2>&1); RC7=$?
[[ $RC7 -eq 0 ]] && ok "dispatcher state init exits 0" || bad "dispatcher rc" "$RC7: $OUT7"
[[ -f "$H7/.local/state/disk-magician/MACHINE" ]] && ok "dispatcher created state repo" || bad "dispatcher create" "missing"
```

- [ ] **Step 2: Run — expect FAIL** (unknown subcommand).
- [ ] **Step 3: Implement** — in the dispatcher's `case` add (mirroring how existing subcommands invoke `scripts/*.sh`):

```bash
  state)
    shift
    exec bash "$SCRIPT_DIR/scripts/state_repo.sh" "$@"
    ;;
```
(Adjust `$SCRIPT_DIR` variable name to whatever the file already uses for its own dir — read the surrounding lines first.)

- [ ] **Step 4: Run full suite to pass** (`=== Result: 23 pass, 0 fail ===`) + `/bin/bash tests/test_cleanup_safety.sh` unaffected.
- [ ] **Step 5: Sync + commit.**

### Task 7: ship the PR

- [ ] Run everything: `for t in tests/test_state_repo.sh tests/test_cleanup_safety.sh tests/test_pressure_sweep.sh tests/test_cleanup_downloads_evidence.sh; do /bin/bash "$t" || exit 1; done && python3 -m unittest discover -s tests -p 'test_*.py' && bash scripts/sync_package_tree.sh --check`
- [ ] Push branch `feat/state-repo-pr1`, open PR with the repo's Evidence template (Claim class: tooling; real counts; full head SHA inline).
- [ ] Do NOT merge — report the PR URL and test counts.

## Self-review notes (done at authoring)

Spec coverage: PR-1 scope = lifecycle + config chain only (snapshot write-path, commit flow, grandfathering, `history diff`, E2E = PRs 2–3, planned after this lands). Type/name consistency: `STATE_DIR`, `MACHINE`, `.offer-declined`, `DISK_MAGICIAN_STATE_REPO`, `DISK_MAGICIAN_CONFIG` used consistently across tasks. No placeholders.
