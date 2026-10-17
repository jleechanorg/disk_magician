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
    "mobile_sync": os.path.join("/Users/test-user", "Library", "Application Support", "MobileSync", "Backup"),
    "mail": os.path.join("/Users/test-user", "Library", "Mail"),
    "messages": os.path.join("/Users/test-user", "Library", "Messages"),
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

    def test_superseded_interrupted_records_serialized_jobs(self):
        evaluator = self.get_evaluator()
        for job in ("snapshot_commit", "pressure_sweep"):
            with self.subTest(job=job):
                store = JobReceiptStore(state_dir=str(self.state_dir))
                old_run = store.begin(job, trigger="scheduled")
                time_old = (self.now - timedelta(hours=5)).strftime("%Y-%m-%dT%H:%M:%SZ")
                receipt_file = self.state_dir / "receipts" / f"{job}.json"
                data = json.loads(receipt_file.read_text(encoding="utf-8"))
                for act in data["active"]:
                    if act["id"] == old_run:
                        act["times"]["started_at"] = time_old
                receipt_file.write_text(json.dumps(data), encoding="utf-8")

                terminal_run = store.begin(job, trigger="scheduled")
                store.finish(
                    job,
                    run_id=terminal_run,
                    outcome="success" if job == "snapshot_commit" else "success_noop",
                    safety={"status": "safe", "reason": "serialized lock held"},
                )
                before_bytes = receipt_file.read_bytes()

                res_action = evaluator.evaluate_action_outcome()
                action_detail = res_action["details"][job]
                self.assertEqual(action_detail["status"], "healthy")
                self.assertEqual(action_detail["latest_attempt"]["id"], terminal_run)
                self.assertEqual(action_detail["active_records"], [])
                self.assertEqual(len(action_detail["superseded_interrupted"]), 1)
                self.assertEqual(action_detail["superseded_interrupted"][0]["id"], old_run)

                res_safety = evaluator.evaluate_safety()
                safety_detail = res_safety["details"][job]
                self.assertEqual(safety_detail["status"], "healthy")
                self.assertEqual(len(safety_detail["superseded_interrupted"]), 1)
                self.assertEqual(safety_detail["superseded_interrupted"][0]["id"], old_run)

                self.assertEqual(receipt_file.read_bytes(), before_bytes)

    def test_unlocked_job_active_run_not_superseded(self):
        evaluator = self.get_evaluator()
        store = JobReceiptStore(state_dir=str(self.state_dir))
        old_run = store.begin("tmp_scratch_sweep", trigger="scheduled")
        time_old = (self.now - timedelta(hours=5)).strftime("%Y-%m-%dT%H:%M:%SZ")
        receipt_file = self.state_dir / "receipts" / "tmp_scratch_sweep.json"
        data = json.loads(receipt_file.read_text(encoding="utf-8"))
        for act in data["active"]:
            if act["id"] == old_run:
                act["times"]["started_at"] = time_old
        receipt_file.write_text(json.dumps(data), encoding="utf-8")

        terminal_run = store.begin("tmp_scratch_sweep", trigger="scheduled")
        store.finish(
            "tmp_scratch_sweep",
            run_id=terminal_run,
            outcome="success",
            safety={"status": "safe", "reason": "unlocked sweep completed"},
        )

        res_action = evaluator.evaluate_action_outcome()
        action_detail = res_action["details"]["tmp_scratch_sweep"]
        self.assertEqual(action_detail["status"], "unknown")
        self.assertEqual(action_detail["superseded_interrupted"], [])

        res_safety = evaluator.evaluate_safety()
        safety_detail = res_safety["details"]["tmp_scratch_sweep"]
        self.assertEqual(safety_detail["status"], "unknown")
        self.assertEqual(safety_detail["superseded_interrupted"], [])

    def test_genuinely_active_run_after_terminal_stays_unknown(self):
        evaluator = self.get_evaluator()
        store = JobReceiptStore(state_dir=str(self.state_dir))
        terminal_run = store.begin("snapshot_commit", trigger="scheduled")
        store.finish(
            "snapshot_commit",
            run_id=terminal_run,
            outcome="success",
            safety={"status": "safe", "reason": "lock held"},
        )
        active_run = store.begin("snapshot_commit", trigger="scheduled")

        res_action = evaluator.evaluate_action_outcome()
        action_detail = res_action["details"]["snapshot_commit"]
        self.assertEqual(action_detail["status"], "unknown")
        self.assertEqual(action_detail["active_records"][-1]["id"], active_run)
        self.assertEqual(action_detail["latest_attempt"]["id"], active_run)

        res_safety = evaluator.evaluate_safety()
        safety_detail = res_safety["details"]["snapshot_commit"]
        self.assertEqual(safety_detail["status"], "unknown")

    def test_malformed_run_identity_or_missing_lock_proof_stays_unknown(self):
        store = JobReceiptStore(state_dir=str(self.state_dir))
        old_run = store.begin("snapshot_commit", trigger="scheduled")
        terminal_run = store.begin("snapshot_commit", trigger="scheduled")
        store.finish(
            "snapshot_commit",
            run_id=terminal_run,
            outcome="success",
            safety={"status": "safe", "reason": "serialized job lock"},
        )
        receipt_file = self.state_dir / "receipts" / "snapshot_commit.json"
        base = json.loads(receipt_file.read_text(encoding="utf-8"))
        base["active"][0]["times"]["started_at"] = (
            self.now - timedelta(hours=5)
        ).strftime("%Y-%m-%dT%H:%M:%SZ")

        def mutate_terminal_missing_lock(data):
            data["last_terminal"]["lock"] = {"held": False, "acquired": False}

        def mutate_active_alias(data):
            data["active"][0]["run_id"] = terminal_run

        def mutate_terminal_alias(data):
            data["last_terminal"]["run"] = old_run

        def mutate_terminal_schema(data):
            data["last_terminal"]["schema_version"] = 999

        malformed_cases = (
            ("terminal missing lock proof", mutate_terminal_missing_lock),
            ("active ID aliases disagree", mutate_active_alias),
            ("terminal ID aliases disagree", mutate_terminal_alias),
            ("terminal schema version invalid", mutate_terminal_schema),
        )

        for label, mutate_fn in malformed_cases:
            with self.subTest(label=label):
                data = copy.deepcopy(base)
                mutate_fn(data)
                receipt_file.write_text(json.dumps(data), encoding="utf-8")
                evaluator = self.get_evaluator()
                action_res = evaluator.evaluate_action_outcome()
                action_detail = action_res["details"]["snapshot_commit"]
                self.assertEqual(action_detail["status"], "unknown")
                self.assertEqual(action_detail["superseded_interrupted"], [])

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

    def test_worktrees_degraded(self):
        leases = self.state_dir / "worktree_leases"
        leases.mkdir()
        ps = self.root / "fake-ps"
        ps.write_text("#!/bin/sh\n[ \"$2\" -gt 3 ] && exit 1\ncase \"$4\" in lstart=) echo 'Sat Oct 10 12:00:00 2026';; *) echo codex;; esac\n")
        ps.chmod(0o755)
        start = int(datetime(2026, 10, 10, 12, tzinfo=timezone.utc).timestamp())
        for i in range(123):
            (leases / f"{i}.json").write_text(json.dumps({
                "owner": {"pid": i + 1, "start_epoch": start, "comm": "codex"},
                "created_epoch": int(self.now.timestamp()), "creator": "guard",
                "last_verdict": "kept:dirty" if i >= 3 else None,
            }))
        self.snapshot_data["directories"] = {"worktrees_dot": 70 * 1024 * 1024}
        (self.state_repo / "snapshots/disk_snapshot.json").write_text(json.dumps(self.snapshot_data))
        with mock.patch.dict(os.environ, {"DISK_MAGICIAN_PS_BIN": str(ps)}):
            result = self.get_evaluator().evaluate()
        worktrees = result["worktrees"]
        self.assertEqual(worktrees["leases"]["alive"], 3)
        self.assertEqual(worktrees["leases"]["dead"], 120)
        self.assertEqual(worktrees["verdicts"], {"kept:dirty": 120})
        self.assertEqual(worktrees["coverage"], {"guard": 1.0})
        self.assertEqual(worktrees["created_per_day_7d"], 123 / 7)
        self.assertEqual(worktrees["root_gb"], 70)
        self.assertEqual(set(worktrees["degraded_reasons"]), {
            "worktree_root_over_60gb", "owner_dead_kept_over_100"})
        self.assertEqual(result["status"], "degraded")

    def test_worktrees_unreadable_coverage_approval_and_observer(self):
        leases = self.state_dir / "worktree_leases"
        leases.mkdir()
        for name, data in {
            "none": {"owner": None, "creator": "adopt", "created_epoch": 0},
            "released": {"owner": {"pid": 1}, "released_at": "today", "creator": "guard"},
            "invalid": {"owner": {"pid": "bad"}, "creator": "guard"},
        }.items():
            (leases / f"{name}.json").write_text(json.dumps(data))
        (leases / "broken.json").write_text("{bad")
        (leases / "array.json").write_text("[]")
        root = self.root / "custom-worktrees"
        (self.state_dir / "step_events.jsonl").write_text(json.dumps({
            "timestamp": self.now_str, "hot_dirs_kb": {str(root): 60 * 1024 * 1024}
        }) + "\n{bad\n")
        with mock.patch.dict(os.environ, {
            "DISK_MAGICIAN_STATE_DIR": str(self.state_dir),
            "STANDARD_WORKTREE_ROOT": str(root), "DISK_MAGICIAN_REAP_MODE": "remove",
        }):
            evaluator = self.get_evaluator(state_dir=None)
            result = evaluator.evaluate()["worktrees"]
            self.assertEqual(evaluator.state_dir, self.state_dir.resolve())
            self.assertEqual(result["leases"]["unreadable"], 3)
            self.assertEqual(result["leases"]["none"], 1)
            self.assertEqual(result["leases"]["released"], 1)
            self.assertEqual(result["coverage"], {"adopt": 0.0, "guard": 1.0})
            self.assertEqual(result["created_per_day_7d"], 0.0)
            self.assertEqual(result["root_gb"], 60)
            self.assertEqual(result["degraded_reasons"], [])
            self.assertTrue(result["remove_requested_not_approved"])
            (self.state_dir / "worktree_reap.remove_approved").touch()
            self.assertFalse(evaluator.evaluate()["worktrees"]["remove_requested_not_approved"])

    def test_worktrees_empty(self):
        result = self.get_evaluator().evaluate()
        self.assertEqual(result["worktrees"]["degraded_reasons"], [])
        self.assertIsNone(result["worktrees"]["root_gb"])
        self.assertEqual(sum(result["worktrees"]["leases"].values()), 0)
        self.assertEqual(result["status"], "healthy")

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

    def _commit_snapshot(self, snap_payload: dict, dt: datetime, msg: str = "commit snapshot") -> None:
        snap_path = self.state_repo / "snapshots" / "disk_snapshot.json"
        with open(snap_path, "w", encoding="utf-8") as f:
            json.dump(snap_payload, f)
        ts = dt.strftime("%Y-%m-%dT%H:%M:%SZ")
        c_env = {
            **os.environ,
            "GIT_OPTIONAL_LOCKS": "0",
            "HERMES_SKIP_EXAMPLE_COM_GUARD": "1",
            "GIT_AUTHOR_DATE": ts,
            "GIT_COMMITTER_DATE": ts,
        }
        subprocess.run(["git", "-C", str(self.state_repo), "add", "snapshots/disk_snapshot.json"], check=True, env=c_env)
        subprocess.run(["git", "-C", str(self.state_repo), "commit", "-m", msg], check=True, env=c_env)

    def _commit_ledger(self, ledger_payload: dict, dt: datetime, msg: str = "commit ledger") -> None:
        strict_path = self.state_repo / "ledger" / "topdown-5g.json"
        with open(strict_path, "w", encoding="utf-8") as f:
            json.dump(ledger_payload, f)
        ts = dt.strftime("%Y-%m-%dT%H:%M:%SZ")
        c_env = {
            **os.environ,
            "GIT_OPTIONAL_LOCKS": "0",
            "HERMES_SKIP_EXAMPLE_COM_GUARD": "1",
            "GIT_AUTHOR_DATE": ts,
            "GIT_COMMITTER_DATE": ts,
        }
        subprocess.run(["git", "-C", str(self.state_repo), "add", "ledger/topdown-5g.json"], check=True, env=c_env)
        subprocess.run(["git", "-C", str(self.state_repo), "commit", "-m", msg], check=True, env=c_env)

    def test_snapshot_coverage_streak_below_gate(self):
        import contextlib
        import io

        # Commit 1 high-coverage snapshot then 2 low-coverage snapshots (< default threshold 3)
        high_snap = copy.deepcopy(self.snapshot_data)
        high_snap["coverage_fresh_pct"] = 82.0
        high_snap["snapshot_coverage_pct"] = 82.0
        high_snap["snapshot_metadata"]["coverage_pct"] = 82.0
        self._commit_snapshot(high_snap, self.now - timedelta(hours=4), "snap high")

        low_snap_1 = copy.deepcopy(self.snapshot_data)
        low_snap_1.pop("coverage_fresh_pct", None)
        low_snap_1["snapshot_coverage_pct"] = 39.1
        low_snap_1["snapshot_metadata"].pop("coverage_pct", None)
        self._commit_snapshot(low_snap_1, self.now - timedelta(hours=3), "snap low 1")

        low_snap_2 = copy.deepcopy(self.snapshot_data)
        low_snap_2["coverage_fresh_pct"] = 41.9
        low_snap_2["snapshot_metadata"]["coverage_pct"] = 41.9
        self._commit_snapshot(low_snap_2, self.now - timedelta(hours=2), "snap low 2")

        evaluator = self.get_evaluator()
        res_2 = evaluator.evaluate()
        streak_2 = res_2["snapshot_coverage_streak_below_gate"]
        self.assertEqual(streak_2["consecutive_below_70"], 2)
        self.assertEqual(streak_2["status"], "ok")

        # Custom env threshold = 2 -> warn on 2 consecutive sub-70% commits
        with mock.patch.dict(os.environ, {"DISK_MAGICIAN_SNAPSHOT_LOW_COVERAGE_STREAK_WARN": "2"}):
            res_env2 = self.get_evaluator().evaluate()
            self.assertEqual(res_env2["snapshot_coverage_streak_below_gate"]["status"], "warn")
            self.assertEqual(res_env2["snapshot_coverage_streak_below_gate"]["consecutive_below_70"], 2)

        # Commit 3rd consecutive low-coverage snapshot -> hits default threshold 3
        low_snap_3 = copy.deepcopy(self.snapshot_data)
        low_snap_3["coverage_fresh_pct"] = 24.5
        low_snap_3["snapshot_coverage_pct"] = 24.5
        low_snap_3["snapshot_metadata"]["coverage_pct"] = 24.5
        self._commit_snapshot(low_snap_3, self.now - timedelta(hours=1), "snap low 3")

        res_3 = self.get_evaluator().evaluate()
        streak_3 = res_3["snapshot_coverage_streak_below_gate"]
        self.assertEqual(streak_3["status"], "warn")
        self.assertEqual(streak_3["consecutive_below_70"], 3)
        self.assertEqual(
            res_3["dimensions"]["measurement"]["details"]["snapshot_coverage_streak_below_gate"]["status"],
            "warn",
        )
        self.assertEqual(res_3["dimensions"]["measurement"]["status"], "degraded")
        self.assertIn("snapshot_coverage_streak_below_gate", res_3["dimensions"]["measurement"]["reason"])

        buf_json = io.StringIO()
        with contextlib.redirect_stdout(buf_json):
            rc_json = disk_status.main([
                "--json",
                "--state-dir", str(self.state_dir),
                "--state-repo", str(self.state_repo),
                "--fleet-json", str(self.fleet_file),
                "--now", self.now_str,
            ])
        self.assertEqual(rc_json, disk_status.EXIT_DEGRADED_OR_UNKNOWN)
        payload = json.loads(buf_json.getvalue())
        self.assertEqual(payload["snapshot_coverage_streak_below_gate"]["status"], "warn")
        self.assertEqual(payload["snapshot_coverage_streak_below_gate"]["consecutive_below_70"], 3)
        self.assertTrue(any("snapshot_coverage_streak_below_gate" in a for a in payload["alerts"]))

        buf_txt = io.StringIO()
        with contextlib.redirect_stdout(buf_txt):
            disk_status.main([
                "--state-dir", str(self.state_dir),
                "--state-repo", str(self.state_repo),
                "--fleet-json", str(self.fleet_file),
                "--now", self.now_str,
            ])
        self.assertIn("snapshot_coverage_streak_below_gate", buf_txt.getvalue())

        # Commit a fresh >= 70% snapshot -> resets consecutive streak to 0
        self._commit_snapshot(high_snap, self.now - timedelta(minutes=15), "snap recovered")
        res_rec = self.get_evaluator().evaluate()
        self.assertEqual(res_rec["snapshot_coverage_streak_below_gate"]["consecutive_below_70"], 0)
        self.assertEqual(res_rec["snapshot_coverage_streak_below_gate"]["status"], "ok")

    def test_ledger_30d_window_degraded(self):
        import contextlib
        import io

        # 1. Initial setUp has only 1 commit in last 30 days (2h ago) -> degraded 30d window
        res_single = self.get_evaluator().evaluate()
        win_single = res_single["ledger_30d_window_degraded"]
        self.assertEqual(win_single["status"], "warn")
        self.assertEqual(win_single["commits_30d"], 1)
        self.assertEqual(win_single["span_hours_30d"], 0.0)
        self.assertAlmostEqual(win_single["newest_age_hours"], 2.0, places=1)
        self.assertEqual(
            res_single["dimensions"]["publication"]["details"]["ledger_30d_window_degraded"]["status"],
            "warn",
        )

        buf_txt = io.StringIO()
        with contextlib.redirect_stdout(buf_txt):
            disk_status.main([
                "--state-dir", str(self.state_dir),
                "--state-repo", str(self.state_repo),
                "--fleet-json", str(self.fleet_file),
                "--now", self.now_str,
            ])
        self.assertIn("ledger_30d_window_degraded", buf_txt.getvalue())

        # 2. Second commit within < 24h (e.g. 1h ago, span = 1.0h < 24h) -> still warn
        dt_1h = self.now - timedelta(hours=1)
        self._commit_ledger(
            make_valid_strict_ledger(captured_at=dt_1h.strftime("%Y-%m-%dT%H:%M:%SZ")),
            dt_1h,
            "commit 1h ago",
        )
        res_short = self.get_evaluator().evaluate()
        win_short = res_short["ledger_30d_window_degraded"]
        self.assertEqual(win_short["status"], "warn")
        self.assertEqual(win_short["commits_30d"], 2)
        self.assertAlmostEqual(win_short["span_hours_30d"], 1.0, places=1)

        # 3. Commit spanning >= 24h (e.g. evaluation time advanced 5 days with fresh commit) -> healthy window
        future_now = self.now + timedelta(days=5)
        dt_fresh = future_now - timedelta(hours=1)
        self._commit_ledger(
            make_valid_strict_ledger(captured_at=dt_fresh.strftime("%Y-%m-%dT%H:%M:%SZ")),
            dt_fresh,
            "commit 5d later",
        )
        res_ok = self.get_evaluator(now=future_now).evaluate()
        win_ok = res_ok["ledger_30d_window_degraded"]
        self.assertEqual(win_ok["status"], "ok")
        self.assertFalse(win_ok["degraded"])
        self.assertEqual(win_ok["commits_30d"], 3)
        self.assertGreaterEqual(win_ok["span_hours_30d"], 24.0)
        self.assertAlmostEqual(win_ok["newest_age_hours"], 1.0, places=1)

        # 4. Newest canonical commit > 48h old -> warn
        stale_eval_now = future_now + timedelta(hours=55)
        res_stale = self.get_evaluator(now=stale_eval_now).evaluate()
        win_stale = res_stale["ledger_30d_window_degraded"]
        self.assertEqual(win_stale["status"], "warn")
        self.assertGreater(win_stale["newest_age_hours"], 48.0)


if __name__ == "__main__":
    unittest.main()
