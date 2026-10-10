#!/usr/bin/env python3
"""tests/test_disk_status.py — Comprehensive tests for scripts/disk_status.py.

Validates:
- All 6 operational dimensions: fleet, measurement, publication, action_outcome,
  safety, deployed_identity.
- Rollup status logic (healthy, degraded, unknown, invalid) and corresponding CLI exit codes.
- Strict read-only invariance (zero file mutations, zero lockfiles created, byte/mtime preserved).
- Production-shaped fixtures with real git commits, dist-info METADATA, complete package manifests,
  and fleet consumer joins.
- Negative cases for false-healthy states (active run, delegated safety, nested measurement timeout,
  uncommitted ledger, malformed sidecars, missing source/override, escaping symlinks, omitted plists).
"""

from __future__ import annotations

import copy
from datetime import datetime, timedelta, timezone
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time
import tempfile
import unittest
from unittest import mock

REPO_ROOT = Path(__file__).resolve().parent.parent
SCRIPTS_DIR = REPO_ROOT / "scripts"
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))

import disk_status
import history_diff
from job_receipt import JobReceiptStore

USER_PROBE_PATHS = {
    "mobile_sync": os.path.join(os.path.expanduser("~"), "Library", "Application Support", "MobileSync", "Backup"),
    "mail": os.path.join(os.path.expanduser("~"), "Library", "Mail"),
    "messages": os.path.join(os.path.expanduser("~"), "Library", "Messages"),
}


def make_valid_strict_ledger(captured_at: str, disk_used_kb: int = 200, residual_kb: int = 200) -> dict:
    """Create a schema_version 2 strict ledger that passes history_diff validation."""
    return {
        "schema_version": 2,
        "mode": "complete",
        "coverage_envelope": {
            "complete": True,
            "fda_preflight_status": "granted",
            "fda_user_preflight_status": "granted",
            "reachable_top_level_roots": 1,
            "measured_top_level_roots": 1,
            "unfinished_top_level_roots": 0,
        },
        "frontier_unfinished": [],
        "fda_probe_paths": USER_PROBE_PATHS,
        "fda_preflight": {
            "status": "granted",
            "probes": {k: {"path": v, "status": "readable"} for k, v in USER_PROBE_PATHS.items()},
        },
        "accounting_equation": {
            "displayed_balanced": True,
            "display_ledger_valid": True,
            "data_used_kb": disk_used_kb,
            "displayed_buckets_kb": 0,
            "oversize_indivisible_files_kb": 0,
            "sub_granularity_tail_kb": 0,
            "purgeable_kb": 0,
            "residual_kb": residual_kb,
            "clone_shared_adjustment_kb": 0,
        },
        "captured_at": captured_at,
        "hostname": "sandbox-host",
        "disk_used_kb": disk_used_kb,
        "residual_kb": residual_kb,
        "residual_label": "test-residual",
        "buckets": [],
        "opaque_intrinsic_gates": [],
    }


def make_valid_partial_ledger(captured_at: str, disk_used_kb: int = 200, residual_kb: int = 200) -> dict:
    """Create a schema_version 2 valid partial ledger that passes history_diff.validate_ledger."""
    ledger = make_valid_strict_ledger(captured_at, disk_used_kb=disk_used_kb, residual_kb=residual_kb)
    ledger["publication_kind"] = "partial"
    ledger["canonical"] = False
    ledger["mode"] = "partial"
    ledger["coverage_envelope"]["complete"] = False
    ledger["coverage_envelope"]["unfinished_top_level_roots"] = 1
    ledger["frontier_unfinished"] = [{"path": "/Users/foo/Downloads"}]
    ledger["unfinished_top_level_roots"] = ["/Users/foo/Downloads"]
    return ledger


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


class TestDiskStatus(unittest.TestCase):
    def setUp(self):
        self.tmp_dir = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp_dir.name)
        self.state_dir = self.root / "state_dir"
        self.state_repo = self.root / "state_repo"
        self.site_packages = self.root / "site-packages"
        self.pkg_root = self.site_packages / "disk_magician"
        self.source_root = self.root / "source_repo"
        self.fleet_file = self.root / "fleet.json"

        self.state_dir.mkdir(parents=True, exist_ok=True)
        self.state_repo.mkdir(parents=True, exist_ok=True)
        self.pkg_root.mkdir(parents=True, exist_ok=True)
        self.source_root.mkdir(parents=True, exist_ok=True)

        self.now = datetime.now(timezone.utc)
        self.now_str = self.now.strftime("%Y-%m-%dT%H:%M:%SZ")

        # 1. Source repo initialization
        self._git_cmd(self.source_root, ["init"])
        self._git_cmd(self.source_root, ["config", "user.email", "jleechan2015@users.noreply.github.com"])
        self._git_cmd(self.source_root, ["config", "user.name", "Test User"])
        (self.source_root / "pyproject.toml").write_text("[project]\nname = 'disk-magician'\nversion = '0.2.0'\n", encoding="utf-8")
        self._git_cmd(self.source_root, ["add", "pyproject.toml"])
        self._git_cmd(self.source_root, ["commit", "-m", "initial commit"])
        self.source_sha = self._git_cmd(self.source_root, ["rev-parse", "HEAD"]).strip()

        # 2. Installed package & adjacent dist-info
        init_file = self.pkg_root / "__init__.py"
        init_content = b'"""disk_magician package"""\n__version__ = "0.2.0"\n'
        init_file.write_bytes(init_content)
        self.init_hash = sha256_bytes(init_content)

        plist_dir = self.pkg_root / "launchd"
        plist_dir.mkdir(parents=True, exist_ok=True)
        plist_file = plist_dir / "com.jleechanorg.disk-magician-snapshot.plist"
        plist_content = b'<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict></dict></plist>'
        plist_file.write_bytes(plist_content)
        self.plist_hash = sha256_bytes(plist_content)

        packaged_scanner = self.pkg_root / "scripts" / "disk_frontier_scan.py"
        packaged_scanner.parent.mkdir(parents=True, exist_ok=True)
        packaged_scanner.write_bytes(b"deployed root scanner\n")
        self.scanner_hash = sha256_bytes(packaged_scanner.read_bytes())
        self.package_hashes = {
            "__init__.py": self.init_hash,
            "launchd/com.jleechanorg.disk-magician-snapshot.plist": self.plist_hash,
            "scripts/disk_frontier_scan.py": self.scanner_hash,
        }

        dist_info = self.site_packages / "disk_magician-0.2.0.dist-info"
        dist_info.mkdir(parents=True, exist_ok=True)
        (dist_info / "METADATA").write_text("Metadata-Version: 2.1\nName: disk-magician\nVersion: 0.2.0\n", encoding="utf-8")

        # 3. deployed.json
        self.deployed_data = {
            "schema_version": 1,
            "source_sha": self.source_sha,
            "installed_version": "0.2.0",
            "deployed_at": (self.now - timedelta(minutes=15)).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "package_root": str(self.pkg_root),
            "package_hashes": dict(self.package_hashes),
            "source_root": str(self.source_root),
            "override_state": False,
        }
        with open(self.state_dir / "deployed.json", "w", encoding="utf-8") as f:
            json.dump(self.deployed_data, f)

        # 4. State repo initialization & committed strict ledger
        self._git_cmd(self.state_repo, ["init"])
        self._git_cmd(self.state_repo, ["config", "user.email", "jleechan2015@users.noreply.github.com"])
        self._git_cmd(self.state_repo, ["config", "user.name", "Test User"])
        (self.state_repo / "ledger").mkdir(parents=True, exist_ok=True)
        (self.state_repo / "snapshots").mkdir(parents=True, exist_ok=True)

        self.ledger_data = make_valid_strict_ledger(
            captured_at=(self.now - timedelta(hours=2)).strftime("%Y-%m-%dT%H:%M:%SZ")
        )
        strict_path = self.state_repo / "ledger" / "topdown-5g.json"
        with open(strict_path, "w", encoding="utf-8") as f:
            json.dump(self.ledger_data, f)

        commit_env = {
            **os.environ,
            "GIT_OPTIONAL_LOCKS": "0",
            "HERMES_SKIP_EXAMPLE_COM_GUARD": "1",
            "GIT_AUTHOR_DATE": (self.now - timedelta(hours=2)).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "GIT_COMMITTER_DATE": (self.now - timedelta(hours=2)).strftime("%Y-%m-%dT%H:%M:%SZ"),
        }
        subprocess.run(["git", "-C", str(self.state_repo), "add", "ledger/topdown-5g.json"], check=True, env=commit_env)
        subprocess.run(["git", "-C", str(self.state_repo), "commit", "-m", "commit ledger"], check=True, env=commit_env)

        # 5. Snapshots/disk_snapshot.json
        self.snapshot_data = {
            "schema_version": 2,
            "timestamp": (self.now - timedelta(minutes=20)).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "coverage_fresh_pct": 85.5,
            "carried_keys": [],
            "unmeasured_keys": [],
            "snapshot_metadata": {
                "captured_at": (self.now - timedelta(minutes=20)).strftime("%Y-%m-%dT%H:%M:%SZ"),
                "coverage_pct": 85.5,
                "measurement_status": "complete",
                "measurement_budget_exhausted": False,
            },
        }
        with open(self.state_repo / "snapshots" / "disk_snapshot.json", "w", encoding="utf-8") as f:
            json.dump(self.snapshot_data, f)

        # 6. Receipts
        self.store = JobReceiptStore(state_dir=str(self.state_dir))
        for job in ("snapshot_commit", "pressure_sweep", "tmp_scratch_sweep"):
            run_id = self.store.begin(job, trigger="scheduled")
            self.store.finish(
                job,
                run_id=run_id,
                outcome="success" if job != "pressure_sweep" else "success_noop",
                safety={"status": "safe", "reason": "verified safe by test harness"},
            )

        # 7. fleet.json
        self.fleet_data = {
            "schema_version": 1,
            "status": "healthy",
            "reason": "all_launchd_jobs_loaded",
            "checked_at": (self.now - timedelta(minutes=5)).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "records": [
                {
                    "label": "com.jleechanorg.disk-magician",
                    "loaded": True,
                    "execution_kind": "packaged_cli",
                    "package_root": str(self.pkg_root),
                    "identity_source": "installed_plist",
                },
                {
                    "label": "com.jleechanorg.disk-magician-snapshot",
                    "loaded": True,
                    "execution_kind": "repo_helper",
                    "execution_root": str(self.source_root),
                    "identity_source": "installed_plist",
                },
            ],
        }
        with open(self.fleet_file, "w", encoding="utf-8") as f:
            json.dump(self.fleet_data, f)

    def tearDown(self):
        self.tmp_dir.cleanup()

    def _git_cmd(self, repo: Path, args: list[str]) -> str:
        res = subprocess.run(
            ["git", "-C", str(repo)] + args,
            capture_output=True,
            text=True,
            check=True,
            env={**os.environ, "GIT_OPTIONAL_LOCKS": "0", "HERMES_SKIP_EXAMPLE_COM_GUARD": "1"},
        )
        return res.stdout

    def get_evaluator(self, **kwargs) -> disk_status.DiskStatusEvaluator:
        defaults = {
            "state_dir": self.state_dir,
            "state_repo": self.state_repo,
            "fleet_json": self.fleet_file,
            "now": self.now,
        }
        defaults.update(kwargs)
        return disk_status.DiskStatusEvaluator(**defaults)

    def test_all_healthy(self):
        evaluator = self.get_evaluator()
        result = evaluator.evaluate()
        self.assertEqual(result["status"], "healthy", f"Unexpected status: {result}")
        dims = result["dimensions"]
        self.assertEqual(dims["fleet"]["status"], "healthy")
        self.assertEqual(dims["measurement"]["status"], "healthy")
        self.assertEqual(dims["publication"]["status"], "healthy")
        self.assertEqual(dims["action_outcome"]["status"], "healthy")
        self.assertEqual(dims["safety"]["status"], "healthy")
        self.assertEqual(dims["deployed_identity"]["status"], "healthy")

    def test_readonly_invariant(self):
        """Evaluation MUST NOT create, delete, or alter any files, locks, or timestamps."""
        def snapshot_tree(root: Path):
            tree = {}
            for path in sorted(root.rglob("*")):
                if path.is_file():
                    stat = path.stat()
                    tree[str(path.relative_to(root))] = {
                        "size": stat.st_size,
                        "mtime_ns": stat.st_mtime_ns,
                        "sha256": disk_status.sha256_file(path),
                    }
            return tree

        before = snapshot_tree(self.root)

        evaluator = self.get_evaluator()
        result = evaluator.evaluate()
        self.assertEqual(result["status"], "healthy")

        rc = disk_status.main([
            "--json",
            "--state-dir", str(self.state_dir),
            "--state-repo", str(self.state_repo),
            "--fleet-json", str(self.fleet_file),
            "--now", self.now_str,
        ])
        self.assertEqual(rc, disk_status.EXIT_HEALTHY)

        after = snapshot_tree(self.root)
        self.assertEqual(before, after, "Evaluation modified files in state tree!")

    def test_measurement_stale_and_partial(self):
        snap_file = self.state_repo / "snapshots" / "disk_snapshot.json"

        # Missing snapshot -> unknown
        snap_file.unlink()
        evaluator = self.get_evaluator()
        res = evaluator.evaluate_measurement()
        self.assertEqual(res["status"], "unknown")
        self.assertEqual(res["reason"], "disk_snapshot_missing")

        # Corrupt JSON -> invalid
        snap_file.write_text("not json", encoding="utf-8")
        res = evaluator.evaluate_measurement()
        self.assertEqual(res["status"], "invalid")

        # Low coverage (< 70%) -> degraded
        self.snapshot_data["coverage_fresh_pct"] = 62.0
        self.snapshot_data["snapshot_metadata"]["coverage_pct"] = 62.0
        with open(snap_file, "w", encoding="utf-8") as f:
            json.dump(self.snapshot_data, f)
        res = evaluator.evaluate_measurement()
        self.assertEqual(res["status"], "degraded")
        self.assertIn("coverage_below_floor", res["reason"])

        # Stale (> 48h) -> degraded
        stale_time = (self.now - timedelta(hours=50)).strftime("%Y-%m-%dT%H:%M:%SZ")
        self.snapshot_data["coverage_fresh_pct"] = 85.0
        self.snapshot_data["timestamp"] = stale_time
        self.snapshot_data["snapshot_metadata"]["captured_at"] = stale_time
        with open(snap_file, "w", encoding="utf-8") as f:
            json.dump(self.snapshot_data, f)
        res = evaluator.evaluate_measurement()
        self.assertEqual(res["status"], "degraded")
        self.assertIn("snapshot_stale", res["reason"])

        # Carried keys present -> degraded
        fresh_time = (self.now - timedelta(minutes=10)).strftime("%Y-%m-%dT%H:%M:%SZ")
        self.snapshot_data["timestamp"] = fresh_time
        self.snapshot_data["snapshot_metadata"]["captured_at"] = fresh_time
        self.snapshot_data["carried_keys"] = ["/Users/foo/Library"]
        with open(snap_file, "w", encoding="utf-8") as f:
            json.dump(self.snapshot_data, f)
        res = evaluator.evaluate_measurement()
        self.assertEqual(res["status"], "degraded")

        # Probe 3: nested measurement_status='timeout' + budget_exhausted=True -> degraded
        self.snapshot_data["carried_keys"] = []
        self.snapshot_data["snapshot_metadata"]["measurement_status"] = "timeout"
        self.snapshot_data["snapshot_metadata"]["measurement_budget_exhausted"] = True
        with open(snap_file, "w", encoding="utf-8") as f:
            json.dump(self.snapshot_data, f)
        res = evaluator.evaluate_measurement()
        self.assertEqual(res["status"], "degraded")
        self.assertEqual(res["reason"], "measurement_status_timeout")

    def test_publication_dimensions(self):
        strict_file = self.state_repo / "ledger" / "topdown-5g.json"
        partial_file = self.state_repo / "ledger" / "topdown-5g.partial.json"
        sidecar_file = self.state_repo / "ledger" / "topdown-5g.status.json"

        # Stale strict ledger (> 48h) -> degraded
        stale_time = (self.now - timedelta(hours=50)).strftime("%Y-%m-%dT%H:%M:%SZ")
        stale_ledger = make_valid_strict_ledger(captured_at=stale_time)
        with open(strict_file, "w", encoding="utf-8") as f:
            json.dump(stale_ledger, f)
        c_env = {
            **os.environ,
            "GIT_OPTIONAL_LOCKS": "0",
            "HERMES_SKIP_EXAMPLE_COM_GUARD": "1",
            "GIT_AUTHOR_DATE": stale_time,
            "GIT_COMMITTER_DATE": stale_time,
        }
        subprocess.run(["git", "-C", str(self.state_repo), "add", "ledger/topdown-5g.json"], check=True, env=c_env)
        subprocess.run(["git", "-C", str(self.state_repo), "commit", "-m", "stale ledger commit"], check=True, env=c_env)

        evaluator = self.get_evaluator()
        res = evaluator.evaluate_publication()
        self.assertEqual(res["status"], "degraded")
        self.assertIn("strict_ledger_stale", res["reason"])

        # Strict missing, valid partial present -> degraded (never canonical)
        strict_file.unlink()
        valid_partial = make_valid_partial_ledger(captured_at=self.now_str)
        with open(partial_file, "w", encoding="utf-8") as f:
            json.dump(valid_partial, f)
        res = evaluator.evaluate_publication()
        self.assertEqual(res["status"], "degraded")
        self.assertEqual(res["reason"], "partial_publication_only_no_strict_ledger")

        # Both missing -> unknown
        partial_file.unlink()
        res = evaluator.evaluate_publication()
        self.assertEqual(res["status"], "unknown")
        self.assertEqual(res["reason"], "no_topdown_ledger_published")

        # Probe 4: strict valid ledger without .git commit -> unknown
        uncommitted_repo = self.root / "uncommitted_state_repo"
        (uncommitted_repo / "ledger").mkdir(parents=True, exist_ok=True)
        with open(uncommitted_repo / "ledger" / "topdown-5g.json", "w", encoding="utf-8") as f:
            json.dump(self.ledger_data, f)
        eval_uncommitted = self.get_evaluator(state_repo=uncommitted_repo)
        res = eval_uncommitted.evaluate_publication()
        self.assertEqual(res["status"], "unknown")
        self.assertEqual(res["reason"], "missing_git_publication_history")

        # Probe 5: malformed '{broken' in topdown-5g.status.json -> invalid
        with open(strict_file, "w", encoding="utf-8") as f:
            json.dump(self.ledger_data, f)
        with open(sidecar_file, "w", encoding="utf-8") as f:
            f.write("{broken json")
        res = evaluator.evaluate_publication()
        self.assertEqual(res["status"], "invalid")
        self.assertIn("sidecar_malformed", res["reason"])
        sidecar_file.unlink()

        # Restore fresh valid strict ledger commit
        with open(strict_file, "w", encoding="utf-8") as f:
            json.dump(self.ledger_data, f)
        fresh_commit_env = {
            **os.environ,
            "GIT_OPTIONAL_LOCKS": "0",
            "HERMES_SKIP_EXAMPLE_COM_GUARD": "1",
            "GIT_AUTHOR_DATE": (self.now - timedelta(hours=2)).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "GIT_COMMITTER_DATE": (self.now - timedelta(hours=2)).strftime("%Y-%m-%dT%H:%M:%SZ"),
        }
        subprocess.run(["git", "-C", str(self.state_repo), "add", "ledger/topdown-5g.json"], check=True, env=fresh_commit_env)
        subprocess.run(["git", "-C", str(self.state_repo), "commit", "-m", "fresh strict commit"], check=True, env=fresh_commit_env)

        # Terra repro: malformed partial {"schema_version":2,"publication_kind":"partial"} beside valid strict -> invalid
        with open(partial_file, "w", encoding="utf-8") as f:
            json.dump({"schema_version": 2, "publication_kind": "partial"}, f)
        res = evaluator.evaluate_publication()
        self.assertEqual(res["status"], "invalid")

        # Structurally valid partial with missing captured_at -> invalid
        partial_missing_time = make_valid_partial_ledger(captured_at=self.now_str)
        del partial_missing_time["captured_at"]
        with open(partial_file, "w", encoding="utf-8") as f:
            json.dump(partial_missing_time, f)
        res = evaluator.evaluate_publication()
        self.assertEqual(res["status"], "invalid")

        # Structurally valid partial with future captured_at -> invalid
        future_time = (self.now + timedelta(hours=2)).strftime("%Y-%m-%dT%H:%M:%SZ")
        partial_future_time = make_valid_partial_ledger(captured_at=future_time)
        with open(partial_file, "w", encoding="utf-8") as f:
            json.dump(partial_future_time, f)
        res = evaluator.evaluate_publication()
        self.assertEqual(res["status"], "invalid")

        # Structurally invalid partial with valid time -> invalid
        bad_partial = make_valid_partial_ledger(captured_at=self.now_str)
        bad_partial["residual_kb"] = 9999999
        with open(partial_file, "w", encoding="utf-8") as f:
            json.dump(bad_partial, f)
        res = evaluator.evaluate_publication()
        self.assertEqual(res["status"], "invalid")
        self.assertIn("partial_ledger_integrity_violation", res["reason"])

        # Legitimate newer valid partial beside strict -> degraded
        newer_partial = make_valid_partial_ledger(captured_at=self.now_str)
        with open(partial_file, "w", encoding="utf-8") as f:
            json.dump(newer_partial, f)
        res = evaluator.evaluate_publication()
        self.assertEqual(res["status"], "degraded")

        # Older valid partial beside strict -> strict healthy
        older_time = (self.now - timedelta(hours=3)).strftime("%Y-%m-%dT%H:%M:%SZ")
        older_partial = make_valid_partial_ledger(captured_at=older_time)
        with open(partial_file, "w", encoding="utf-8") as f:
            json.dump(older_partial, f)
        res = evaluator.evaluate_publication()
        self.assertEqual(res["status"], "healthy")
        self.assertEqual(res["reason"], "strict_ledger_current_and_valid")
        partial_file.unlink()

        # Publication-only mode flag returns only publication dimension
        with open(sidecar_file, "w", encoding="utf-8") as f:
            f.write("{broken json")
        result = evaluator.evaluate(publication_only=True)
        self.assertIn("publication", result["dimensions"])
        self.assertEqual(len(result["dimensions"]), 1)
        self.assertEqual(result["status"], "invalid")

    def test_action_outcomes(self):
        evaluator = self.get_evaluator()

        # Probe 1: store.begin after existing success -> returns unknown (in progress), NOT healthy
        self.store.begin("snapshot_commit", trigger="scheduled")
        res = evaluator.evaluate_action_outcome()
        self.assertEqual(res["status"], "unknown")
        self.assertIn("snapshot_commit", res["reason"])
        self.assertEqual(res["details"]["snapshot_commit"]["status"], "unknown")

        # Terminal error -> degraded
        run_id = self.store.begin("pressure_sweep", trigger="pressure")
        self.store.finish(
            "pressure_sweep",
            run_id=run_id,
            outcome="error",
        )
        res = evaluator.evaluate_action_outcome()
        self.assertEqual(res["status"], "degraded")
        self.assertIn("pressure_sweep: outcome error", res["reason"])

        # Stale receipt -> degraded
        receipt_file = self.state_dir / "receipts" / "snapshot_commit.json"
        with open(receipt_file, "r") as f:
            data = json.load(f)
        stale_start = (self.now - timedelta(hours=5, minutes=1)).strftime("%Y-%m-%dT%H:%M:%SZ")
        stale_end = (self.now - timedelta(hours=5)).strftime("%Y-%m-%dT%H:%M:%SZ")
        data["active"] = []
        data["last_terminal"]["times"]["started_at"] = stale_start
        data["last_terminal"]["times"]["ended_at"] = stale_end
        data["last_terminal"]["times"]["duration_seconds"] = 60.0
        with open(receipt_file, "w") as f:
            json.dump(data, f)
        res = evaluator.evaluate_action_outcome()
        self.assertEqual(res["status"], "degraded")
        self.assertIn("snapshot_commit: stale", res["reason"])

        # Interrupted active run (> 4h) without terminal -> unknown
        data["last_terminal"] = None
        data["active"] = [{
            "id": "interrupted-run",
            "job": "snapshot_commit",
            "outcome": "unknown",
            "times": {"started_at": stale_start, "ended_at": None},
        }]
        with open(receipt_file, "w") as f:
            json.dump(data, f)
        res = evaluator.evaluate_action_outcome()
        self.assertEqual(res["details"]["snapshot_commit"]["status"], "unknown")
        self.assertIn("interrupted", res["reason"])

        # Skipped without prior success -> degraded
        store_fresh = JobReceiptStore(state_dir=str(self.root / "empty_state"))
        store_fresh.record_skip("snapshot_commit", outcome="skipped_lock")
        eval_skip = self.get_evaluator(state_dir=self.root / "empty_state")
        res = eval_skip.evaluate_action_outcome()
        self.assertEqual(res["status"], "degraded")
        self.assertIn("skip without prior success", res["reason"])

        # Corrupt receipt file -> invalid
        corrupt_receipt = self.state_dir / "receipts" / "snapshot_commit.json"
        corrupt_receipt.write_text("{bad json", encoding="utf-8")
        res = evaluator.evaluate_action_outcome()
        self.assertEqual(res["status"], "invalid")

    def test_superseded_interrupted_receipts_require_locked_strictly_newer_terminal(self):
        def set_receipt(job, active_started, terminal_started, *, locked=True, terminal_time_valid=True):
            store = JobReceiptStore(state_dir=str(self.state_dir))
            run_id = store.begin(job, trigger="scheduled")
            data = json.loads((self.state_dir / "receipts" / f"{job}.json").read_text())
            active = next(record for record in data["active"] if record["id"] == run_id)
            active["times"]["started_at"] = active_started
            terminal = dict(data["last_terminal"])
            terminal["outcome"] = "success"
            terminal["lock"] = {"held": locked, "acquired": locked}
            terminal["safety"] = {"status": "safe", "reason": "serialized job lock"}
            terminal["times"] = {
                "started_at": terminal_started if terminal_time_valid else "not-a-time",
                "ended_at": self.now_str,
                "duration_seconds": 60.0,
            }
            data["active"] = [active]
            data["last_terminal"] = terminal
            data["last_success"] = terminal
            receipt_file_for_job = self.state_dir / "receipts" / f"{job}.json"
            receipt_file_for_job.write_text(json.dumps(data), encoding="utf-8")
            return receipt_file_for_job, active, terminal

        old_start = (self.now - timedelta(hours=5)).strftime("%Y-%m-%dT%H:%M:%SZ")
        terminal_start = (self.now - timedelta(minutes=10)).strftime("%Y-%m-%dT%H:%M:%SZ")
        receipt, old_record, terminal = set_receipt(
            "snapshot_commit", old_start, terminal_start
        )
        before = receipt.read_bytes()
        evaluator = self.get_evaluator()
        action = evaluator.evaluate_action_outcome()["details"]["snapshot_commit"]
        safety = evaluator.evaluate_safety()["details"]["snapshot_commit"]
        self.assertEqual(action["status"], "healthy", action)
        self.assertEqual(action["latest_attempt"]["id"], terminal["id"])
        self.assertEqual(action["active_records"], [])
        self.assertEqual(action["superseded_interrupted"][0]["id"], old_record["id"])
        self.assertEqual(
            action["superseded_interrupted"][0]["classification"],
            "superseded_interrupted",
        )
        self.assertEqual(safety["status"], "healthy")
        self.assertEqual(safety["superseded_interrupted"][0]["id"], old_record["id"])
        self.assertEqual(receipt.read_bytes(), before)

        pressure_receipt, pressure_old, _ = set_receipt(
            "pressure_sweep", old_start, terminal_start
        )
        pressure_action = evaluator.evaluate_action_outcome()["details"]["pressure_sweep"]
        pressure_safety = evaluator.evaluate_safety()["details"]["pressure_sweep"]
        self.assertEqual(pressure_action["status"], "unknown")
        self.assertEqual(pressure_action["active_records"][0]["id"], pressure_old["id"])
        self.assertEqual(pressure_action["superseded_interrupted"], [])
        self.assertEqual(pressure_safety["status"], "unknown")
        self.assertEqual(pressure_safety["superseded_interrupted"], [])

        cases = [
            ("newer active", terminal_start, terminal_start),
            ("equal timestamps", terminal_start, terminal_start),
            ("unproven lock", old_start, terminal_start),
        ]
        for label, active_start, terminal_time in cases:
            with self.subTest(label=label):
                locked = label != "unproven lock"
                receipt, active, _ = set_receipt(
                    "snapshot_commit",
                    active_start,
                    terminal_time,
                    locked=locked,
                    terminal_time_valid=True,
                )
                if label == "newer active":
                    data = json.loads(receipt.read_text())
                    data["active"][0]["times"]["started_at"] = (
                        self.now - timedelta(minutes=1)
                    ).strftime("%Y-%m-%dT%H:%M:%SZ")
                    receipt.write_text(json.dumps(data), encoding="utf-8")
                data = json.loads(receipt.read_text())
                if label == "equal timestamps":
                    data["active"][0]["times"]["started_at"] = terminal_start
                    receipt.write_text(json.dumps(data), encoding="utf-8")
                action = evaluator.evaluate_action_outcome()["details"]["snapshot_commit"]
                self.assertEqual(action["status"], "unknown")
                self.assertEqual(action["active_records"][0]["id"], active["id"])
                self.assertEqual(action["superseded_interrupted"], [])
                safety = evaluator.evaluate_safety()["details"]["snapshot_commit"]
                self.assertEqual(safety["status"], "unknown")
                self.assertEqual(safety["superseded_interrupted"], [])

        malformed_active = {
            "id": "malformed-active",
            "times": {"started_at": "not-a-time"},
        }
        malformed_superseded, malformed_current = disk_status.superseded_interrupted_records(
            "snapshot_commit", [malformed_active], terminal
        )
        self.assertEqual(malformed_superseded, [])
        self.assertEqual(malformed_current, [malformed_active])
        malformed_terminal = {**terminal, "times": {"started_at": "not-a-time"}}
        malformed_superseded, malformed_current = disk_status.superseded_interrupted_records(
            "snapshot_commit", [old_record], malformed_terminal
        )
        self.assertEqual(malformed_superseded, [])
        self.assertEqual(malformed_current, [old_record])
        for malformed_times in ("not-a-mapping", ["started_at", "ended_at"]):
            malformed_terminal_container = {**terminal, "times": malformed_times}
            malformed_superseded, malformed_current = disk_status.superseded_interrupted_records(
                "snapshot_commit", [old_record], malformed_terminal_container
            )
            self.assertEqual(malformed_superseded, [])
            self.assertEqual(malformed_current, [old_record])
        for invalid_outcome in (None, "in_progress", "unexpected", "skipped_lock"):
            invalid_terminal = {**terminal, "outcome": invalid_outcome}
            invalid_superseded, invalid_current = disk_status.superseded_interrupted_records(
                "snapshot_commit", [old_record], invalid_terminal
            )
            self.assertEqual(invalid_superseded, [])
            self.assertEqual(invalid_current, [old_record])
        wrong_job_terminal = {**terminal, "job": "pressure_sweep"}
        wrong_job_superseded, wrong_job_current = disk_status.superseded_interrupted_records(
            "snapshot_commit", [old_record], wrong_job_terminal
        )
        self.assertEqual(wrong_job_superseded, [])
        self.assertEqual(wrong_job_current, [old_record])
        wrong_job_active = {**old_record, "job": "pressure_sweep"}
        wrong_active_superseded, wrong_active_current = disk_status.superseded_interrupted_records(
            "snapshot_commit", [wrong_job_active], terminal
        )
        self.assertEqual(wrong_active_superseded, [])
        self.assertEqual(wrong_active_current, [wrong_job_active])
        malformed_container = {**old_record, "times": "not-a-mapping"}
        malformed_superseded, malformed_current = disk_status.superseded_interrupted_records(
            "snapshot_commit", [malformed_container], terminal
        )
        self.assertEqual(malformed_superseded, [])
        self.assertEqual(malformed_current, [malformed_container])
        incomplete_terminal = {**terminal, "times": {"started_at": terminal_start}}
        incomplete_superseded, incomplete_current = disk_status.superseded_interrupted_records(
            "snapshot_commit", [old_record], incomplete_terminal
        )
        self.assertEqual(incomplete_superseded, [])
        self.assertEqual(incomplete_current, [old_record])
        unknown_terminal = {**terminal, "outcome": "unknown"}
        unknown_superseded, unknown_current = disk_status.superseded_interrupted_records(
            "snapshot_commit", [old_record], unknown_terminal
        )
        self.assertEqual(unknown_superseded, [])
        self.assertEqual(unknown_current, [old_record])

        # tmp_scratch_sweep is unlocked and cannot use this lock proof.
        tmp_store = JobReceiptStore(state_dir=str(self.state_dir))
        tmp_id = tmp_store.begin("tmp_scratch_sweep", trigger="scheduled")
        tmp_file = self.state_dir / "receipts" / "tmp_scratch_sweep.json"
        tmp_data = json.loads(tmp_file.read_text())
        tmp_active = next(record for record in tmp_data["active"] if record["id"] == tmp_id)
        tmp_active["times"]["started_at"] = old_start
        tmp_terminal = dict(tmp_data["last_terminal"])
        tmp_terminal["outcome"] = "success"
        tmp_terminal["lock"] = {"held": True, "acquired": True}
        tmp_terminal["times"]["started_at"] = terminal_start
        tmp_terminal["times"]["ended_at"] = self.now_str
        tmp_data["active"] = [tmp_active]
        tmp_data["last_terminal"] = tmp_terminal
        tmp_file.write_text(json.dumps(tmp_data), encoding="utf-8")
        tmp_action = evaluator.evaluate_action_outcome()["details"]["tmp_scratch_sweep"]
        self.assertEqual(tmp_action["status"], "unknown")
        self.assertEqual(tmp_action["superseded_interrupted"], [])

    def test_malformed_run_identity_or_finished_active_stays_unknown(self):
        store = JobReceiptStore(state_dir=str(self.state_dir))
        old_run = store.begin("snapshot_commit", trigger="scheduled")
        terminal_run = store.begin("snapshot_commit", trigger="scheduled")
        store.finish(
            "snapshot_commit",
            run_id=terminal_run,
            outcome="success",
            safety={"status": "safe", "reason": "serialized job lock"},
        )
        receipt = self.state_dir / "receipts" / "snapshot_commit.json"
        base = json.loads(receipt.read_text())
        base["active"][0]["times"]["started_at"] = (
            self.now - timedelta(hours=5)
        ).strftime("%Y-%m-%dT%H:%M:%SZ")
        self.assertEqual(base["active"][0]["id"], old_run)
        self.assertEqual(base["last_terminal"]["id"], terminal_run)

        def mutate_active_outcome(data):
            data["active"][0]["outcome"] = "success"

        def mutate_active_ended_at(data):
            data["active"][0]["times"]["ended_at"] = self.now_str

        def mutate_active_alias(data):
            data["active"][0]["run_id"] = terminal_run

        def mutate_active_id_type(data):
            data["active"][0]["id"] = {"run_id": old_run}

        def mutate_terminal_id_type(data):
            data["last_terminal"]["id"] = {"run_id": terminal_run}

        def mutate_terminal_alias(data):
            data["last_terminal"]["run"] = old_run

        def mutate_terminal_schema(data):
            data["last_terminal"].pop("schema_version")

        def mutate_active_schema_bool(data):
            data["active"][0]["schema_version"] = True

        def mutate_terminal_schema_bool(data):
            data["last_terminal"]["schema_version"] = True

        malformed_cases = (
            ("active non-unknown outcome", mutate_active_outcome),
            ("active already ended", mutate_active_ended_at),
            ("active ID aliases disagree", mutate_active_alias),
            ("active object ID", mutate_active_id_type),
            ("terminal object ID", mutate_terminal_id_type),
            ("terminal ID aliases disagree", mutate_terminal_alias),
            ("terminal schema missing", mutate_terminal_schema),
            ("active boolean schema", mutate_active_schema_bool),
            ("terminal boolean schema", mutate_terminal_schema_bool),
        )
        env = {**os.environ, "DISK_MAGICIAN_STATE_DIR": str(self.state_dir)}
        status_cli = REPO_ROOT / "disk_magician.sh"

        def read_status():
            result = subprocess.run(
                [
                    str(status_cli), "status", "--json",
                    "--state-dir", str(self.state_dir),
                    "--state-repo", str(self.state_dir / "empty-state-repo"),
                    "--fleet-json", str(self.state_dir / "fleet.json"),
                ],
                env=env,
                capture_output=True,
                text=True,
                check=False,
            )
            return json.loads(result.stdout)

        for label, mutate in malformed_cases:
            with self.subTest(label=label):
                data = copy.deepcopy(base)
                mutate(data)
                receipt.write_text(json.dumps(data), encoding="utf-8")
                status = read_status()
                action = status["dimensions"]["action_outcome"]["details"]["snapshot_commit"]
                safety = status["dimensions"]["safety"]["details"]["snapshot_commit"]
                self.assertEqual(action["status"], "unknown", action)
                self.assertEqual(action["superseded_interrupted"], [])
                self.assertEqual(safety["status"], "unknown", safety)
                self.assertEqual(safety["superseded_interrupted"], [])

    def test_receipt_cli_reports_superseded_and_current_runs_without_mutation(self):
        with tempfile.TemporaryDirectory() as state_dir_str:
            state_dir = Path(state_dir_str)
            env = {**os.environ, "DISK_MAGICIAN_STATE_DIR": str(state_dir)}
            writer = SCRIPTS_DIR / "job_receipt.py"
            status_cli = REPO_ROOT / "disk_magician.sh"

            def invoke_writer(*args):
                return subprocess.run(
                    [sys.executable, str(writer), *args],
                    env=env,
                    capture_output=True,
                    text=True,
                    check=True,
                ).stdout.strip()

            old_run = invoke_writer("begin", "--job", "snapshot_commit")
            time.sleep(1.1)
            terminal_run = invoke_writer("begin", "--job", "snapshot_commit")
            invoke_writer(
                "finish",
                "--job", "snapshot_commit",
                "--run-id", terminal_run,
                "--outcome", "success",
                "--safety", '{"status":"safe","reason":"test receipt"}',
            )
            receipt_file = state_dir / "receipts" / "snapshot_commit.json"
            before = receipt_file.read_bytes()

            def read_status():
                result = subprocess.run(
                    [
                        str(status_cli), "status", "--json",
                        "--state-dir", str(state_dir),
                        "--state-repo", str(state_dir / "empty-state-repo"),
                        "--fleet-json", str(state_dir / "fleet.json"),
                    ],
                    env=env,
                    capture_output=True,
                    text=True,
                    check=False,
                )
                return json.loads(result.stdout)

            status = read_status()
            action = status["dimensions"]["action_outcome"]["details"]["snapshot_commit"]
            safety = status["dimensions"]["safety"]["details"]["snapshot_commit"]
            self.assertEqual(action["status"], "healthy")
            self.assertEqual(action["latest_attempt"]["id"], terminal_run)
            self.assertEqual(action["active_records"], [])
            self.assertEqual(action["superseded_interrupted"][0]["id"], old_run)
            self.assertEqual(safety["status"], "healthy")
            self.assertEqual(safety["superseded_interrupted"][0]["id"], old_run)
            self.assertEqual(receipt_file.read_bytes(), before)

            time.sleep(1.1)
            current_run = invoke_writer("begin", "--job", "snapshot_commit")
            status = read_status()
            action = status["dimensions"]["action_outcome"]["details"]["snapshot_commit"]
            safety = status["dimensions"]["safety"]["details"]["snapshot_commit"]
            self.assertEqual(action["status"], "unknown")
            self.assertEqual(action["active_records"][-1]["id"], current_run)
            self.assertEqual(action["latest_attempt"]["id"], current_run)
            self.assertEqual(action["superseded_interrupted"][0]["id"], old_run)
            self.assertEqual(safety["status"], "unknown")
            self.assertEqual(safety["superseded_interrupted"][0]["id"], old_run)

    def test_safety_evaluation(self):
        evaluator = self.get_evaluator()
        res = evaluator.evaluate_safety()
        self.assertEqual(res["status"], "healthy")

        # Probe 2: last_terminal.safety={'status':'delegated'} -> returns unknown, NOT healthy
        run_id = self.store.begin("snapshot_commit", trigger="scheduled")
        self.store.finish(
            "snapshot_commit",
            run_id=run_id,
            outcome="success",
            safety={"status": "delegated"},
        )
        res = evaluator.evaluate_safety()
        self.assertEqual(res["status"], "unknown")
        self.assertIn("safety delegated", res["reason"])

        # Receipt with blocked_safety -> degraded
        run_id = self.store.begin("tmp_scratch_sweep", trigger="manual")
        self.store.finish(
            "tmp_scratch_sweep",
            run_id=run_id,
            outcome="blocked_safety",
            safety={"status": "blocked_safety", "reason": "unauthorized_root"},
        )
        res = evaluator.evaluate_safety()
        self.assertEqual(res["status"], "degraded")
        self.assertIn("blocked_safety", res["reason"])

    def test_deployed_identity(self):
        deployed_path = self.state_dir / "deployed.json"
        evaluator = self.get_evaluator()

        # Missing deployed.json -> unknown
        deployed_path.unlink()
        res = evaluator.evaluate_deployed_identity()
        self.assertEqual(res["status"], "unknown")

        # Corrupt deployed.json -> invalid
        deployed_path.write_text("not json", encoding="utf-8")
        res = evaluator.evaluate_deployed_identity()
        self.assertEqual(res["status"], "invalid")

        # Probe 6: source_root=None or override_state=None -> invalid
        self.deployed_data["source_root"] = None
        with open(deployed_path, "w", encoding="utf-8") as f:
            json.dump(self.deployed_data, f)
        res = evaluator.evaluate_deployed_identity()
        self.assertEqual(res["status"], "invalid")
        self.assertIn("source_root_not_absolute", res["reason"])

        self.deployed_data["source_root"] = str(self.source_root)
        self.deployed_data["override_state"] = None
        with open(deployed_path, "w", encoding="utf-8") as f:
            json.dump(self.deployed_data, f)
        res = evaluator.evaluate_deployed_identity()
        self.assertEqual(res["status"], "invalid")
        self.assertIn("override_state_not_boolean", res["reason"])

        # Probe 7: symlink escaping package_root -> invalid
        self.deployed_data["override_state"] = False
        with open(deployed_path, "w", encoding="utf-8") as f:
            json.dump(self.deployed_data, f)
        escape_target = self.root / "outside_target.txt"
        escape_target.write_text("external")
        escape_symlink = self.pkg_root / "escape_link"
        escape_symlink.symlink_to(escape_target)
        res = evaluator.evaluate_deployed_identity()
        self.assertEqual(res["status"], "invalid")
        self.assertIn("symlink_target_escapes_package_root", res["reason"])
        escape_symlink.unlink()

        # Untracked plist on disk -> degraded
        extra_plist = self.pkg_root / "launchd" / "extra.plist"
        extra_plist.write_bytes(b"<plist></plist>")
        res = evaluator.evaluate_deployed_identity()
        self.assertEqual(res["status"], "degraded")
        self.assertIn("untracked_package_files_on_disk", res["reason"])
        extra_plist.unlink()

        # Fleet repo_helper observed root mismatch -> degraded
        mismatched_fleet = {
            "schema_version": 1,
            "status": "healthy",
            "checked_at": self.now_str,
            "records": [
                {
                    "label": "com.jleechanorg.disk-magician-snapshot",
                    "execution_kind": "repo_helper",
                    "execution_root": "/different/foreign/root",
                    "identity_source": "installed_plist",
                }
            ],
        }
        res = evaluator.evaluate_deployed_identity(fleet_info=mismatched_fleet)
        self.assertEqual(res["status"], "degraded")
        self.assertIn("observed_repo_helper_root_mismatch", res["reason"])

    def test_root_frontier_scanner_identity(self):
        evaluator = self.get_evaluator()
        root = self.root / "libexec"
        root.mkdir()
        scanner = root / "disk_frontier_scan.py"
        scanner.write_bytes(b"deployed root scanner\n")
        record = {
            "label": "com.jleechanorg.disk-magician-frontier-root",
            "execution_kind": "system",
            "identity_source": "installed_plist",
            "program_arguments": [str(root / "diskm"), "frontier"],
        }
        fleet = {"records": [record]}

        res = evaluator.evaluate_deployed_identity(fleet_info=fleet)
        self.assertEqual(res["status"], "healthy", res)

        scanner.write_bytes(b"stale root scanner\n")
        res = evaluator.evaluate_deployed_identity(fleet_info=fleet)
        self.assertEqual(res["status"], "degraded")
        self.assertIn("root_frontier_scanner_hash_mismatch", res["reason"])

        missing_root = self.root / "missing-libexec"
        missing_record = {**record, "program_arguments": [str(missing_root / "diskm"), "frontier"]}
        res = evaluator.evaluate_deployed_identity(fleet_info={"records": [missing_record]})
        self.assertEqual(res["status"], "degraded")
        self.assertIn("root_frontier_scanner_missing_or_unreadable", res["reason"])

        scanner.write_bytes(b"deployed root scanner\n")
        original_hash = disk_status.sha256_file
        def unreadable(path):
            if Path(path) == scanner:
                raise PermissionError("test unreadable")
            return original_hash(path)
        with mock.patch.object(disk_status, "sha256_file", side_effect=unreadable):
            res = evaluator.evaluate_deployed_identity(fleet_info=fleet)
        self.assertEqual(res["status"], "degraded")
        self.assertIn("root_frontier_scanner_missing_or_unreadable", res["reason"])

    def test_root_frontier_scanner_check_skips_unrelated_and_absent_service(self):
        evaluator = self.get_evaluator()
        res = evaluator.evaluate_deployed_identity(fleet_info={"records": []})
        self.assertEqual(res["status"], "healthy", res)
        res = evaluator.evaluate_deployed_identity(fleet_info={"records": [
            {"label": "unrelated-system-job",
             "execution_kind": "system", "identity_source": "installed_plist"}
        ]})
        self.assertEqual(res["status"], "healthy", res)

    def test_fleet_evaluation(self):
        evaluator = self.get_evaluator()

        # Healthy fleet json
        res = evaluator.evaluate_fleet()
        self.assertEqual(res["status"], "healthy")

        # Degraded fleet json
        with open(self.fleet_file, "w", encoding="utf-8") as f:
            json.dump({"status": "degraded", "reason": "unloaded_jobs", "records": []}, f)
        res = evaluator.evaluate_fleet()
        self.assertEqual(res["status"], "degraded")

        # Missing fleet json -> unknown
        self.fleet_file.unlink()
        res = evaluator.evaluate_fleet()
        self.assertEqual(res["status"], "unknown")

        # Non-darwin platform fallback -> healthy with launchd_not_applicable_on_platform
        eval_no_fleet = self.get_evaluator(fleet_json=None)
        with mock.patch("sys.platform", "linux"):
            res = eval_no_fleet.evaluate_fleet()
            self.assertEqual(res["status"], "healthy")
            self.assertEqual(res["reason"], "launchd_not_applicable_on_platform")

    def test_cli_exit_codes(self):
        # 1. Healthy -> exit 0
        rc = disk_status.main([
            "--state-dir", str(self.state_dir),
            "--state-repo", str(self.state_repo),
            "--fleet-json", str(self.fleet_file),
            "--now", self.now_str,
        ])
        self.assertEqual(rc, disk_status.EXIT_HEALTHY)

        # 2. Degraded -> exit 1
        with open(self.fleet_file, "w", encoding="utf-8") as f:
            json.dump({"status": "degraded", "reason": "flapping", "records": []}, f)
        rc = disk_status.main([
            "--state-dir", str(self.state_dir),
            "--state-repo", str(self.state_repo),
            "--fleet-json", str(self.fleet_file),
            "--now", self.now_str,
        ])
        self.assertEqual(rc, disk_status.EXIT_DEGRADED_OR_UNKNOWN)

        # 3. Invalid -> exit 2
        with open(self.fleet_file, "w", encoding="utf-8") as f:
            f.write("{invalid json")
        rc = disk_status.main([
            "--state-dir", str(self.state_dir),
            "--state-repo", str(self.state_repo),
            "--fleet-json", str(self.fleet_file),
            "--now", self.now_str,
        ])
        self.assertEqual(rc, disk_status.EXIT_INVALID)

        # 4. Invalid --now -> exit 2
        rc = disk_status.main(["--now", "invalid-timestamp"])
        self.assertEqual(rc, disk_status.EXIT_INVALID)


if __name__ == "__main__":
    unittest.main()
