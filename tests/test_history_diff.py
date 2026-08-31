#!/usr/bin/env python3
"""test_history_diff.py — unit + CLI-integration tests for
scripts/history_diff.py (sandboxed: tempfile git repos, no real $HOME)."""
import datetime
import json
import os
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
SYSTEM_BOUNDARY_PATHS = (
    "/System/Volumes/Data/.Spotlight-V100",
    "/System/Volumes/Data/.fseventsd",
    "/System/Volumes/Data/.DocumentRevisions-V100",
)
USER_PROBE_PATHS = {
    "mobile_sync": os.path.join(os.path.expanduser("~"), "Library", "Application Support", "MobileSync", "Backup"),
    "mail": os.path.join(os.path.expanduser("~"), "Library", "Mail"),
    "messages": os.path.join(os.path.expanduser("~"), "Library", "Messages"),
}
FORGED_USER_PROBE_PATHS = {
    "mobile_sync": "/Users/reviewer/../../tmp/forged/Library/Application Support/MobileSync/Backup",
    "mail": "/Users/reviewer/../../tmp/forged/Library/Mail",
    "messages": "/Users/reviewer/../../tmp/forged/Library/Messages",
}


def ledger(disk_used_kb, residual_kb, buckets, residual_label="test-residual", captured_at="2026-07-21T00:00:00Z"):
    bucket_total = sum(item.get("measured_kb", 0) for item in buckets)
    tail = disk_used_kb - bucket_total - residual_kb
    return {
        "schema_version": 2,
        "mode": "complete",
        "coverage_envelope": {
            "complete": True,
            "fda_preflight_status": "granted",
            "reachable_top_level_roots": 1,
            "measured_top_level_roots": 1,
            "unfinished_top_level_roots": 0,
        },
        "frontier_unfinished": [],
        "accounting_equation": {
            "displayed_balanced": tail >= 0, "display_ledger_valid": tail >= 0,
            "data_used_kb": disk_used_kb, "displayed_buckets_kb": bucket_total,
            "oversize_indivisible_files_kb": 0, "sub_granularity_tail_kb": tail,
            "purgeable_kb": 0, "residual_kb": residual_kb,
            "clone_shared_adjustment_kb": 0,
        },
        "captured_at": captured_at,
        "hostname": "sandbox-host",
        "disk_used_kb": disk_used_kb,
        "residual_kb": residual_kb,
        "residual_label": residual_label,
        "buckets": buckets,
        "opaque_intrinsic_gates": [],
    }


def attested_partial_ledger(disk_used_kb, residual_kb, buckets):
    result = ledger(disk_used_kb, residual_kb, buckets)
    user_probes = {
        name: {"path": path, "status": "readable"}
        for name, path in USER_PROBE_PATHS.items()
    }
    result.update(
        run_id="run-1", run_started_at=100.0, run_finished_at=102.0,
        fda_probe_paths=dict(USER_PROBE_PATHS),
    )
    result["coverage_envelope"].update(
        fda_preflight_status="partial", fda_user_preflight_status="granted"
    )
    result["fda_preflight"] = {
        "status": "partial",
        "probes": {
            **user_probes,
            "spotlight": {"path": SYSTEM_BOUNDARY_PATHS[0], "status": "permission_denied_or_tcc", "errno": 13},
            "fseventsd": {"path": SYSTEM_BOUNDARY_PATHS[1], "status": "permission_denied_or_tcc", "errno": 13},
            "document_revisions": {"path": SYSTEM_BOUNDARY_PATHS[2], "status": "permission_denied_or_tcc", "errno": 13},
        },
    }
    result["system_boundary_attestations"] = [
        {
            "run_id": "run-1", "path": path, "status": "permission_denied", "errno": 13,
            "captured_at": 101.0, "captured_during_run": True, "path_is_symlink": False,
            "verifier": {
                "effective_uid": 0,
                "access_context": "parent_scanner_confirmation",
                "fda": {"status": "granted", "probes": user_probes},
            },
            "identity_before": {"st_dev": 1, "st_ino": 2},
            "identity_after": {"st_dev": 1, "st_ino": 2},
        }
        for path in SYSTEM_BOUNDARY_PATHS
    ]
    result["opaque_intrinsic_gates"] = [
        {
            "path": path, "reason": "permission_denied_intrinsic", "errno": 13,
            "root_device": 1, "path_device": 1,
            "verification": "parent_scanner_system_boundary_confirmation",
            "reclaimable": False,
        }
        for path in SYSTEM_BOUNDARY_PATHS
    ]
    return result


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
        led = ledger(6 * GIB_KB, 0, [{"path": "/big", "measured_kb": 5 * GIB_KB + 1}])
        with self.assertRaises(hd.LedgerError) as ctx:
            hd.validate_ledger(led, label="oversize")
        self.assertIn("/big", str(ctx.exception))

    def test_reconciliation_mismatch_rejected(self):
        led = ledger(10, 1, [{"path": "/a", "measured_kb": 5}])
        led["accounting_equation"]["sub_granularity_tail_kb"] = 0
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

    def test_direct_allocation_segment_is_a_bounded_bucket(self):
        led = ledger(3 * GIB_KB, 1 * GIB_KB, [{
            "path": "/data [direct files + directory metadata]",
            "measured_kb": 1 * GIB_KB,
            "kind": "direct_allocation_segment",
        }])
        hd.validate_ledger(led, label="direct-segment")

    def test_intrinsic_gate_requires_metadata_and_has_no_size(self):
        led = ledger(1 * GIB_KB, 0, [{"path": "/a", "measured_kb": 1 * GIB_KB}])
        led["opaque_intrinsic_gates"] = [{
            "path": "/private/var/db/protected",
            "reason": "permission_denied_intrinsic",
            "root_device": 1,
            "path_device": 2,
            "verification": "root-owned persistent state",
            "reclaimable": False,
        }]
        hd.validate_ledger(led, label="intrinsic-gate")

        led["opaque_intrinsic_gates"][0]["measured_kb"] = 1
        with self.assertRaises(hd.LedgerError):
            hd.validate_ledger(led, label="sized-intrinsic-gate")

    def test_schema_v2_requires_opaque_intrinsic_gates(self):
        led = ledger(1 * GIB_KB, 0, [{"path": "/a", "measured_kb": 1 * GIB_KB}])
        del led["opaque_intrinsic_gates"]

        with self.assertRaises(hd.LedgerError) as ctx:
            hd.validate_ledger(led, label="missing-intrinsic-gates")
        self.assertIn("opaque_intrinsic_gates", str(ctx.exception))

    def test_positive_clone_adjustment_is_rejected(self):
        led = ledger(1 * GIB_KB, 0, [{"path": "/a", "measured_kb": 1 * GIB_KB}])
        led["accounting_equation"]["clone_shared_adjustment_kb"] = 1
        with self.assertRaises(hd.LedgerError):
            hd.validate_ledger(led, label="positive-clone-adjustment")

    def test_negative_clone_adjustment_is_in_exact_display_equation(self):
        led = ledger(1 * GIB_KB, 0, [{"path": "/a", "measured_kb": 2 * GIB_KB}])
        led["accounting_equation"]["clone_shared_adjustment_kb"] = -1 * GIB_KB
        led["accounting_equation"]["sub_granularity_tail_kb"] = 0
        led["accounting_equation"]["displayed_balanced"] = True
        led["accounting_equation"]["display_ledger_valid"] = True
        hd.validate_ledger(led, label="negative-clone-adjustment")
        hd.validate_full_attribution_ledger(led, label="negative-clone-adjustment")

    def test_attested_partial_system_boundary_ledger_is_full_attribution(self):
        led = attested_partial_ledger(3 * GIB_KB, 0, [{"path": "/a", "measured_kb": 1 * GIB_KB}])

        hd.validate_ledger(led, label="attested-partial")
        hd.validate_full_attribution_ledger(led, label="attested-partial")

    def test_partial_system_boundary_contract_rejects_missing_or_malformed_evidence(self):
        mutations = {
            "missing_preflight": lambda d: d.pop("fda_preflight"),
            "malformed_attestation": lambda d: d["system_boundary_attestations"][0].pop("verifier"),
            "noncatalog_gate": lambda d: d["opaque_intrinsic_gates"][0].update(path="/Users/test/private"),
            "unattested_gate": lambda d: d["opaque_intrinsic_gates"].pop(),
            "incomplete_system_probe": lambda d: d["fda_preflight"]["probes"].update(
                {"document_revisions": {"path": SYSTEM_BOUNDARY_PATHS[-1], "status": "readable"}}
            ),
        }
        for label, mutate in mutations.items():
            with self.subTest(label=label):
                candidate = attested_partial_ledger(3 * GIB_KB, 0, [{"path": "/a", "measured_kb": 1 * GIB_KB}])
                mutate(candidate)
                with self.assertRaises(hd.LedgerError):
                    hd.validate_full_attribution_ledger(candidate, label=label)

    def test_partial_contract_rejects_attestations_transplanted_from_another_run(self):
        candidate = attested_partial_ledger(3 * GIB_KB, 0, [{"path": "/a", "measured_kb": 1 * GIB_KB}])
        for attestation in candidate["system_boundary_attestations"]:
            attestation["run_id"] = "run-2"

        with self.assertRaises(hd.LedgerError):
            hd.validate_full_attribution_ledger(candidate, label="transplanted-attestations")

    def test_partial_contract_rejects_attestation_outside_run_window(self):
        candidate = attested_partial_ledger(3 * GIB_KB, 0, [{"path": "/a", "measured_kb": 1 * GIB_KB}])
        candidate["system_boundary_attestations"][0]["captured_at"] = 103.0

        with self.assertRaises(hd.LedgerError):
            hd.validate_full_attribution_ledger(candidate, label="outside-run-window")

    def test_partial_contract_rejects_substituted_user_probe_path(self):
        cases = [
            ("single_probe_tmp", lambda d: d["fda_preflight"]["probes"]["mail"].update(path="/tmp/mail")),
            ("catalog_tmp_exact", lambda d: (
                d["fda_probe_paths"].update(mail="/tmp"),
                d["fda_preflight"]["probes"]["mail"].update(path="/tmp"),
                [a["verifier"]["fda"]["probes"]["mail"].update(path="/tmp") for a in d["system_boundary_attestations"]],
            )),
            ("catalog_tmp_mail", lambda d: (
                d["fda_probe_paths"].update(mail="/tmp"),
                d["fda_preflight"]["probes"]["mail"].update(path="/tmp"),
                [a["verifier"]["fda"]["probes"]["mail"].update(path="/tmp") for a in d["system_boundary_attestations"]],
            )),
            ("catalog_foreign_home", lambda d: (
                d["fda_probe_paths"].update(mail="/Users/other/Library/Mail"),
                d["fda_preflight"]["probes"]["mail"].update(path="/Users/other/Library/Mail"),
                [a["verifier"]["fda"]["probes"]["mail"].update(path="/Users/other/Library/Mail") for a in d["system_boundary_attestations"]],
            )),
            ("catalog_tmp_home", lambda d: (
                d["fda_probe_paths"].update(
                    mobile_sync="/tmp/Library/Application Support/MobileSync/Backup",
                    mail="/tmp/Library/Mail",
                    messages="/tmp/Library/Messages",
                ),
                d["fda_preflight"]["probes"]["mobile_sync"].update(path="/tmp/Library/Application Support/MobileSync/Backup"),
                d["fda_preflight"]["probes"]["mail"].update(path="/tmp/Library/Mail"),
                d["fda_preflight"]["probes"]["messages"].update(path="/tmp/Library/Messages"),
                [a["verifier"]["fda"]["probes"].update({
                    "mobile_sync": {"path": "/tmp/Library/Application Support/MobileSync/Backup", "status": "readable"},
                    "mail": {"path": "/tmp/Library/Mail", "status": "readable"},
                    "messages": {"path": "/tmp/Library/Messages", "status": "readable"},
                }) for a in d["system_boundary_attestations"]],
            )),
            ("non_canonical_relative", lambda d: (
                d["fda_probe_paths"].update(mail=os.path.join(os.path.expanduser("~"), "Mail")),
                d["fda_preflight"]["probes"]["mail"].update(path=os.path.join(os.path.expanduser("~"), "Mail")),
                [a["verifier"]["fda"]["probes"]["mail"].update(path=os.path.join(os.path.expanduser("~"), "Mail")) for a in d["system_boundary_attestations"]],
            )),
            ("catalog_dot_segments", lambda d: (
                d["fda_probe_paths"].update(FORGED_USER_PROBE_PATHS),
                d["fda_preflight"]["probes"].update({
                    name: {"path": path, "status": "readable"}
                    for name, path in FORGED_USER_PROBE_PATHS.items()
                }),
                [a["verifier"]["fda"].update(probes={
                    name: {"path": path, "status": "readable"}
                    for name, path in FORGED_USER_PROBE_PATHS.items()
                }) for a in d["system_boundary_attestations"]],
            )),
        ]
        for name, mutate in cases:
            with self.subTest(case=name):
                candidate = attested_partial_ledger(3 * GIB_KB, 0, [{"path": "/a", "measured_kb": 1 * GIB_KB}])
                mutate(candidate)
                with self.assertRaises(hd.LedgerError):
                    hd.validate_full_attribution_ledger(candidate, label=name)


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


def _git(repo, *args):
    return subprocess.run(
        ["git", "-C", str(repo), *args],
        capture_output=True, text=True, check=True,
    )


def _write_ledger_commit(repo, ledger_obj, msg, committed_at=None):
    ledger_dir = repo / "ledger"
    ledger_dir.mkdir(exist_ok=True)
    (ledger_dir / "topdown-5g.json").write_text(json.dumps(ledger_obj))
    _git(repo, "add", "ledger/topdown-5g.json")
    env = None
    if committed_at:
        env = {**os.environ, "GIT_AUTHOR_DATE": committed_at, "GIT_COMMITTER_DATE": committed_at}
    subprocess.run(
        ["git", "-C", str(repo), "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", msg],
        capture_output=True, text=True, check=True, env=env,
    )


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

    def _run_cli_without_state_override(self, *args, **env_overrides):
        env = os.environ.copy()
        env.pop("DISK_MAGICIAN_STATE_REPO", None)
        env.pop("DISK_MAGICIAN_CONFIG", None)
        env.update(env_overrides)
        return subprocess.run(
            [sys.executable, str(SCRIPT), *args],
            capture_output=True, text=True, env=env,
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

    def test_cli_accepts_attested_partial_system_boundary_ledgers(self):
        base = attested_partial_ledger(1 * GIB_KB, 0, [{"path": "/a", "measured_kb": 1 * GIB_KB}])
        _write_ledger_commit(self.repo, base, "base")
        target = attested_partial_ledger(2 * GIB_KB, 0, [
            {"path": "/a", "measured_kb": 1 * GIB_KB},
            {"path": "/growth", "measured_kb": 1 * GIB_KB},
        ])
        _write_ledger_commit(self.repo, target, "target")

        result = self._run_cli()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("+1.00 GiB  /growth", result.stdout)

    def test_default_state_repo_matches_snapshot_config_resolver(self):
        configured_repo = self.tmp / "configured-state"
        configured_repo.mkdir()
        _git(configured_repo, "init", "-q", "-b", "main")
        base = ledger(1 * GIB_KB, 0, [{"path": "/a", "measured_kb": 1 * GIB_KB}])
        _write_ledger_commit(configured_repo, base, "base")
        target = ledger(2 * GIB_KB, 0, [
            {"path": "/a", "measured_kb": 1 * GIB_KB},
            {"path": "/growth", "measured_kb": 1 * GIB_KB},
        ])
        _write_ledger_commit(configured_repo, target, "target")

        config_home = self.tmp / "config-home"
        config_path = config_home / "disk-magician" / "config.json"
        config_path.parent.mkdir(parents=True)
        config_path.write_text(json.dumps({"state_repo_path": str(configured_repo)}))
        result = self._run_cli_without_state_override(
            HOME=str(self.tmp / "home"),
            XDG_CONFIG_HOME=str(config_home),
            XDG_STATE_HOME=str(self.tmp / "different-xdg-state"),
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("+1.00 GiB  /growth", result.stdout)

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

    def test_days_selects_lowest_valid_used_ledger_in_window(self):
        now = datetime.datetime.now(datetime.timezone.utc)
        old = (now - datetime.timedelta(days=4)).strftime("%Y-%m-%dT%H:%M:%S%z")
        floor = (now - datetime.timedelta(days=2)).strftime("%Y-%m-%dT%H:%M:%S%z")
        head = (now - datetime.timedelta(hours=1)).strftime("%Y-%m-%dT%H:%M:%S%z")
        _write_ledger_commit(
            self.repo, ledger(4 * GIB_KB, 0, [{"path": "/a", "measured_kb": 4 * GIB_KB}]),
            "old", old,
        )
        _write_ledger_commit(
            self.repo, ledger(2 * GIB_KB, 0, [{"path": "/a", "measured_kb": 2 * GIB_KB}]),
            "floor", floor,
        )
        _write_ledger_commit(
            self.repo, ledger(5 * GIB_KB, 0, [
                {"path": "/a", "measured_kb": 2 * GIB_KB},
                {"path": "/growth", "measured_kb": 3 * GIB_KB},
            ]), "head", head,
        )
        result = self._run_cli("--days", "3")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("floor (3d):", result.stdout)
        self.assertIn("+3.00 GiB  /growth", result.stdout)

    def test_days_cannot_be_combined_with_explicit_ref(self):
        result = self._run_cli("HEAD~1", "--days", "7")
        self.assertEqual(result.returncode, 2)
        self.assertIn("cannot be combined", result.stderr)

    def test_fail_closed_on_oversize_bucket_refuses_diff(self):
        base = ledger(1 * GIB_KB, 0, [{"path": "/a", "measured_kb": 1 * GIB_KB}])
        _write_ledger_commit(self.repo, base, "base")
        bad = ledger(6 * GIB_KB, 0, [{"path": "/opaque", "measured_kb": 6 * GIB_KB}])
        _write_ledger_commit(self.repo, bad, "bad")
        result = self._run_cli()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("/opaque", result.stderr)
        self.assertEqual(result.stdout, "")

    def test_diff_rejects_legacy_ledger(self):
        base = ledger(1 * GIB_KB, 0, [{"path": "/a", "measured_kb": 1 * GIB_KB}])
        for key in ("mode", "coverage_envelope", "frontier_unfinished", "accounting_equation"):
            base.pop(key)
        _write_ledger_commit(self.repo, base, "legacy")
        target = ledger(2 * GIB_KB, 0, [
            {"path": "/a", "measured_kb": 1 * GIB_KB},
            {"path": "/growth", "measured_kb": 1 * GIB_KB},
        ])
        _write_ledger_commit(self.repo, target, "target")
        result = self._run_cli()
        self.assertEqual(result.returncode, 2)
        self.assertIn("full-attribution ledger required", result.stderr)

    def test_diff_rejects_partial_ledger(self):
        base = ledger(1 * GIB_KB, 0, [{"path": "/a", "measured_kb": 1 * GIB_KB}])
        _write_ledger_commit(self.repo, base, "base")
        partial = ledger(2 * GIB_KB, 0, [
            {"path": "/a", "measured_kb": 1 * GIB_KB},
            {"path": "/growth", "measured_kb": 1 * GIB_KB},
        ])
        partial["mode"] = "partial"
        partial["coverage_envelope"]["complete"] = False
        _write_ledger_commit(self.repo, partial, "partial")
        result = self._run_cli()
        self.assertEqual(result.returncode, 2)
        self.assertIn("full-attribution ledger required", result.stderr)

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

    def test_validate_mode_labels_legacy_as_structural_partial(self):
        led_path = self.tmp / "legacy.json"
        legacy = ledger(1 * GIB_KB, 0, [{"path": "/a", "measured_kb": 1 * GIB_KB}])
        for key in ("mode", "coverage_envelope", "frontier_unfinished", "accounting_equation"):
            legacy.pop(key)
        led_path.write_text(json.dumps(legacy))
        result = subprocess.run(
            [sys.executable, str(SCRIPT), "--validate", str(led_path)],
            capture_output=True, text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("structural partial/legacy", result.stdout)

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


    def test_malformed_json_fails_closed_not_traceback(self):
        # cursor-agent adversarial finding 2026-07-21: malformed ledger JSON
        # must produce a clean "history diff: ..." diagnostic on stderr with a
        # nonzero rc, never an uncaught JSONDecodeError traceback.
        import subprocess, os
        bad = os.path.join(self.tmp, "bad.json")
        with open(bad, "w") as f:
            f.write("not{valid json")
        r = subprocess.run(
            ["python3", str(SCRIPT), "--validate", bad],
            capture_output=True, text=True,
        )
        self.assertNotEqual(r.returncode, 0)
        self.assertNotIn("Traceback", r.stderr)
        self.assertIn("not readable JSON", r.stderr + r.stdout)

if __name__ == "__main__":
    unittest.main()
