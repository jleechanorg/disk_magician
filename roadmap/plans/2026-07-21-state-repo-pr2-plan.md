# State-Repo PR 2 Implementation Plan — snapshot write-path + grandfathering

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** the 35-min snapshot job writes `disk_snapshot.json` into `<state repo>/snapshots/`,
refreshes `ledger/topdown-5g.{json,md}` when frontier data is fresh (<36h), writes the
resolved config back to `config/config.json`, retains the newest N=4 frontier evidence
files, commits, and pushes fail-safe (local-on-push-failure, never fatal) — all through the
per-machine state repo built in PR 1 (`scripts/state_repo.sh`, `scripts/resolve_config.py`).
On THIS machine the existing `~/.disk_magician_backup` repo is grandfathered in place via a
`state_repo_path` config key: `backup/<host>/` stays untouched, the new `snapshots/`,
`ledger/`, `config/`, `evidence/` dirs are created beside it in the SAME repo. Spec:
`roadmap/2026-07-21-generic-split-state-repo-design.md` §Snapshot/commit flow,
§Grandfathering, §Error handling, exit criterion 5 (read it first). Builds on the merged PR1
(`scripts/state_repo.sh`, `scripts/resolve_config.py`, `tests/test_state_repo.sh` — currently
33 pass, 0 fail; do not regress it).

**Architecture:**
- `scripts/resolve_state_repo_path.py` (new) — the grandfathering knob. Precedence:
  `DISK_MAGICIAN_STATE_REPO` env (existing PR1 contract) → `state_repo_path` key in
  whichever config file `resolve_config.resolve()` picks as winner → XDG state default
  (`${XDG_STATE_HOME:-$HOME/.local/state}/disk-magician`).
- `scripts/state_repo.sh` (modify) — computes `STATE_DIR` via the new resolver instead of
  its own inline env-only logic. Backward compatible: `DISK_MAGICIAN_STATE_REPO` still wins
  outright, and with no XDG config present the resolver falls through to the exact same XDG
  default PR1 already used, so all 33 existing tests stay green untouched.
- `scripts/render_topdown_ledger.py` (new) — reads `~/.disk_magician_state/frontier_last.json`
  (the file `disk_frontier_scan.py` already writes), and when it is fresh (<36h, same
  threshold `disk_snapshot.sh` already applies to `topdown_coverage` embedding) writes
  `ledger/topdown-5g.json` (a curated subset: `granularity_buckets`, `oversize_indivisible_files`,
  `residual_kb`, `accounting_equation`) and `ledger/topdown-5g.md` (human table, residual last).
  Stale/missing/corrupt frontier data is a silent no-op — existing ledger files are left
  untouched (same fail-open posture `disk_snapshot.sh` already uses for this file).
- `scripts/retain_evidence.py` (new) — copies the current frontier report into `evidence/`
  under a timestamped name, then prunes to the newest N (`--keep`, default 4). Python, not a
  shell pipeline (grep-shim corruption class — memory
  `feedback_2026-07-20_grep_shim_truncates_pipelines_use_python_parsing.md`).
- `scripts/snapshot_commit.sh` (new) — the orchestrator the 35-min job now calls: auto-init
  the state repo (local-only when absent, satisfies design bullet "auto-init local-only"),
  write `snapshots/disk_snapshot.json`, invoke the ledger + evidence helpers, write back the
  resolved config, `git commit`, then a fail-safe guarded push (pre-push secret scan via
  `gitleaks`, remote-optional, push failures degrade to a warning + stay local — never a
  fatal exit, fixing a latent bug in the current code where a push failure kills the whole
  `disk_magician.sh` process via `set -euo pipefail` even though the commit already
  succeeded).
- `disk_magician.sh` (modify) — `BACKUP_DIR` becomes an alias for the resolver's `STATE_DIR`;
  `run_snapshot` delegates to `snapshot_commit.sh` instead of its own inline write+commit+push;
  `run_setup` delegates repo init/gh-offer to `state_repo.sh init` instead of duplicating that
  logic; `audit`/`clean`/`clean-all`/`history` resolve `DISK_SNAPSHOT_JSON` preferring the new
  `snapshots/disk_snapshot.json`, falling back to the legacy `backup/<host>/disk_snapshot.json`
  path so nothing regresses for a repo that hasn't taken a new-layout snapshot yet.

**Tech stack / house rules (MANDATORY, inherited from PR1 + this session's corrections):**
bash must pass `/bin/bash -n` AND run green under macOS `/bin/bash` 3.2 (no `mapfile`, no
`declare -A`, guard empty arrays under `set -u` with `${arr[0]+"${arr[@]}"}`); `shellcheck
--severity=error --external-sources` clean on every new/modified `.sh`; every repo-root
`scripts/`/`config.json.template` change synced via `bash scripts/sync_package_tree.sh`
before commit (CI enforces `--check`; the glob already covers new files under `scripts/*.sh`
and `scripts/*.py` — no extra wiring needed); tests are sandboxed (never touch real `$HOME`
— use a fixture `HOME=<tmp>` with `PATH` prefixed, matching `tests/test_snapshot_audit_coverage.sh`'s
precedent of `PATH="$FAKE_BIN:/opt/homebrew/bin:/usr/bin:/bin"` rather than a bare `env -i`,
since `disk_snapshot.sh` needs real `du`/`df`/`python3`); real `gitleaks` IS installed on this
dev machine at `/opt/homebrew/bin/gitleaks` — any test simulating "no gitleaks available"
MUST force it via `DISK_MAGICIAN_GITLEAKS_BIN=<nonexistent path>`, NOT by trimming `PATH`,
because `find_gitleaks()` also probes hardcoded absolute paths
(`/opt/homebrew/bin/gitleaks`, `/usr/local/bin/gitleaks`, `~/.local/bin/gitleaks`)
independent of `PATH`; NEVER bump `pyproject.toml` version (integrator does); PR body must
fill `.github/PULL_REQUEST_TEMPLATE.md` Evidence fields with REAL command output, values
INLINE on the `**Field:**` line, `**Evidence SHA:**` = full 40-char head. Commit + push
after EVERY green unit of work; never hold >30 minutes of uncommitted changes.

---

### Task 1: `resolve_state_repo_path.py` — the grandfathering resolver

**Files:**
- Create: `scripts/resolve_state_repo_path.py`
- Test: `tests/test_resolve_state_repo_path.py`

- [ ] **Step 1: Write the failing test file**

```python
import json, os, subprocess, tempfile, unittest, pathlib
REPO = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = REPO / "scripts" / "resolve_state_repo_path.py"

def resolve(env_extra):
    env = {"PATH": "/usr/bin:/bin"}
    env.update(env_extra)
    r = subprocess.run(["python3", str(SCRIPT)], capture_output=True, text=True, env=env)
    return r.returncode, r.stdout.strip()

class TestResolveStateRepoPath(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.home = os.path.join(self.tmp, "home")
        os.makedirs(self.home)

    def test_env_override_wins_outright(self):
        rc, out = resolve({"HOME": self.home, "DISK_MAGICIAN_STATE_REPO": "/tmp/explicit-state"})
        self.assertEqual((rc, out), (0, "/tmp/explicit-state"))

    def test_xdg_config_state_repo_path_key_wins_over_default(self):
        cfg_dir = os.path.join(self.home, ".config", "disk-magician")
        os.makedirs(cfg_dir)
        legacy = os.path.join(self.home, "legacy-backup")
        with open(os.path.join(cfg_dir, "config.json"), "w") as f:
            json.dump({"state_repo_path": legacy}, f)
        rc, out = resolve({"HOME": self.home})
        self.assertEqual((rc, out), (0, legacy))

    def test_default_is_xdg_state_home_disk_magician(self):
        rc, out = resolve({"HOME": self.home})
        self.assertEqual(rc, 0)
        self.assertTrue(out.endswith("/disk-magician"), out)
        self.assertIn("/.local/state/", out)

    def test_tilde_in_configured_path_expands_to_home(self):
        cfg_dir = os.path.join(self.home, ".config", "disk-magician")
        os.makedirs(cfg_dir)
        with open(os.path.join(cfg_dir, "config.json"), "w") as f:
            json.dump({"state_repo_path": "~/.disk_magician_backup"}, f)
        rc, out = resolve({"HOME": self.home})
        self.assertEqual((rc, out), (0, os.path.join(self.home, ".disk_magician_backup")))

if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run to verify it fails** — `python3 -m unittest tests.test_resolve_state_repo_path -v`
  → errors (script missing).

- [ ] **Step 3: Minimal implementation**

```python
#!/usr/bin/env python3
"""Print the winning state-repo directory (the grandfathering knob): design
roadmap/2026-07-21-generic-split-state-repo-design.md §Grandfathering.

Precedence: DISK_MAGICIAN_STATE_REPO env (explicit override, same contract
scripts/state_repo.sh already honors) -> `state_repo_path` key in whichever
config file scripts/resolve_config.py picks as the chain winner -> XDG state
default. Reusing resolve_config.resolve() (rather than re-implementing the
env->XDG->state-repo->packaged chain) means a single config file is the one
source of truth for both the app's general settings and this one key.
"""
import json, os, pathlib, sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import resolve_config  # noqa: E402


def resolve() -> str:
    explicit = os.environ.get("DISK_MAGICIAN_STATE_REPO")
    if explicit:
        return explicit
    home = pathlib.Path(os.environ.get("HOME", "/"))
    cfg_path = resolve_config.resolve()
    if cfg_path:
        try:
            with open(cfg_path) as f:
                data = json.load(f)
            configured = data.get("state_repo_path")
            if configured:
                return str(pathlib.Path(configured.replace("~", str(home), 1)))
        except (OSError, ValueError):
            pass
    state_home = pathlib.Path(os.environ.get("XDG_STATE_HOME", home / ".local/state"))
    return str(state_home / "disk-magician")


if __name__ == "__main__":
    print(resolve())
```

- [ ] **Step 4: Run to pass** — `python3 -m unittest tests.test_resolve_state_repo_path -v` → 4/4 OK.
  `shellcheck` N/A (python); `python3 -m py_compile scripts/resolve_state_repo_path.py` clean.

- [ ] **Step 5: Sync + commit** — `bash scripts/sync_package_tree.sh && git add scripts/resolve_state_repo_path.py tests/test_resolve_state_repo_path.py src/disk_magician/scripts/resolve_state_repo_path.py && git commit -m "feat(state): resolve_state_repo_path.py — grandfathering resolver" && git push origin main`

### Task 2: `state_repo.sh` sources `STATE_DIR` from the resolver

**Files:** Modify `scripts/state_repo.sh`; Test: append to `tests/test_state_repo.sh`
(current baseline: 33 pass, 0 fail — verified by running it before this task).

- [ ] **Step 1: Append a failing test** (before the final `Result` block)

```bash
echo "Test 11: state_repo_path config key grandfathers an existing directory"
H11="$TMP_ROOT/h11"; mkdir -p "$H11"
LEGACY11="$TMP_ROOT/legacy11"; mkdir -p "$LEGACY11"
mkdir -p "$H11/.config/disk-magician"
python3 - "$H11/.config/disk-magician/config.json" "$LEGACY11" <<'PY'
import json, sys
json.dump({"state_repo_path": sys.argv[2]}, open(sys.argv[1], "w"))
PY
OUT11=$(run_sr "$H11" - init 2>&1); RC11=$?
[[ $RC11 -eq 0 ]] && ok "grandfathered init exits 0" || bad "grandfathered init rc" "$RC11: $OUT11"
[[ -f "$LEGACY11/MACHINE" ]] && ok "state repo created at the configured legacy dir" || bad "grandfathered dir" "missing MACHINE at $LEGACY11"
[[ ! -d "$H11/.local/state/disk-magician" ]] && ok "XDG default dir NOT created when grandfathered" || bad "no stray XDG dir" "found $H11/.local/state/disk-magician"

echo "Test 12: DISK_MAGICIAN_STATE_REPO env still wins over a configured state_repo_path"
H12="$TMP_ROOT/h12"; mkdir -p "$H12"
LEGACY12="$TMP_ROOT/legacy12"; ENVOVERRIDE12="$TMP_ROOT/envoverride12"
mkdir -p "$H12/.config/disk-magician"
python3 - "$H12/.config/disk-magician/config.json" "$LEGACY12" <<'PY'
import json, sys
json.dump({"state_repo_path": sys.argv[2]}, open(sys.argv[1], "w"))
PY
OUT12=$(env -i HOME="$H12" PATH="/usr/bin:/bin" DISK_MAGICIAN_STATE_REPO="$ENVOVERRIDE12" bash "$SR" init 2>&1); RC12=$?
[[ $RC12 -eq 0 ]] && ok "env-override init exits 0" || bad "env-override rc" "$RC12: $OUT12"
[[ -f "$ENVOVERRIDE12/MACHINE" ]] && ok "env override beats configured state_repo_path" || bad "env override" "missing MACHINE at $ENVOVERRIDE12"
[[ ! -d "$LEGACY12" || ! -f "$LEGACY12/MACHINE" ]] && ok "configured legacy dir untouched by env override" || bad "legacy untouched" "unexpectedly initialized $LEGACY12"
```

- [ ] **Step 2: Run — expect Test 11/12 FAIL** (`state_repo.sh` still ignores `state_repo_path`;
  `run_sr` uses `PATH="/usr/bin:/bin"` so `python3` at `/usr/bin/python3` must resolve the
  script — confirm with `which python3` showing `/usr/bin/python3` is present, already true on
  this machine).

- [ ] **Step 3: Implement** — replace the top-of-file `STATE_DIR=` line:

```bash
#!/usr/bin/env bash
# state_repo.sh — per-machine state-repo lifecycle (design:
# roadmap/2026-07-21-generic-split-state-repo-design.md).
# Subcommands: init | status | remote <url> | push
set -euo pipefail

SR_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="$(python3 "$SR_SCRIPT_DIR/resolve_state_repo_path.py")"
log() { echo "[state_repo] $*"; }
```

  (everything below the original `STATE_DIR=`/`log()` lines is unchanged — `git_id`,
  `cmd_init`, `offer_remote`, `cmd_status`, `cmd_remote`, `cmd_push`, and the dispatch `case`
  all reference `$STATE_DIR` exactly as before, so this is a pure single-line substitution at
  the top of the file plus the new `SR_SCRIPT_DIR` line).

- [ ] **Step 4: Run to pass** — `/bin/bash tests/test_state_repo.sh` → `=== Result: 39 pass, 0 fail ===`
  (33 existing + 6 new assertions across Test 11/12); `shellcheck --severity=error
  --external-sources scripts/state_repo.sh` clean.

- [ ] **Step 5: Sync + commit** — `bash scripts/sync_package_tree.sh && git add scripts/state_repo.sh tests/test_state_repo.sh src/disk_magician/scripts/state_repo.sh && git commit -m "feat(state): state_repo.sh honors state_repo_path grandfathering" && git push origin main`

### Task 3: `render_topdown_ledger.py` — freshness-gated ledger refresh

**Files:**
- Create: `scripts/render_topdown_ledger.py`
- Test: `tests/test_render_topdown_ledger.py`

- [ ] **Step 1: Write the failing test file**

```python
import datetime, json, os, subprocess, tempfile, unittest, pathlib
REPO = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = REPO / "scripts" / "render_topdown_ledger.py"

def run(frontier, out_dir):
    r = subprocess.run(
        ["python3", str(SCRIPT), "--frontier", str(frontier), "--out-dir", str(out_dir)],
        capture_output=True, text=True,
    )
    return r.returncode, r.stdout, r.stderr

class TestRenderTopdownLedger(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.out_dir = os.path.join(self.tmp, "ledger")

    def _fixture(self, age_hours):
        captured = (datetime.datetime.utcnow() - datetime.timedelta(hours=age_hours)).strftime(
            "%Y-%m-%dT%H:%M:%SZ"
        )
        data = {
            "captured_at": captured,
            "hostname": "testhost",
            "disk_used_kb": 500 * 1024 * 1024,
            "residual_kb": 524288,  # 0.5 GiB
            "purgeable_kb": 1024,
            "granularity_buckets": [
                {"path": "/Users/x/big", "measured_kb": 3145728},    # 3.0 GiB
                {"path": "/Users/x/small", "measured_kb": 1048576},  # 1.0 GiB
            ],
            "oversize_indivisible_files": [],
            "accounting_equation": {"displayed_balanced": True},
        }
        path = os.path.join(self.tmp, "frontier_last.json")
        with open(path, "w") as f:
            json.dump(data, f)
        return path

    def test_fresh_report_writes_json_and_md(self):
        frontier = self._fixture(age_hours=1)
        rc, out, err = run(frontier, self.out_dir)
        self.assertEqual(rc, 0, err)
        j = json.load(open(os.path.join(self.out_dir, "topdown-5g.json")))
        self.assertEqual(j["residual_kb"], 524288)
        self.assertEqual(len(j["granularity_buckets"]), 2)
        md = open(os.path.join(self.out_dir, "topdown-5g.md")).read()
        self.assertIn("residual (unattributed)", md)
        self.assertIn("3.0", md)
        self.assertIn("1.0", md)
        self.assertIn("0.5", md)

    def test_stale_report_leaves_ledger_untouched(self):
        frontier = self._fixture(age_hours=40)
        os.makedirs(self.out_dir)
        sentinel = os.path.join(self.out_dir, "topdown-5g.json")
        with open(sentinel, "w") as f:
            f.write('{"prior": true}')
        rc, out, err = run(frontier, self.out_dir)
        self.assertEqual(rc, 0, err)
        self.assertEqual(json.load(open(sentinel)), {"prior": True})

    def test_missing_report_is_a_noop(self):
        rc, out, err = run(os.path.join(self.tmp, "nope.json"), self.out_dir)
        self.assertEqual(rc, 0, err)
        self.assertFalse(os.path.isdir(self.out_dir))

if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run to verify it fails** — `python3 -m unittest tests.test_render_topdown_ledger -v`
  → errors (script missing).

- [ ] **Step 3: Implement**

```python
#!/usr/bin/env python3
"""Refresh ledger/topdown-5g.{json,md} from the frontier scanner's report
(design: roadmap/2026-07-21-generic-split-state-repo-design.md, "Snapshot/commit
flow"). Freshness-gated: silently no-ops (exit 0, ledger files untouched) when
the frontier report is missing, unreadable, or older than 36h — the same
staleness threshold scripts/disk_snapshot.sh already applies when embedding
topdown_coverage into the snapshot JSON, so a stale scan never overwrites a
fresher committed ledger with worse data.
"""
import argparse, datetime, json, os, sys

STALE_HOURS = 36


def gib(kb):
    return (kb or 0) / 1024.0 / 1024.0


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--frontier", required=True)
    p.add_argument("--out-dir", required=True)
    args = p.parse_args()

    try:
        with open(args.frontier) as f:
            report = json.load(f)
    except (OSError, ValueError):
        return 0  # no frontier data yet — leave ledger untouched

    captured_at = report.get("captured_at")
    try:
        ts = datetime.datetime.strptime(captured_at, "%Y-%m-%dT%H:%M:%SZ").replace(
            tzinfo=datetime.timezone.utc
        )
    except (TypeError, ValueError):
        return 0
    age_hours = (datetime.datetime.now(datetime.timezone.utc) - ts).total_seconds() / 3600.0
    if age_hours > STALE_HOURS:
        return 0  # stale — leave prior ledger in place

    buckets = report.get("granularity_buckets") or []
    oversize = report.get("oversize_indivisible_files") or []
    equation = report.get("accounting_equation") or {}

    os.makedirs(args.out_dir, exist_ok=True)

    ledger = {
        "schema_version": 1,
        "captured_at": captured_at,
        "hostname": report.get("hostname"),
        "disk_used_kb": report.get("disk_used_kb"),
        "residual_kb": report.get("residual_kb"),
        "purgeable_kb": report.get("purgeable_kb"),
        "granularity_buckets": buckets,
        "oversize_indivisible_files": oversize,
        "accounting_equation": equation,
    }
    with open(os.path.join(args.out_dir, "topdown-5g.json"), "w") as f:
        json.dump(ledger, f, indent=2)
        f.write("\n")

    lines = [
        f"# Top-down 5 GiB ledger — {report.get('hostname', 'unknown')}",
        f"Captured: {captured_at}",
        "",
        "| Size (GiB) | Path |",
        "|---:|---|",
    ]
    for item in sorted(buckets, key=lambda b: -(b.get("measured_kb") or 0)):
        lines.append(f"| {gib(item.get('measured_kb')):.1f} | {item.get('path')} |")
    for item in oversize:
        lines.append(
            f"| {gib(item.get('measured_kb')):.1f} | {item.get('path')} (indivisible file) |"
        )
    lines.append(f"| {gib(report.get('residual_kb')):.1f} | _residual (unattributed)_ |")
    lines.append("")
    lines.append(f"Balanced: {str(bool(equation.get('displayed_balanced'))).lower()}")
    with open(os.path.join(args.out_dir, "topdown-5g.md"), "w") as f:
        f.write("\n".join(lines) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 4: Run to pass** — `python3 -m unittest tests.test_render_topdown_ledger -v` → 3/3 OK.

- [ ] **Step 5: Sync + commit** — `bash scripts/sync_package_tree.sh && git add scripts/render_topdown_ledger.py tests/test_render_topdown_ledger.py src/disk_magician/scripts/render_topdown_ledger.py && git commit -m "feat(state): render_topdown_ledger.py — freshness-gated ledger refresh" && git push origin main`

### Task 4: `retain_evidence.py` — keep newest N=4 frontier snapshots

**Files:**
- Create: `scripts/retain_evidence.py`
- Test: `tests/test_retain_evidence.py`

- [ ] **Step 1: Write the failing test file**

```python
import glob, os, subprocess, tempfile, unittest, pathlib
REPO = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = REPO / "scripts" / "retain_evidence.py"

def run(frontier, evidence_dir, keep):
    r = subprocess.run(
        ["python3", str(SCRIPT), "--frontier", str(frontier),
         "--evidence-dir", str(evidence_dir), "--keep", str(keep)],
        capture_output=True, text=True,
    )
    return r.returncode, r.stdout, r.stderr

class TestRetainEvidence(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.evidence_dir = os.path.join(self.tmp, "evidence")
        os.makedirs(self.evidence_dir)

    def test_copies_current_report_and_prunes_to_newest_n(self):
        for i in range(6):
            p = os.path.join(self.evidence_dir, f"frontier-old{i}.json")
            with open(p, "w") as f:
                f.write("{}")
            os.utime(p, (1000 + i, 1000 + i))

        frontier = os.path.join(self.tmp, "frontier_last.json")
        with open(frontier, "w") as f:
            f.write('{"captured_at": "now"}')
        os.utime(frontier, (2000, 2000))

        rc, out, err = run(frontier, self.evidence_dir, keep=4)
        self.assertEqual(rc, 0, err)
        remaining = sorted(glob.glob(os.path.join(self.evidence_dir, "frontier-*.json")))
        self.assertEqual(len(remaining), 4)
        newest = max(remaining, key=os.path.getmtime)
        self.assertEqual(os.path.getmtime(newest), 2000.0)

    def test_missing_frontier_still_prunes_existing(self):
        for i in range(5):
            p = os.path.join(self.evidence_dir, f"frontier-x{i}.json")
            with open(p, "w") as f:
                f.write("{}")
            os.utime(p, (1000 + i, 1000 + i))
        rc, out, err = run(os.path.join(self.tmp, "nope.json"), self.evidence_dir, keep=4)
        self.assertEqual(rc, 0, err)
        remaining = glob.glob(os.path.join(self.evidence_dir, "frontier-*.json"))
        self.assertEqual(len(remaining), 4)

    def test_fewer_than_keep_prunes_nothing(self):
        for i in range(2):
            p = os.path.join(self.evidence_dir, f"frontier-y{i}.json")
            with open(p, "w") as f:
                f.write("{}")
        rc, out, err = run(os.path.join(self.tmp, "nope.json"), self.evidence_dir, keep=4)
        self.assertEqual(rc, 0, err)
        remaining = glob.glob(os.path.join(self.evidence_dir, "frontier-*.json"))
        self.assertEqual(len(remaining), 2)

if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run to verify it fails** — `python3 -m unittest tests.test_retain_evidence -v`
  → errors (script missing).

- [ ] **Step 3: Implement**

```python
#!/usr/bin/env python3
"""Copy the current frontier report into evidence/ as a timestamped file, then
prune to the newest N (design: roadmap/2026-07-21-generic-split-state-repo-design.md,
"Snapshot/commit flow" — evidence retention so the state repo cannot itself
become a leak). shutil.copy2 (not copyfile) so the copy preserves the source
mtime, keeping the prune's newest-N-by-mtime ordering meaningful. Python, not a
shell pipeline, per the grep-shim pipeline-corruption precedent (memory
feedback_2026-07-20_grep_shim_truncates_pipelines_use_python_parsing.md).
"""
import argparse, datetime, glob, os, shutil, sys


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--frontier", required=True)
    p.add_argument("--evidence-dir", required=True)
    p.add_argument("--keep", type=int, required=True)
    args = p.parse_args()

    os.makedirs(args.evidence_dir, exist_ok=True)

    if os.path.isfile(args.frontier):
        mtime = os.path.getmtime(args.frontier)
        stamp = datetime.datetime.utcfromtimestamp(mtime).strftime("%Y%m%dT%H%M%SZ")
        dest = os.path.join(args.evidence_dir, f"frontier-{stamp}.json")
        if not os.path.exists(dest):
            shutil.copy2(args.frontier, dest)

    files = sorted(
        glob.glob(os.path.join(args.evidence_dir, "frontier-*.json")),
        key=os.path.getmtime,
        reverse=True,
    )
    for stale in files[args.keep:]:
        os.remove(stale)
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 4: Run to pass** — `python3 -m unittest tests.test_retain_evidence -v` → 3/3 OK.

- [ ] **Step 5: Sync + commit** — `bash scripts/sync_package_tree.sh && git add scripts/retain_evidence.py tests/test_retain_evidence.py src/disk_magician/scripts/retain_evidence.py && git commit -m "feat(state): retain_evidence.py — keep newest N=4 frontier snapshots" && git push origin main`

### Task 5: `snapshot_commit.sh` — orchestrator write-path

**Files:**
- Create: `scripts/snapshot_commit.sh`
- Test: `tests/test_snapshot_commit.sh`

The orchestrator the 35-min job calls. To keep the test hermetic (no real `du`/`df`/frontier scan), it invokes the snapshot writer through a `DISK_MAGICIAN_SNAPSHOT_BIN` indirection (default `scripts/disk_snapshot.sh`) so tests substitute a stub that just writes a fixture JSON to `--output`.

- [ ] **Step 1: Write the failing test**

```bash
#!/usr/bin/env bash
# test_snapshot_commit.sh — orchestrator write-path (sandboxed, stubbed snapshot writer).
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SC="$REPO_ROOT/scripts/snapshot_commit.sh"
TMP_ROOT=$(mktemp -d -t snapshot_commit_test.XXXXXX)
trap 'rm -rf "$TMP_ROOT"' EXIT
PASS=0; FAIL=0
ok()  { echo "  PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $1 — $2"; FAIL=$((FAIL+1)); }

# Stub snapshot writer: honors --output, writes a minimal valid snapshot JSON.
STUB_BIN="$TMP_ROOT/bin"; mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/snap.sh" <<'EOF'
#!/usr/bin/env bash
out=""
while [[ $# -gt 0 ]]; do case "$1" in --output) out="$2"; shift 2 ;; *) shift ;; esac; done
[[ -n "$out" ]] || exit 1
mkdir -p "$(dirname "$out")"
printf '{"disk_free_gb": 100, "schema_version": 2}\n' > "$out"
EOF
chmod +x "$STUB_BIN/snap.sh"

run_sc() { # run_sc <home> <args...>
  env -i HOME="$1" PATH="/usr/bin:/bin" \
    DISK_MAGICIAN_SNAPSHOT_BIN="$STUB_BIN/snap.sh" \
    bash "$SC" "${@:2}"
}

echo "Test 1: fresh run auto-inits state repo, writes snapshot, commits"
H1="$TMP_ROOT/h1"; mkdir -p "$H1"
OUT1=$(run_sc "$H1" 2>&1); RC1=$?
SD1="$H1/.local/state/disk-magician"
[[ $RC1 -eq 0 ]] && ok "exits 0" || bad "rc" "$RC1: $OUT1"
[[ -f "$SD1/snapshots/disk_snapshot.json" ]] && ok "snapshot written under snapshots/" || bad "snapshot path" "missing"
[[ -f "$SD1/config/config.json" ]] && ok "resolved config written" || bad "config path" "missing"
git -C "$SD1" log --oneline | grep -qi snapshot && ok "commit made" || bad "commit" "$(git -C "$SD1" log --oneline 2>&1 | head -1)"
LASTC=$(git -C "$SD1" rev-list --count HEAD)

echo "Test 2: second run commits a NEW snapshot (history accrues)"
OUT2=$(run_sc "$H1" 2>&1)
NEWC=$(git -C "$SD1" rev-list --count HEAD)
[[ "$NEWC" -gt "$LASTC" ]] && ok "history accrued a commit" || bad "history" "count $LASTC -> $NEWC"

echo "Test 3: push failure is non-fatal (commit still local, exit 0)"
H3="$TMP_ROOT/h3"; mkdir -p "$H3"
SD3="$H3/.local/state/disk-magician"
# Point origin at an unwritable/bogus path so push fails.
run_sc "$H3" >/dev/null 2>&1
git -C "$SD3" remote add origin /nonexistent/bare.git 2>/dev/null || true
OUT3=$(run_sc "$H3" 2>&1); RC3=$?
[[ $RC3 -eq 0 ]] && ok "push failure is non-fatal (exit 0)" || bad "non-fatal push" "rc=$RC3"
echo "$OUT3" | grep -qi "push" && ok "push outcome logged" || bad "push log" "$OUT3"
git -C "$SD3" log --oneline | grep -qi snapshot && ok "commit preserved despite push failure" || bad "commit preserved" "none"

echo; echo "=== Result: $PASS pass, $FAIL fail ==="
[[ "$FAIL" -eq 0 ]]
```

- [ ] **Step 2: Run to verify fail** — `/bin/bash tests/test_snapshot_commit.sh` → FAILs (script missing).

- [ ] **Step 3: Implement**

```bash
#!/usr/bin/env bash
# snapshot_commit.sh — orchestrate a state-repo snapshot commit (design:
# roadmap/2026-07-21-generic-split-state-repo-design.md §Snapshot/commit flow).
# Auto-inits the state repo local-only, writes snapshots/disk_snapshot.json,
# refreshes the 5G ledger + evidence retention, writes back resolved config,
# commits, then a FAIL-SAFE push (a push failure never aborts — the commit
# already landed locally; this fixes the latent set -euo pipefail abort in the
# legacy inline path).
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

STATE_DIR="$(python3 "$SCRIPT_DIR/resolve_state_repo_path.py")"
SNAP_BIN="${DISK_MAGICIAN_SNAPSHOT_BIN:-$SCRIPT_DIR/disk_snapshot.sh}"
FRONTIER="${DISK_MAGICIAN_FRONTIER_JSON:-$HOME/.disk_magician_state/frontier_last.json}"
KEEP="${DISK_MAGICIAN_EVIDENCE_KEEP:-4}"
log() { echo "[snapshot_commit] $*"; }
git_id() { git -C "$STATE_DIR" -c user.name=disk-magician -c user.email=disk-magician@localhost "$@"; }

# 1. Ensure the state repo exists (local-only auto-init).
if [[ ! -f "$STATE_DIR/MACHINE" || ! -d "$STATE_DIR/.git" ]]; then
  DISK_MAGICIAN_STATE_REPO="$STATE_DIR" bash "$SCRIPT_DIR/state_repo.sh" init >/dev/null 2>&1 || {
    log "ERROR: state repo init failed for $STATE_DIR"; exit 1; }
fi
mkdir -p "$STATE_DIR/snapshots" "$STATE_DIR/ledger" "$STATE_DIR/config" "$STATE_DIR/evidence"

# 2. Write the snapshot.
if ! bash "$SNAP_BIN" --output "$STATE_DIR/snapshots/disk_snapshot.json"; then
  log "ERROR: snapshot writer failed"; exit 1
fi

# 3. Refresh the 5G ledger (fail-open) and evidence retention.
python3 "$SCRIPT_DIR/render_topdown_ledger.py" --frontier "$FRONTIER" \
  --out-dir "$STATE_DIR/ledger" 2>/dev/null || true
python3 "$SCRIPT_DIR/retain_evidence.py" --frontier "$FRONTIER" \
  --evidence-dir "$STATE_DIR/evidence" --keep "$KEEP" 2>/dev/null || true

# 4. Write back the resolved config.
CFG="$(python3 "$SCRIPT_DIR/resolve_config.py" 2>/dev/null || true)"
[[ -n "$CFG" && -f "$CFG" ]] && cp "$CFG" "$STATE_DIR/config/config.json"

# 5. Commit.
git_id add -A
if git -C "$STATE_DIR" diff --cached --quiet; then
  log "no changes to commit"
else
  git_id commit -q -m "snapshot $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  log "committed snapshot"
fi

# 6. Fail-safe push (never fatal).
if git -C "$STATE_DIR" remote get-url origin >/dev/null 2>&1; then
  if DISK_MAGICIAN_STATE_REPO="$STATE_DIR" bash "$SCRIPT_DIR/state_repo.sh" push >/dev/null 2>&1; then
    log "pushed to origin"
  else
    log "push failed — commit kept local, will retry next run"
  fi
else
  log "local-only (no remote)"
fi
exit 0
```

- [ ] **Step 4: Run to pass** — `/bin/bash tests/test_snapshot_commit.sh` → `=== Result: 8 pass, 0 fail ===`; `shellcheck --severity=error --external-sources scripts/snapshot_commit.sh tests/test_snapshot_commit.sh` clean.

- [ ] **Step 5: Sync + commit** — `bash scripts/sync_package_tree.sh && git add scripts/snapshot_commit.sh tests/test_snapshot_commit.sh src/disk_magician/scripts/snapshot_commit.sh && git commit -m "feat(state): snapshot_commit.sh — orchestrated fail-safe state-repo commit" && git push origin main`

### Task 6: grandfather this machine onto `~/.disk_magician_backup`

**Files:**
- Test: append to `tests/test_snapshot_commit.sh`
- (No production code — this task proves the resolver already grandfathers via config, and documents the one-time setup.)

- [ ] **Step 1: Append the failing test** (before the Result block)

```bash
echo "Test 4: state_repo_path config grandfathers an existing repo in place"
H4="$TMP_ROOT/h4"; mkdir -p "$H4/.config/disk-magician"
LEGACY="$TMP_ROOT/legacy-backup"; mkdir -p "$LEGACY/backup/somehost"
printf '{"pre":"existing"}\n' > "$LEGACY/backup/somehost/disk_snapshot.json"
( cd "$LEGACY" && git init -q -b main && git -c user.email=x@x -c user.name=x add -A && git -c user.email=x@x -c user.name=x commit -qm seed )
printf '{"state_repo_path": "%s"}\n' "$LEGACY" > "$H4/.config/disk-magician/config.json"
OUT4=$(run_sc "$H4" 2>&1); RC4=$?
[[ $RC4 -eq 0 ]] && ok "grandfathered run exits 0" || bad "grandfather rc" "$RC4: $OUT4"
[[ -f "$LEGACY/snapshots/disk_snapshot.json" ]] && ok "new-layout snapshots/ created in legacy repo" || bad "new layout" "missing"
[[ -f "$LEGACY/backup/somehost/disk_snapshot.json" ]] && ok "existing backup/<host>/ left untouched" || bad "legacy preserved" "gone"
[[ "$(cat "$LEGACY/backup/somehost/disk_snapshot.json")" == '{"pre":"existing"}' ]] && ok "legacy content byte-identical" || bad "legacy content" "changed"
```

- [ ] **Step 2: Run** — expect the 4 new asserts PASS immediately (resolver + orchestrator from Tasks 1/5 already handle it). If any fail, the resolver precedence is wrong — fix `resolve_state_repo_path.py`, not the test.

- [ ] **Step 3: Document the one-time setup** — add to `README.md` a `### Grandfathering an existing backup repo` note: `mkdir -p ~/.config/disk-magician && echo '{"state_repo_path": "'$HOME'/.disk_magician_backup"}' > ~/.config/disk-magician/config.json`. (Do NOT run it against the real `~/.disk_magician_backup` in this task — that live-adoption is exit-criterion 5, executed only in Task 8's guarded live check.)

- [ ] **Step 4: Run full suite** — `/bin/bash tests/test_snapshot_commit.sh` → `=== Result: 12 pass, 0 fail ===`.

- [ ] **Step 5: Sync + commit** — `git add tests/test_snapshot_commit.sh src/disk_magician/... README.md && git commit -m "test(state): grandfather existing backup repo in place" && git push origin main`

### Task 7: rewire `disk_magician.sh` to the orchestrator (with legacy fallback)

**Files:**
- Modify: `disk_magician.sh` AND `src/disk_magician/disk_magician.sh` (repo-root is source of truth; sync mirrors it). Read `disk_magician.sh:280-300` (the `run_snapshot`/snapshot dispatch) and `:360-370` first.
- Test: append to `tests/test_state_repo.sh` (dispatcher-routing home, mirrors PR1 Test 7)

- [ ] **Step 1: Append the failing test**

```bash
echo "Test 11: 'disk_magician.sh snapshot' routes through snapshot_commit.sh (new layout)"
H11="$TMP_ROOT/h11"; mkdir -p "$H11"
STUB11="$TMP_ROOT/stub11"; mkdir -p "$STUB11"
cat > "$STUB11/snap.sh" <<'EOF'
#!/usr/bin/env bash
out=""; while [[ $# -gt 0 ]]; do case "$1" in --output) out="$2"; shift 2;; *) shift;; esac; done
mkdir -p "$(dirname "$out")"; printf '{"schema_version":2}\n' > "$out"
EOF
chmod +x "$STUB11/snap.sh"
OUT11=$(env -i HOME="$H11" PATH="/usr/bin:/bin" DISK_MAGICIAN_SNAPSHOT_BIN="$STUB11/snap.sh" \
  bash "$REPO_ROOT/disk_magician.sh" snapshot 2>&1); RC11=$?
[[ $RC11 -eq 0 ]] && ok "dispatcher snapshot exits 0" || bad "dispatcher snapshot rc" "$RC11: $OUT11"
[[ -f "$H11/.local/state/disk-magician/snapshots/disk_snapshot.json" ]] && ok "snapshot in new-layout state repo" || bad "new-layout snapshot" "missing"
```

- [ ] **Step 2: Run — expect FAIL** (legacy `run_snapshot` writes to `backup/<host>/`, not the state repo).

- [ ] **Step 3: Implement** — in BOTH `disk_magician.sh` copies, change the snapshot dispatch (around `:296`) from the inline `disk_snapshot.sh --output "$snap_dest"` + inline commit to:

```bash
  snapshot)
    exec bash "$SCRIPT_DIR/scripts/snapshot_commit.sh"
    ;;
```
Keep the legacy `backup/<host>/disk_snapshot.json` read path in `audit`/`history` as a FALLBACK: resolve `DISK_SNAPSHOT_JSON` preferring `<state_dir>/snapshots/disk_snapshot.json`, else the legacy path — so a repo that hasn't taken a new-layout snapshot yet still reads its last one. (Read the surrounding `case`/variable names first; adapt `$SCRIPT_DIR` to whatever the file uses.)

- [ ] **Step 4: Run to pass** — `/bin/bash tests/test_state_repo.sh` → all green (was 33, now 35); `/bin/bash tests/test_cleanup_safety.sh` unaffected; `bash scripts/sync_package_tree.sh --check` clean.

- [ ] **Step 5: Sync + commit** — `git commit -m "feat(state): route snapshot through snapshot_commit.sh + legacy read fallback"`

### Task 8: guarded live grandfather check (exit criterion 5)

**Files:** Create `tests/test_grandfather_live.sh` (guarded; opt-in only, never runs in CI unless `DM_LIVE_GRANDFATHER=1`).

- [ ] **Step 1: Write the guarded live test**

```bash
#!/usr/bin/env bash
# test_grandfather_live.sh — exit criterion 5: on THIS machine, prove the real
# ~/.disk_magician_backup adopts the new layout with backup/<host>/ untouched.
# GUARDED: no-op unless DM_LIVE_GRANDFATHER=1 (protects the real repo in CI).
set -uo pipefail
if [[ "${DM_LIVE_GRANDFATHER:-0}" != "1" ]]; then
  echo "SKIP: set DM_LIVE_GRANDFATHER=1 to run the live grandfather check"; exit 0
fi
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BK="$HOME/.disk_magician_backup"
[[ -d "$BK/.git" ]] || { echo "FAIL: $BK is not a git repo"; exit 1; }
HOST="$(hostname -s)"
before="$(git -C "$BK" rev-parse HEAD)"
legacy_before="$(cat "$BK/backup/$HOST/disk_snapshot.json" 2>/dev/null | shasum | cut -d' ' -f1)"
mkdir -p "$HOME/.config/disk-magician"
printf '{"state_repo_path": "%s"}\n' "$BK" > "$HOME/.config/disk-magician/config.json"
bash "$REPO_ROOT/scripts/snapshot_commit.sh"
[[ -f "$BK/snapshots/disk_snapshot.json" ]] || { echo "FAIL: new-layout snapshot not created"; exit 1; }
legacy_after="$(cat "$BK/backup/$HOST/disk_snapshot.json" 2>/dev/null | shasum | cut -d' ' -f1)"
[[ "$legacy_before" == "$legacy_after" ]] || { echo "FAIL: legacy backup/$HOST/ changed"; exit 1; }
echo "PASS: grandfathered in place, legacy layout untouched (was $before)"
```

- [ ] **Step 2: Run guarded (default skip)** — `/bin/bash tests/test_grandfather_live.sh` → `SKIP: ...`.
- [ ] **Step 3: Run live once** — `DM_LIVE_GRANDFATHER=1 /bin/bash tests/test_grandfather_live.sh` → `PASS: grandfathered in place...`. Capture this output for the PR Evidence section (exit criterion 5). NOTE: this creates `~/.config/disk-magician/config.json` on the real machine — that is the intended grandfather setup for this host; leave it.
- [ ] **Step 4: shellcheck** clean.
- [ ] **Step 5: Commit** — `git commit -m "test(state): guarded live grandfather check (exit criterion 5)"`

### Task 9: ship the PR

- [ ] Full battery: `for t in tests/test_state_repo.sh tests/test_snapshot_commit.sh tests/test_cleanup_safety.sh tests/test_pressure_sweep.sh tests/test_cleanup_downloads_evidence.sh tests/test_cleanup_tmp_large_protections.sh; do /bin/bash "$t" || exit 1; done && python3 -m unittest discover -s tests -p 'test_*.py' && bash scripts/sync_package_tree.sh --check`
- [ ] Confirm the launchd job still works: `DISK_MAGICIAN_SNAPSHOT_BIN` unset, run `bash disk_magician.sh snapshot` once against a scratch `HOME` (or observe the next real 35-min tick's commit in `~/.disk_magician_backup` git log if grandfather setup ran).
- [ ] Push branch `feat/state-repo-pr2`, open PR with the Evidence template (Claim class: tooling; real counts INLINE; full 40-char head SHA; include the DM_LIVE_GRANDFATHER=1 output as exit-criterion-5 proof; What-this-does-not-prove: the E2E fresh-user install is PR 3).
- [ ] Do NOT merge — report the PR URL and test counts.

## Self-review notes (authoring)

Spec coverage: §Snapshot/commit flow → Tasks 5,7; §Grandfathering → Tasks 1,6,8; evidence retention → Task 4; ledger refresh → Task 3; config chain write-back → Task 5 step 4; error handling (push non-fatal) → Task 5 step 6 + Test 3; exit criterion 5 → Task 8. Deferred to PR 3 (correctly out of scope here): `history diff`, fresh-user E2E install (exit criteria 1-3). Name consistency: `STATE_DIR`, `resolve_state_repo_path.py`, `snapshot_commit.sh`, `DISK_MAGICIAN_SNAPSHOT_BIN`, `state_repo_path` used consistently across tasks. No placeholders.
