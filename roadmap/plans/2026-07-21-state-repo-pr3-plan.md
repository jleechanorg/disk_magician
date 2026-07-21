# State-Repo PR 3 Implementation Plan — `history diff` + sandbox E2E + README

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `disk-magician history diff [ref]` compares two committed
`ledger/topdown-5g.json` snapshots in the per-machine state repo (git
`show ref:path`, pure Python, no shell pipelines) and prints bucket-level
growth deltas sorted by growth with the residual delta last. A sandbox E2E
harness (`tests/test_state_repo_e2e.sh`) proves design-doc Exit Criteria 1–3
end to end. `README.md` gains a quick-start for strangers.

**Architecture:** New `scripts/history_diff.py` (stdlib-only Python: ledger
load/validate, delta computation, CLI) + a `diff` sub-case inside the
existing `history)` branch of `disk_magician.sh`'s dispatcher (root file is
canonical; `scripts/sync_package_tree.sh` mirrors it into
`src/disk_magician/`). Spec: `roadmap/2026-07-21-generic-split-state-repo-design.md`
(read it first — "Diff UX", "Exit criteria 1–3", "Delivery PR 3"). PR-1
(merged) code this plan builds on: `scripts/state_repo.sh`,
`scripts/resolve_config.py`.

## Ledger contract this PR assumes (PR-2 is the producer, not yet merged)

`ledger/topdown-5g.json`, committed inside the state repo by the (in-flight)
PR-2 snapshot flow:

```json
{
  "schema_version": 1,
  "captured_at": "2026-07-21T00:00:00Z",
  "hostname": "sandbox-host",
  "disk_used_kb": 104857600,
  "residual_kb": 1048576,
  "residual_label": "protected_or_apfs_allocation_not_attributable_by_this_session",
  "buckets": [
    {"path": "/Users/x/Library/Caches", "measured_kb": 3000000, "kind": "dir"},
    {"path": "/Users/x/projects", "measured_kb": 2097152, "kind": "dir"},
    {"path": "/Users/x/big_export.img", "measured_kb": 7000000, "kind": "file"}
  ]
}
```

Keys deliberately reuse `path`/`measured_kb` from the existing
`top_level_ledger`/`granularity_buckets` entries in
`scripts/disk_frontier_scan.py:1302-1322` so PR-2 can adapt the frontier
report into this shape instead of inventing new field names. Contract
(enforced by `history_diff.py validate_ledger()`, fail-closed):

- Every bucket has a `path` and an integer `measured_kb` (no nulls — a
  `status: unfinished/deduped` frontier entry with no concrete size must not
  be written into this ledger; that filtering is PR-2's job).
- Optional `kind`: `"dir"` (default when absent) or `"file"`. A `"dir"`
  bucket's `measured_kb` must be strictly `< 5 * 1024 * 1024` KiB (5 GiB) —
  at/above that ceiling it's an "unexplained aggregate" that should have been
  broken down into child buckets, and the whole ledger is refused, matching
  design-doc line "renderer fails closed on any opaque ≥5 GiB aggregate". A
  `"file"` bucket is exempt from the ceiling — a single indivisible file is
  already a leaf and cannot be broken down further, mirroring the
  `oversize_indivisible_files` category `scripts/disk_frontier_scan.py`
  already tracks separately from its `<=5 GiB` `granularity_buckets`
  (`scripts/disk_frontier_scan.py:1323-1327`).
- `sum(buckets[].measured_kb) + residual_kb == disk_used_kb` exactly.

**Resolved ambiguity (flagging for the PR-2 author / integrator):** PR-2 is
still in flight, so `test_state_repo_e2e.sh` in this plan cannot call a real
`disk-magician snapshot` to produce `ledger/topdown-5g.json` — that code
doesn't exist yet. Task 5 below builds the ledger via a single seam function,
`write_fixture_ledger()`, that fabricates a schema-valid ledger JSON and
commits it through `state_repo.sh` primitives (already merged in PR-1)
rather than through a real scan. It still creates a **real sparse file on
disk** at the path the fixture names (exit criterion 3 says "sparse file
OK"), so once PR-2 lands and wires `snapshot` to write the real ledger, the
harness's sparse-file fixture becomes meaningful input to a real scan and
`write_fixture_ledger()` is a one-line swap for the real `disk-magician
snapshot` call — the fixture and the real path measure the same file. This
is a deliberate, documented gap, not a silent skip: Task 5 Step 6 files a
tracking bead for the swap.

**Tech stack / house rules (MANDATORY, inherited from the PR-1 plan +
lessons from that implementation):**
- bash must pass `/bin/bash -n` AND run green under macOS `/bin/bash` 3.2 (no
  `mapfile`, no `declare -A`, guard empty arrays under `set -u` with
  `${arr[0]+"${arr[@]}"}`); `shellcheck --severity=error --external-sources`
  clean.
- Pin git default branches explicitly (`git init -q -b main` with a fallback
  to `init` + `symbolic-ref HEAD refs/heads/main`) wherever a fixture repo is
  created — PR-1's `state_repo.sh:17-18,27-28` hit a real CI failure from an
  unborn-HEAD default-branch mismatch; every `git init` in this plan's tests
  and in `history_diff.py`'s test fixtures follows that pattern.
- Every repo-root `scripts/`/`config.json.template`/`disk_magician.sh` change
  is synced via `bash scripts/sync_package_tree.sh` before commit (CI
  enforces `--check`). Edit the **root** `disk_magician.sh` and
  `scripts/history_diff.py`, never the `src/disk_magician/` mirror directly.
  `tests/` is NOT in the sync pattern list — test files live only at the
  repo root and are never mirrored.
- `git add -f` where `.gitignore` interferes (verify with `git status
  --porcelain` before every commit in this plan — PR-1 sessions lost time to
  silently-ignored new files).
- PR body must fill `.github/PULL_REQUEST_TEMPLATE.md` Evidence fields with
  REAL command output, values **INLINE** on the `**Field:**` line, and
  `**Evidence SHA:**` = the full 40-character PR head SHA.
- Tests are sandboxed: shell tests never touch the real `$HOME` — always
  `env -i HOME=<tmp> PATH=<minimal>`; python tests use `tempfile.mkdtemp()`.
  CI (`.github/workflows/ci.yml`) runs every `tests/test_*.sh` under `timeout
  300`, so no task in this plan may assume network/gh/uv availability by
  default — real-network/real-gh paths are opt-in via env flags described in
  Task 5.
- **NEVER bump `pyproject.toml` version** (integrator does that at deploy
  time, matching `CLAUDE.md`'s "commit is NOT deploy" section).
- Commit + push after EVERY green unit of work; never hold more than 30
  minutes of uncommitted changes. Pull `--rebase` before each push (a sibling
  PR-2 plan lane also pushes to `main`); retry once on non-fast-forward,
  verify landing via `git ls-remote origin main` compared against local
  `git rev-parse HEAD` — never trust piped push output alone.

---

### Task 1: ledger schema — `validate_ledger()` (pure, no git yet)

**Files:**
- Create: `scripts/history_diff.py`
- Create: `tests/test_history_diff.py`

- [ ] **Step 1: Write the failing test file**

```python
#!/usr/bin/env python3
"""test_history_diff.py — unit + CLI-integration tests for
scripts/history_diff.py (sandboxed: tempfile git repos, no real $HOME)."""
import json
import pathlib
import subprocess
import sys
import tempfile
import unittest

REPO = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = REPO / "scripts" / "history_diff.py"
sys.path.insert(0, str(REPO / "scripts"))
import history_diff as hd  # noqa: E402

GIB_KB = 1024 * 1024


def ledger(disk_used_kb, residual_kb, buckets, residual_label="test-residual"):
    return {
        "schema_version": 1,
        "captured_at": "2026-07-21T00:00:00Z",
        "hostname": "sandbox-host",
        "disk_used_kb": disk_used_kb,
        "residual_kb": residual_kb,
        "residual_label": residual_label,
        "buckets": buckets,
    }


class TestValidateLedger(unittest.TestCase):
    def test_valid_ledger_passes(self):
        led = ledger(3 * GIB_KB, 1 * GIB_KB, [
            {"path": "/a", "measured_kb": 1 * GIB_KB},
            {"path": "/b", "measured_kb": 1 * GIB_KB},
        ])
        hd.validate_ledger(led, label="valid")  # must not raise

    def test_missing_key_rejected(self):
        led = ledger(1, 1, [])
        del led["residual_kb"]
        with self.assertRaises(hd.LedgerError):
            hd.validate_ledger(led, label="missing-key")

    def test_oversize_bucket_rejected(self):
        led = ledger(6 * GIB_KB, 0, [{"path": "/big", "measured_kb": 5 * GIB_KB}])
        with self.assertRaises(hd.LedgerError) as ctx:
            hd.validate_ledger(led, label="oversize")
        self.assertIn("/big", str(ctx.exception))

    def test_reconciliation_mismatch_rejected(self):
        led = ledger(10, 1, [{"path": "/a", "measured_kb": 5}])
        with self.assertRaises(hd.LedgerError) as ctx:
            hd.validate_ledger(led, label="unbalanced")
        self.assertIn("reconciliation", str(ctx.exception))

    def test_bucket_missing_measured_kb_rejected(self):
        led = ledger(1, 1, [{"path": "/a"}])
        with self.assertRaises(hd.LedgerError):
            hd.validate_ledger(led, label="null-size")

    def test_oversize_dir_rejected_but_oversize_file_allowed(self):
        # A >=5 GiB directory aggregate without child breakdown is an
        # unexplained opaque node (refused). A >=5 GiB single FILE is a leaf
        # by construction — it can't be broken down further, mirroring
        # scripts/disk_frontier_scan.py's oversize_indivisible_files, which
        # is tracked outside the <=5 GiB granularity_buckets ceiling.
        oversize_dir = ledger(6 * GIB_KB, 0, [{"path": "/big_dir", "measured_kb": 6 * GIB_KB, "kind": "dir"}])
        with self.assertRaises(hd.LedgerError):
            hd.validate_ledger(oversize_dir, label="oversize-dir")
        oversize_file = ledger(6 * GIB_KB, 0, [{"path": "/big.img", "measured_kb": 6 * GIB_KB, "kind": "file"}])
        hd.validate_ledger(oversize_file, label="oversize-file")  # must not raise


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run to verify it fails** — `python3 -m unittest
  tests.test_history_diff -v` → `ModuleNotFoundError: No module named
  'history_diff'` (script missing).

- [ ] **Step 3: Minimal implementation** — create `scripts/history_diff.py`:

```python
#!/usr/bin/env python3
"""history_diff.py — compare two committed ledger/topdown-5g.json snapshots
in the per-machine state repo; print bucket-level growth deltas.

Design: roadmap/2026-07-21-generic-split-state-repo-design.md ("Diff UX").
Ledger contract: roadmap/plans/2026-07-21-state-repo-pr3-plan.md
("Ledger contract this PR assumes").

No shell pipelines: all comparison/sort logic is Python (the grep-shim
pipeline-corruption class documented in this repo's operator memory).
"""
import argparse
import json
import os
import pathlib
import subprocess
import sys

GIB_KB = 1024 * 1024
LEDGER_REL_PATH = "ledger/topdown-5g.json"


class LedgerError(ValueError):
    """Ledger fails schema, the <=5 GiB ceiling, or reconciliation."""


def validate_ledger(ledger: dict, *, label: str) -> None:
    for key in ("disk_used_kb", "residual_kb", "buckets"):
        if key not in ledger:
            raise LedgerError(f"{label}: missing required key {key!r}")
    buckets = ledger["buckets"]
    if not isinstance(buckets, list):
        raise LedgerError(f"{label}: 'buckets' must be a list")
    total = 0
    for item in buckets:
        path = item.get("path")
        size = item.get("measured_kb")
        kind = item.get("kind", "dir")
        if not path or not isinstance(size, int):
            raise LedgerError(f"{label}: bucket missing path/measured_kb: {item!r}")
        if kind not in ("dir", "file"):
            raise LedgerError(f"{label}: bucket {path!r} has unknown kind {kind!r}")
        if kind == "dir" and size >= 5 * GIB_KB:
            # A directory aggregate at/above the ceiling should have been
            # broken into child buckets — refuse rather than diff a partial
            # picture. A single indivisible FILE (kind="file") is exempt: it
            # is already a leaf and cannot be decomposed further, mirroring
            # disk_frontier_scan.py's oversize_indivisible_files category.
            raise LedgerError(
                f"{label}: bucket {path!r} is {size / GIB_KB:.2f} GiB — "
                "unexplained >=5 GiB aggregate without child breakdown"
            )
        total += size
    residual = ledger["residual_kb"]
    used = ledger["disk_used_kb"]
    if total + residual != used:
        raise LedgerError(
            f"{label}: buckets ({total} KiB) + residual ({residual} KiB) "
            f"!= disk_used_kb ({used} KiB) — reconciliation failed"
        )


if __name__ == "__main__":
    pass
```

- [ ] **Step 4: Run to verify pass** — `python3 -m unittest
  tests.test_history_diff -v` → `Ran 6 tests ... OK`.
- [ ] **Step 5: Sync + commit** — `bash scripts/sync_package_tree.sh && git
  add scripts/history_diff.py tests/test_history_diff.py
  src/disk_magician/scripts/history_diff.py && git commit -m "feat(history):
  history_diff.py validate_ledger — schema + 5GiB ceiling + reconciliation"`

### Task 2: delta computation — `compute_deltas()` / `format_diff()` (pure)

**Files:** Modify `scripts/history_diff.py`; Test: append to
`tests/test_history_diff.py` (before the `if __name__` block).

- [ ] **Step 1: Append failing tests**

```python
class TestComputeDeltas(unittest.TestCase):
    def test_growth_sorted_first_shrink_last(self):
        base = ledger(4 * GIB_KB, 1 * GIB_KB, [
            {"path": "/grew", "measured_kb": 1 * GIB_KB},
            {"path": "/shrank", "measured_kb": 2 * GIB_KB},
        ])
        target = ledger(4 * GIB_KB, 1 * GIB_KB, [
            {"path": "/grew", "measured_kb": 3 * GIB_KB},
            {"path": "/shrank", "measured_kb": 0},
        ])
        deltas, residual_delta = hd.compute_deltas(base, target)
        self.assertEqual(deltas[0][0], "/grew")
        self.assertGreater(deltas[0][1], 0)
        self.assertEqual(deltas[-1][0], "/shrank")
        self.assertLess(deltas[-1][1], 0)
        self.assertEqual(residual_delta, 0)

    def test_added_and_removed_buckets_diff_against_zero(self):
        base = ledger(1 * GIB_KB, 0, [{"path": "/old", "measured_kb": 1 * GIB_KB}])
        target = ledger(1 * GIB_KB, 0, [{"path": "/new", "measured_kb": 1 * GIB_KB}])
        deltas, _ = hd.compute_deltas(base, target)
        by_path = dict(deltas)
        self.assertEqual(by_path["/new"], 1 * GIB_KB)
        self.assertEqual(by_path["/old"], -1 * GIB_KB)

    def test_residual_delta_sign(self):
        base = ledger(2 * GIB_KB, 1 * GIB_KB, [])
        target = ledger(2 * GIB_KB, 2 * GIB_KB, [])
        _, residual_delta = hd.compute_deltas(base, target)
        self.assertEqual(residual_delta, 1 * GIB_KB)


class TestFormatDiff(unittest.TestCase):
    def test_top_line_is_largest_growth_last_line_is_residual(self):
        deltas = [("/grew", 6 * GIB_KB), ("/flat", 0), ("/shrank", -1 * GIB_KB)]
        out = hd.format_diff(deltas, 0)
        lines = out.splitlines()
        self.assertIn("/grew", lines[0])
        self.assertTrue(lines[0].startswith("+"))
        self.assertEqual(lines[-1], "residual delta: +0.00 GiB")
        # zero-delta buckets are noise in a diff view — omitted, not printed as +0.00.
        self.assertFalse(any("/flat" in l for l in lines))
```

- [ ] **Step 2: Run — expect FAIL** (`compute_deltas`/`format_diff` don't
  exist yet).

- [ ] **Step 3: Implement** — append to `scripts/history_diff.py` (above the
  `if __name__` guard):

```python
def compute_deltas(base: dict, target: dict) -> "tuple[list, int]":
    base_by_path = {b["path"]: b["measured_kb"] for b in base["buckets"]}
    target_by_path = {b["path"]: b["measured_kb"] for b in target["buckets"]}
    paths = set(base_by_path) | set(target_by_path)
    deltas = [
        (path, target_by_path.get(path, 0) - base_by_path.get(path, 0))
        for path in paths
    ]
    deltas.sort(key=lambda item: (-item[1], item[0]))
    residual_delta = target["residual_kb"] - base["residual_kb"]
    return deltas, residual_delta


def format_kb(delta_kb: int) -> str:
    sign = "+" if delta_kb >= 0 else "-"
    return f"{sign}{abs(delta_kb) / GIB_KB:.2f} GiB"


def format_diff(deltas: list, residual_delta: int) -> str:
    lines = [
        f"{format_kb(delta_kb)}  {path}"
        for path, delta_kb in deltas
        if delta_kb != 0
    ]
    lines.append(f"residual delta: {format_kb(residual_delta)}")
    return "\n".join(lines)
```

- [ ] **Step 4: Run to pass** — `python3 -m unittest tests.test_history_diff
  -v` → `Ran 10 tests ... OK`.
- [ ] **Step 5: Sync + commit** — `git commit -m "feat(history):
  compute_deltas/format_diff — growth-sorted, residual last"`

### Task 3: CLI — git integration, `[ref]` arg, `--validate`, exit codes

**Files:** Modify `scripts/history_diff.py`; Test: append to
`tests/test_history_diff.py`.

- [ ] **Step 1: Append failing tests** (builds a real 3-commit fixture git
  repo — pin `-b main` per the house rule above)

```python
def _git(repo, *args):
    return subprocess.run(
        ["git", "-C", str(repo), *args],
        capture_output=True, text=True, check=True,
    )


def _write_ledger_commit(repo, ledger_obj, msg):
    ledger_dir = repo / "ledger"
    ledger_dir.mkdir(exist_ok=True)
    (ledger_dir / "topdown-5g.json").write_text(json.dumps(ledger_obj))
    _git(repo, "add", "ledger/topdown-5g.json")
    _git(repo, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", msg)


class TestCLIIntegration(unittest.TestCase):
    def setUp(self):
        self.tmp = pathlib.Path(tempfile.mkdtemp())
        self.repo = self.tmp / "state"
        self.repo.mkdir()
        try:
            _git(self.repo, "init", "-q", "-b", "main")
        except subprocess.CalledProcessError:
            _git(self.repo, "init", "-q")
            _git(self.repo, "symbolic-ref", "HEAD", "refs/heads/main")

    def _run_cli(self, *args):
        return subprocess.run(
            [sys.executable, str(SCRIPT), "--state-dir", str(self.repo), *args],
            capture_output=True, text=True,
        )

    def test_default_diffs_head_minus_1_against_head(self):
        # Both buckets stay under the 5 GiB dir ceiling on purpose — this
        # test exercises ordering/wiring, not the ceiling edge case (that's
        # test_fail_closed_on_oversize_bucket_refuses_diff below, and the
        # >=5 GiB kind="file" exemption is covered in TestValidateLedger).
        base = ledger(4 * GIB_KB, 0, [{"path": "/a", "measured_kb": 4 * GIB_KB}])
        _write_ledger_commit(self.repo, base, "base")
        target = ledger(8 * GIB_KB, 0, [
            {"path": "/a", "measured_kb": 4 * GIB_KB},
            {"path": "/fixture_growth", "measured_kb": 4 * GIB_KB},
        ])
        _write_ledger_commit(self.repo, target, "target")
        result = self._run_cli()
        self.assertEqual(result.returncode, 0, result.stderr)
        lines = result.stdout.splitlines()
        self.assertIn("/fixture_growth", lines[0])
        self.assertEqual(lines[-1], "residual delta: +0.00 GiB")

    def test_explicit_ref_diffs_against_head(self):
        first = ledger(1 * GIB_KB, 0, [{"path": "/a", "measured_kb": 1 * GIB_KB}])
        _write_ledger_commit(self.repo, first, "c1")
        mid = ledger(2 * GIB_KB, 0, [{"path": "/a", "measured_kb": 2 * GIB_KB}])
        _write_ledger_commit(self.repo, mid, "c2")
        last = ledger(3 * GIB_KB, 0, [{"path": "/a", "measured_kb": 3 * GIB_KB}])
        _write_ledger_commit(self.repo, last, "c3")
        result = self._run_cli("HEAD~2")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("+2.00 GiB", result.stdout)

    def test_fail_closed_on_oversize_bucket_refuses_diff(self):
        base = ledger(1 * GIB_KB, 0, [{"path": "/a", "measured_kb": 1 * GIB_KB}])
        _write_ledger_commit(self.repo, base, "base")
        bad = ledger(6 * GIB_KB, 0, [{"path": "/opaque", "measured_kb": 6 * GIB_KB}])
        _write_ledger_commit(self.repo, bad, "bad")
        result = self._run_cli()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("/opaque", result.stderr)
        self.assertEqual(result.stdout, "")

    def test_missing_state_repo_exits_1(self):
        result = subprocess.run(
            [sys.executable, str(SCRIPT), "--state-dir", str(self.tmp / "nope")],
            capture_output=True, text=True,
        )
        self.assertEqual(result.returncode, 1)

    def test_validate_mode_valid_file(self):
        led_path = self.tmp / "led.json"
        led_path.write_text(json.dumps(
            ledger(1 * GIB_KB, 0, [{"path": "/a", "measured_kb": 1 * GIB_KB}])
        ))
        result = subprocess.run(
            [sys.executable, str(SCRIPT), "--validate", str(led_path)],
            capture_output=True, text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_validate_mode_invalid_file(self):
        led_path = self.tmp / "bad.json"
        led_path.write_text(json.dumps(
            ledger(6 * GIB_KB, 0, [{"path": "/big", "measured_kb": 6 * GIB_KB}])
        ))
        result = subprocess.run(
            [sys.executable, str(SCRIPT), "--validate", str(led_path)],
            capture_output=True, text=True,
        )
        self.assertEqual(result.returncode, 2)
```

- [ ] **Step 2: Run — expect FAIL** (no `argparse` wiring, `SCRIPT` invoked
  as subprocess prints nothing/errors).

- [ ] **Step 3: Implement** — replace the `if __name__ == "__main__": pass`
  stub with:

```python
def load_ledger_from_file(path: pathlib.Path) -> dict:
    return json.loads(path.read_text())


def load_ledger_from_git(state_dir: pathlib.Path, ref: str) -> dict:
    result = subprocess.run(
        ["git", "-C", str(state_dir), "show", f"{ref}:{LEDGER_REL_PATH}"],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        raise LedgerError(f"{ref}: cannot read {LEDGER_REL_PATH} — {result.stderr.strip()}")
    return json.loads(result.stdout)


def resolve_state_dir(explicit) -> pathlib.Path:
    if explicit:
        return pathlib.Path(explicit)
    env = os.environ.get("DISK_MAGICIAN_STATE_REPO")
    if env:
        return pathlib.Path(env)
    home = pathlib.Path(os.environ.get("HOME", "/"))
    xdg_state = pathlib.Path(os.environ.get("XDG_STATE_HOME", home / ".local/state"))
    return xdg_state / "disk-magician"


def main(argv) -> int:
    parser = argparse.ArgumentParser(prog="disk-magician history diff")
    parser.add_argument("ref", nargs="?", default=None,
                         help="base ref to diff against HEAD (default: HEAD~1)")
    parser.add_argument("--state-dir", default=None)
    parser.add_argument("--validate", metavar="LEDGER_JSON", default=None,
                         help="validate a single ledger file and exit (no diff)")
    args = parser.parse_args(argv)

    if args.validate:
        try:
            validate_ledger(load_ledger_from_file(pathlib.Path(args.validate)),
                             label=args.validate)
        except LedgerError as exc:
            print(f"history diff: {exc}", file=sys.stderr)
            return 2
        print(f"history diff: {args.validate} is a valid <=5 GiB ledger")
        return 0

    state_dir = resolve_state_dir(args.state_dir)
    if not (state_dir / ".git").is_dir():
        print(f"history diff: no state repo at {state_dir} (run: state init)", file=sys.stderr)
        return 1

    base_ref = args.ref or "HEAD~1"
    try:
        base = load_ledger_from_git(state_dir, base_ref)
        target = load_ledger_from_git(state_dir, "HEAD")
        validate_ledger(base, label=base_ref)
        validate_ledger(target, label="HEAD")
    except LedgerError as exc:
        print(f"history diff: {exc}", file=sys.stderr)
        return 2

    deltas, residual_delta = compute_deltas(base, target)
    print(format_diff(deltas, residual_delta))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
```

- [ ] **Step 4: Run to pass** — `python3 -m unittest tests.test_history_diff
  -v` → `Ran 16 tests ... OK`. Also `shellcheck` N/A (pure Python); `python3
  -m py_compile scripts/history_diff.py` clean.
- [ ] **Step 5: Sync + commit** — `git commit -m "feat(history): CLI —
  git-show integration, [ref] arg, --validate, fail-closed exit codes"`

### Task 4: dispatcher wiring — `disk-magician history diff [ref]`

**Files:** Modify `disk_magician.sh` (repo root — canonical); Create:
`tests/test_history_diff_dispatch.sh`.

- [ ] **Step 1: Write the failing test file**

```bash
#!/usr/bin/env bash
# test_history_diff_dispatch.sh — dispatcher wiring for `history diff [ref]`
# (sandboxed: fixture STATE_DIR via DISK_MAGICIAN_STATE_REPO, no real $HOME).
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DM="$REPO_ROOT/disk_magician.sh"
TMP_ROOT=$(mktemp -d -t history_diff_dispatch.XXXXXX)
trap 'rm -rf "$TMP_ROOT"' EXIT
PASS=0; FAIL=0
ok()  { echo "  PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $1 — $2"; FAIL=$((FAIL+1)); }

STATE="$TMP_ROOT/state"
mkdir -p "$STATE/ledger"
git -C "$STATE" init -q -b main 2>/dev/null \
  || { git -C "$STATE" init -q && git -C "$STATE" symbolic-ref HEAD refs/heads/main; }
gib=$((1024*1024))
cat > "$STATE/ledger/topdown-5g.json" <<EOF
{"schema_version":1,"disk_used_kb":$((4*gib)),"residual_kb":0,
 "residual_label":"t","buckets":[{"path":"/a","measured_kb":$((4*gib))}]}
EOF
git -C "$STATE" add -A
git -C "$STATE" -c user.name=t -c user.email=t@t commit -qm base
cat > "$STATE/ledger/topdown-5g.json" <<EOF
{"schema_version":1,"disk_used_kb":$((8*gib)),"residual_kb":0,
 "residual_label":"t","buckets":[{"path":"/a","measured_kb":$((4*gib))},
 {"path":"/fixture_growth","measured_kb":$((4*gib))}]}
EOF
git -C "$STATE" add -A
git -C "$STATE" -c user.name=t -c user.email=t@t commit -qm grown

echo "Test 1: history diff (no ref) names the grown bucket first, residual last"
OUT=$(env -i HOME="$TMP_ROOT/home" PATH="/usr/bin:/bin" \
      DISK_MAGICIAN_STATE_REPO="$STATE" "$DM" history diff 2>&1)
RC=$?
[[ $RC -eq 0 ]] && ok "dispatch exits 0" || bad "dispatch rc" "$RC: $OUT"
FIRST_LINE=$(python3 -c "import sys; print(sys.argv[1].splitlines()[0])" "$OUT")
LAST_LINE=$(python3 -c "import sys; print(sys.argv[1].splitlines()[-1])" "$OUT")
[[ "$FIRST_LINE" == *"/fixture_growth"* ]] && ok "grown bucket is the top line" \
  || bad "top line" "$FIRST_LINE"
[[ "$LAST_LINE" == "residual delta: +0.00 GiB" ]] && ok "residual delta is the last line" \
  || bad "last line" "$LAST_LINE"

echo "Test 2: history diff HEAD (explicit ref) still routes to history_diff.py"
OUT2=$(env -i HOME="$TMP_ROOT/home" PATH="/usr/bin:/bin" \
       DISK_MAGICIAN_STATE_REPO="$STATE" "$DM" history diff HEAD 2>&1)
[[ "$OUT2" == "residual delta: +0.00 GiB" ]] && ok "diff HEAD == HEAD is empty + residual line" \
  || bad "diff HEAD" "$OUT2"

echo "Test 3: bare 'history' (no diff) still falls through to disk_history.sh"
OUT3=$(env -i HOME="$TMP_ROOT/home2" PATH="/usr/bin:/bin" "$DM" history 2>&1)
echo "$OUT3" | grep -qi "history_diff" && bad "bare history unaffected" "leaked into history_diff: $OUT3" \
  || ok "bare history is not rerouted"

echo; echo "=== Result: $PASS pass, $FAIL fail ==="
[[ "$FAIL" -eq 0 ]]
```

- [ ] **Step 2: Run to verify it fails** — `/bin/bash
  tests/test_history_diff_dispatch.sh` → Test 1/2 FAIL (`history diff` is
  currently swallowed by the `disk_history.sh` fallthrough, which doesn't
  understand `diff`).

- [ ] **Step 3: Minimal implementation** — edit `disk_magician.sh` (repo
  root), the `history)` case:

```bash
  history)
    if [[ "${1:-}" == "diff" ]]; then
      shift
      python3 "$SCRIPT_DIR/scripts/history_diff.py" "$@"
      exit $?
    fi
    DISK_SNAPSHOT_JSON="$BACKUP_DIR/backup/$(hostname -s 2>/dev/null || hostname)/disk_snapshot.json"
    export DISK_SNAPSHOT_JSON
    # Execute history from the BACKUP_DIR context so git history is tracked there
    DISK_SNAPSHOT_JSON="$BACKUP_DIR/backup/$(hostname -s 2>/dev/null || hostname)/disk_snapshot.json" python3 "$SCRIPT_DIR/scripts/disk_history.sh" "$@"
    ;;
```

  Also add one line to `usage()`'s `history` entry:
  `history [diff [ref]]   Show growth trends, or diff two committed ledgers.`

- [ ] **Step 4: Run to pass** — `/bin/bash
  tests/test_history_diff_dispatch.sh` → `=== Result: 5 pass, 0 fail ===`.
  `/bin/bash -n disk_magician.sh && shellcheck --severity=error
  --external-sources disk_magician.sh` clean.
- [ ] **Step 5: Sync + commit** — `bash scripts/sync_package_tree.sh &&
  git add disk_magician.sh src/disk_magician/disk_magician.sh
  tests/test_history_diff_dispatch.sh && git commit -m "feat(history): wire
  'history diff [ref]' into the dispatcher"`

### Task 5: sandbox E2E harness — design-doc Exit Criteria 1–3

**Files:** Create `tests/test_state_repo_e2e.sh`.

- [ ] **Step 1: Write the harness (no red/green cycle — this is an
  integration proof over already-green units from Tasks 1–4 and the merged
  PR-1 `state_repo.sh`; verify by running it, not by TDD-ing the harness
  itself against a stub)**

```bash
#!/usr/bin/env bash
# test_state_repo_e2e.sh — sandbox E2E proof of design-doc Exit Criteria 1-3
# (roadmap/2026-07-21-generic-split-state-repo-design.md).
#
# Default (CI): DM_E2E_SKIP_INSTALL=1-equivalent behavior — no network, no
# uv, no gh. Set DM_E2E_BRANCH=<pushed-branch> and unset DM_E2E_SKIP_INSTALL
# to exercise the real `uv tool install git+...@branch` path (criterion 1).
# Set DM_E2E_REAL_GH=1 (in addition) to let a real `gh repo create` run
# against github.com; default is a stubbed gh so CI stays hermetic.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TMP_ROOT=$(mktemp -d -t state_repo_e2e.XXXXXX)
trap 'rm -rf "$TMP_ROOT"' EXIT
PASS=0; FAIL=0
ok()  { echo "  PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $1 — $2"; FAIL=$((FAIL+1)); }
gib=$((1024*1024))

DM_E2E_SKIP_INSTALL="${DM_E2E_SKIP_INSTALL:-1}"
DM_E2E_REAL_GH="${DM_E2E_REAL_GH:-0}"
DM_E2E_BRANCH="${DM_E2E_BRANCH:-}"

SANDBOX_HOME="$TMP_ROOT/home"
mkdir -p "$SANDBOX_HOME"
FAKE_HOST="sandbox-$(date +%s)-$$"

# ---- Criterion 1: fresh-user E2E -------------------------------------
echo "=== Criterion 1: fresh-user E2E ==="
if [[ "$DM_E2E_SKIP_INSTALL" == "1" ]]; then
  echo "  SKIP (loud): DM_E2E_SKIP_INSTALL=1 — set DM_E2E_BRANCH=<branch> and"
  echo "  DM_E2E_SKIP_INSTALL=0 to run the real 'uv tool install git+...' leg."
  DM_BIN="$REPO_ROOT/disk_magician.sh"
else
  [[ -n "$DM_E2E_BRANCH" ]] || { bad "DM_E2E_BRANCH set" "required when DM_E2E_SKIP_INSTALL=0"; echo "=== Result: $PASS pass, $FAIL fail ==="; exit 1; }
  command -v uv >/dev/null 2>&1 || { bad "uv on PATH" "uv not found — cannot run real install leg"; echo "=== Result: $PASS pass, $FAIL fail ==="; exit 1; }
  REMOTE_URL="$(git -C "$REPO_ROOT" remote get-url origin)"
  UV_TOOL_DIR="$TMP_ROOT/uv-tools"
  if UV_TOOL_DIR="$UV_TOOL_DIR" uv tool install --force \
       "git+${REMOTE_URL}@${DM_E2E_BRANCH}" >"$TMP_ROOT/uv-install.log" 2>&1; then
    ok "uv tool install git+<repo>@<branch> succeeds"
  else
    bad "uv tool install git+<repo>@<branch> succeeds" "$(cat "$TMP_ROOT/uv-install.log")"
  fi
  DM_BIN=$(UV_TOOL_DIR="$UV_TOOL_DIR" command -v disk-magician || true)
  [[ -n "$DM_BIN" ]] && ok "installed disk-magician entrypoint found" \
    || { bad "installed entrypoint found" "not on PATH after install"; DM_BIN="$REPO_ROOT/disk_magician.sh"; }
fi

FAKE_BIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKE_BIN"
GH_LOG="$TMP_ROOT/gh.log"
if [[ "$DM_E2E_REAL_GH" != "1" ]]; then
  cat > "$FAKE_BIN/gh" <<EOF
#!/usr/bin/env bash
echo "gh \$*" >> "$GH_LOG"
case "\$1" in
  auth) exit 0 ;;
  repo) exit 0 ;;
  api) echo '{"login":"sandbox-user"}'; exit 0 ;;
esac
exit 0
EOF
  chmod +x "$FAKE_BIN/gh"
fi

STATE_DIR="$SANDBOX_HOME/.local/state/disk-magician"
INIT_OUT=$(env -i HOME="$SANDBOX_HOME" PATH="$FAKE_BIN:/usr/bin:/bin" \
  DISK_MAGICIAN_ASSUME_YES=1 "$REPO_ROOT/scripts/state_repo.sh" init 2>&1)
[[ -d "$STATE_DIR/.git" ]] && ok "state init creates a git state repo" \
  || bad "state init creates a git state repo" "$INIT_OUT"
if [[ "$DM_E2E_REAL_GH" != "1" ]]; then
  grep -q "repo create" "$GH_LOG" 2>/dev/null && ok "gh repo-create offer invoked (stub)" \
    || bad "gh repo-create offer invoked" "$(cat "$GH_LOG" 2>/dev/null || echo missing)"
else
  echo "  REAL gh: verify via 'gh api repos/<user>/disk-magician-state-${FAKE_HOST}' after this run."
fi

# ---- Criterion 2 + 3: ledger contract + diff naming growth ------------
# PR-2 (snapshot -> ledger write) is not merged yet; write_fixture_ledger()
# is the documented seam — see roadmap/plans/2026-07-21-state-repo-pr3-plan.md
# "Ledger contract this PR assumes" for the swap-to-real-snapshot plan.
write_fixture_ledger() {
  local disk_used_kb="$1" residual_kb="$2" buckets_json="$3"
  mkdir -p "$STATE_DIR/ledger"
  printf '{"schema_version":1,"captured_at":"2026-07-21T00:00:00Z",' > "$STATE_DIR/ledger/topdown-5g.json"
  printf '"hostname":"%s","disk_used_kb":%s,"residual_kb":%s,' "$FAKE_HOST" "$disk_used_kb" "$residual_kb" >> "$STATE_DIR/ledger/topdown-5g.json"
  printf '"residual_label":"protected_or_apfs_allocation_not_attributable_by_this_session",' >> "$STATE_DIR/ledger/topdown-5g.json"
  printf '"buckets":%s}' "$buckets_json" >> "$STATE_DIR/ledger/topdown-5g.json"
  git -C "$STATE_DIR" add ledger/topdown-5g.json
  git -C "$STATE_DIR" -c user.name=disk-magician -c user.email=disk-magician@localhost \
    commit -q -m "$4"
}

echo "=== Criterion 2: ledger contract (exact reconciliation, no >=5GiB opaque node) ==="
BASE_BUCKETS='[{"path":"/Users/sandbox/Library/Caches","measured_kb":'$((2*gib))'},{"path":"/Users/sandbox/projects","measured_kb":'$((2*gib))'}]'
write_fixture_ledger "$((4*gib))" 0 "$BASE_BUCKETS" "snapshot: baseline"
if VALID_OUT=$(python3 "$REPO_ROOT/scripts/history_diff.py" \
     --validate "$STATE_DIR/ledger/topdown-5g.json" 2>&1); then
  ok "committed ledger reconciles exactly with zero unexplained >=5GiB nodes"
else
  bad "ledger reconciles / no opaque nodes" "$VALID_OUT"
fi

echo "=== Criterion 3: diff names injected growth as the top line, residual last ==="
FIXTURE_DIR="$SANDBOX_HOME/fixture_growth"
mkdir -p "$(dirname "$FIXTURE_DIR")"
FIXTURE_FILE="$FIXTURE_DIR.img"
# Sparse file: seek to (6 GiB - 1 byte) and write one byte, so the fixture
# names a real >=6 GiB path without actually consuming 6 GiB of disk.
dd if=/dev/zero of="$FIXTURE_FILE" bs=1 count=1 seek=$((6*1024*1024*1024 - 1)) >/dev/null 2>&1
if [[ -f "$FIXTURE_FILE" ]]; then
  ok "sparse fixture file created"
else
  bad "sparse fixture file created" "dd failed"
fi
# kind:"file" is required here — the fixture is a single indivisible file
# >=5 GiB, which is exempt from the "dir" ceiling (see "Ledger contract this
# PR assumes" / TestValidateLedger.test_oversize_dir_rejected_but_oversize_file_allowed).
GROWN_BUCKETS='[{"path":"/Users/sandbox/Library/Caches","measured_kb":'$((2*gib))'},{"path":"/Users/sandbox/projects","measured_kb":'$((2*gib))'},{"path":"'"$FIXTURE_FILE"'","measured_kb":'$((6*gib))',"kind":"file"}]'
write_fixture_ledger "$((10*gib))" 0 "$GROWN_BUCKETS" "snapshot: injected >=6GiB growth"

DIFF_OUT=$(env -i HOME="$SANDBOX_HOME" PATH="/usr/bin:/bin" \
  DISK_MAGICIAN_STATE_REPO="$STATE_DIR" python3 "$REPO_ROOT/scripts/history_diff.py" 2>&1)
FIRST_LINE=$(python3 -c "import sys; print(sys.argv[1].splitlines()[0])" "$DIFF_OUT")
LAST_LINE=$(python3 -c "import sys; print(sys.argv[1].splitlines()[-1])" "$DIFF_OUT")
[[ "$FIRST_LINE" == *"$FIXTURE_FILE"* && "$FIRST_LINE" == "+6.00 GiB"* ]] \
  && ok "history diff names the injected bucket with its delta as the top line" \
  || bad "top line names injected growth" "$FIRST_LINE"
[[ "$LAST_LINE" == "residual delta: +0.00 GiB" ]] \
  && ok "residual delta is printed last" \
  || bad "residual delta last" "$LAST_LINE"

# ---- Teardown -----------------------------------------------------------
rm -f "$FIXTURE_FILE"
if [[ "$DM_E2E_REAL_GH" == "1" ]]; then
  echo "  REAL gh: tear down the throwaway repo yourself:"
  echo "    gh repo delete disk-magician-state-${FAKE_HOST} --yes"
fi

echo; echo "=== Result: $PASS pass, $FAIL fail ==="
[[ "$FAIL" -eq 0 ]]
```

- [ ] **Step 2: Run under CI defaults** — `/bin/bash
  tests/test_state_repo_e2e.sh` (no env overrides) → hermetic, stubbed `gh`,
  no `uv`/network. Expected `=== Result: 6 pass, 0 fail ===`.
- [ ] **Step 3: Run the real-install leg locally (not in CI)** — push this
  branch, then:
  ```bash
  DM_E2E_SKIP_INSTALL=0 DM_E2E_BRANCH=<this-branch> /bin/bash tests/test_state_repo_e2e.sh
  ```
  Confirms `uv tool install git+<repo>@<branch>` actually succeeds outside
  CI's no-network assumption. Record the output in the PR evidence block —
  this is the externally-anchored half of criterion 1 that CI cannot run.
- [ ] **Step 4: (optional, manual, real gh)** —
  ```bash
  DM_E2E_SKIP_INSTALL=0 DM_E2E_BRANCH=<this-branch> DM_E2E_REAL_GH=1 \
    /bin/bash tests/test_state_repo_e2e.sh
  gh api "repos/<you>/disk-magician-state-<printed-hostname>" --jq .full_name
  gh repo delete disk-magician-state-<printed-hostname> --yes
  ```
  This is the fully-real leg of criterion 1 ("verified via `gh api`, not
  tool output"); do not run it in CI (rate limits, leaves live repos if a
  teardown step is skipped).
- [ ] **Step 5: shellcheck** — `/bin/bash -n tests/test_state_repo_e2e.sh &&
  shellcheck --severity=error --external-sources tests/test_state_repo_e2e.sh`
  clean.
- [ ] **Step 6: File the PR-2 integration bead, then commit** —
  ```bash
  br create "swap test_state_repo_e2e.sh write_fixture_ledger() for real disk-magician snapshot" \
    --type task --priority 2 \
    --description "roadmap/plans/2026-07-21-state-repo-pr3-plan.md Task 5 Step 1: \
tests/test_state_repo_e2e.sh's write_fixture_ledger() fabricates ledger/topdown-5g.json \
directly because PR-2 (snapshot -> ledger write) wasn't merged when PR-3 landed. Once PR-2 \
ships a real ledger-writing snapshot path, replace the two write_fixture_ledger() calls with \
a real 'disk-magician snapshot' invocation against the same sparse-file fixture at \
\$FIXTURE_FILE so criterion 2/3 exercise the real scanner end to end."
  git add tests/test_state_repo_e2e.sh
  git commit -m "test(state): sandbox E2E harness — exit criteria 1-3"
  ```

### Task 6: README quick-start for strangers

**Files:** Modify `README.md`.

- [ ] **Step 1: Insert a new section** directly after the intro paragraph and
  before `## Portable configuration` (line 6 in the current file):

```markdown
## Quick start (strangers, no local checkout needed)

```bash
# 1. Install straight from GitHub (requires https://docs.astral.sh/uv/):
uv tool install git+https://github.com/jleechanorg/disk_magician.git@main

# 2. First run — audits your disk and auto-initializes a per-machine state
#    repo at $XDG_STATE_HOME/disk-magician (default: ~/.local/state/disk-magician).
#    If `gh` is authenticated, you'll be offered a private
#    disk-magician-state-<hostname> GitHub repo for snapshot history;
#    decline once and it won't ask again. No gh -> local-only, silently.
disk-magician audit

# 3. See what's committed to your state repo:
disk-magician state status

# 4. Take another snapshot later, then see what grew between the two:
disk-magician snapshot
disk-magician history diff          # last two committed ledgers
disk-magician history diff HEAD~5   # explicit base ref
```

Output is a plain list of bucket-level deltas, growth first, with the
residual (space `disk-magician` can't attribute to a specific directory)
printed last:

```
+6.20 GiB  /Users/you/Downloads/big_dataset
+0.40 GiB  /Users/you/Library/Caches/some-app
-1.00 GiB  /Users/you/tmp/old-build
residual delta: +0.05 GiB
```

Everything `disk-magician` observes — snapshots, ledgers, resolved config —
lives in your state repo, not in this checkout; see `roadmap/2026-07-21-generic-split-state-repo-design.md`
for the full design.
```

- [ ] **Step 2: Verify rendering** — no automated test (docs-only); manually
  confirm the fenced code blocks don't nest incorrectly (the outer section
  uses a single ```` ```markdown ```` fence only in this plan document — the
  actual README edit uses plain triple-backtick ` ```bash `/plain fences,
  not nested markdown fences).
- [ ] **Step 3: Commit** — `git commit -m "docs(readme): quick-start —
  uv tool install, state repo, history diff"`

---

## Self-review (PR-1 plan checklist, reapplied)

- [x] Every task has a concrete failing-test-first step with real assertions
  (no `TODO`/`pass`-only tests).
- [x] Every implementation step is real, runnable code — no placeholders.
- [x] `/bin/bash 3.2` compatibility: no `mapfile`, no `declare -A`; the one
  array-adjacent construct (`FAKE_BIN` PATH prepend) uses plain string
  concatenation, not bash-4 array tricks.
- [x] `env -i HOME=<tmp>` sandboxing used in every shell test; python tests
  use `tempfile.mkdtemp()`; nothing touches the real `$HOME`.
- [x] No shell pipelines inside `history_diff.py`'s actual comparison logic
  (Task 1–3) — sort/compare/reconcile is pure Python, matching the design
  doc's explicit "No shell pipelines" line and the grep-shim corruption
  memory. Test-assertion `grep -q`/`dd`/single-tool reads are fine (existing
  repo convention in `test_deploy_uv_tool.sh`); growth-line parsing in shell
  tests routes through a one-line `python3 -c` instead of `head`/`tail`/`awk`
  chains to stay consistent with that same principle.
- [x] The default-branch pin discipline (`git init -q -b main` with a
  `symbolic-ref HEAD` fallback, as shown in `state_repo.sh:17-18,27-28` and
  `test_disk_audit_topdown.sh`'s `-b main` pin) is followed in every new
  fixture repo (Tasks 3, 4, 5).
- [x] `sync_package_tree.sh` is run after every root-file change
  (`disk_magician.sh`, `scripts/history_diff.py`); `tests/` is correctly
  excluded (not a sync pattern).
- [x] `pyproject.toml` version is never touched.
- [x] Commit-often discipline stated explicitly with the pull-rebase +
  `git ls-remote` verification note (sibling PR-2 plan lane also pushes to
  `main`).
- [x] CI's 300s-per-file timeout respected: default `DM_E2E_SKIP_INSTALL=1`
  keeps `test_state_repo_e2e.sh` hermetic and fast in CI; the real
  `uv`/`gh` legs are explicitly opt-in, run locally, and documented as such
  in the PR evidence rather than silently skipped without disclosure.
- [x] Ambiguity around "PR-2 not merged yet" is resolved explicitly (fixture
  ledger writer + tracked bead), not silently worked around.
- [x] `.github/PULL_REQUEST_TEMPLATE.md` Evidence-field format (inline
  values, full 40-char SHA) called out in house rules.

## Ambiguities resolved while writing this plan

1. **`ledger/topdown-5g.json` field names** — not yet defined anywhere
   (PR-2 hasn't landed). Chose `path`/`measured_kb` to match the existing
   `top_level_ledger`/`granularity_buckets` entries in
   `scripts/disk_frontier_scan.py:1302-1322`, so PR-2 can adapt rather than
   invent a second naming convention.
2. **`history diff [ref]` semantics** — design doc doesn't specify what the
   two compared commits are. Chose: optional `ref` is the *base*, always
   diffed against `HEAD`; omitted `ref` defaults to `HEAD~1` (mirrors `git
   diff [ref]` ergonomics: "what changed since ref, up to now").
3. **"top line" / "residual delta last line" (exit criterion 3)** — read
   literally as *stdout's first and last lines*, not a labeled header. Output
   has no header line; zero-delta buckets are omitted (a diff view showing
   `+0.00 GiB` rows for unchanged buckets is noise).
4. **Criterion 2's "from that run"** — cannot be literal in PR-3 because the
   only "run" producing a ledger today is the fixture writer this plan adds
   (PR-2's real snapshot-to-ledger path isn't merged). Documented as a named
   gap with a concrete swap point (`write_fixture_ledger()`) and a tracking
   bead filed in Task 5 Step 6, rather than either blocking on PR-2 or
   silently declaring the criterion met against a stub.
5. **Sparse-file fixture** — exit criterion 3 explicitly allows "sparse file
   OK"; implemented with `dd seek=... count=1` (portable BSD/macOS `dd`, no
   GNU-only `truncate -s`) so the harness doesn't depend on the `coreutils`
   brew formula CI installs only for `timeout`.
6. **The 5 GiB ceiling can't apply uniformly to every bucket** — a flat "no
   bucket >=5 GiB" rule would reject exit criterion 3's own required "inject
   a >=6 GiB fixture" the moment it's represented as a single leaf. Caught
   this by tracing it back to `scripts/disk_frontier_scan.py`, which already
   makes exactly this distinction in production: `granularity_buckets`
   (directory aggregates, ceiling-checked) vs `oversize_indivisible_files`
   (single files at/above the ceiling, exempt because they can't be
   decomposed further, `scripts/disk_frontier_scan.py:1323-1327`). Added an
   optional per-bucket `"kind": "dir" | "file"` field (default `"dir"`) to
   the ledger schema so `validate_ledger()` only ceiling-checks aggregates,
   not indivisible leaves — locked in by
   `TestValidateLedger.test_oversize_dir_rejected_but_oversize_file_allowed`
   in Task 1 and used by Task 5's `$FIXTURE_FILE` bucket.
