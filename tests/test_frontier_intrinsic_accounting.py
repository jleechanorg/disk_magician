import errno
import os
import pathlib
import stat
import sys
import tempfile
import unittest
from types import SimpleNamespace
from unittest import mock

REPO = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "scripts"))
import disk_frontier_scan as frontier  # noqa: E402

GIB_KB = 1024 * 1024


class TestIntrinsicGateAccounting(unittest.TestCase):
    def test_root_without_scan_home_cannot_grant_user_fda_evidence(self):
        invalid_homes = (
            None,
            "",
            "relative/home",
            "/Users/fixture/../other",
            "/Users/fixture/",
            "/var/root",
            "/var/empty",
            "/tmp",
            "/private/tmp",
            "/Users/fixture/child",
        )
        for home in invalid_homes:
            with self.subTest(home=home), \
                 mock.patch.object(frontier.os, "geteuid", return_value=0), \
                 mock.patch.dict(
                     frontier.os.environ,
                     {} if home is None else {"DISK_MAGICIAN_SCAN_USER_HOME": home},
                     clear=True,
                 ):
                self.assertIsNone(frontier.scan_user_home())
                paths = frontier.fda_probe_paths("/fixture")
                self.assertNotIn("mobile_sync", paths)
                self.assertIsNone(frontier.fda_user_probe_evidence(frontier.fda_preflight(paths)))

    def test_root_scan_home_rejects_symlink_alias(self):
        with mock.patch.object(frontier.os, "geteuid", return_value=0), \
             mock.patch.dict(
                 frontier.os.environ,
                 {"DISK_MAGICIAN_SCAN_USER_HOME": "/Users/link"},
                 clear=True,
             ), \
             mock.patch.object(frontier.os.path, "realpath", return_value="/Users/real"):
            self.assertIsNone(frontier.scan_user_home())
            paths = frontier.fda_probe_paths("/fixture")
            self.assertNotIn("mobile_sync", paths)
            self.assertIsNone(frontier.fda_user_probe_evidence(frontier.fda_preflight(paths)))

    def test_root_scan_home_selects_exact_user_fda_probe_paths(self):
        with mock.patch.object(frontier.os, "geteuid", return_value=0), \
             mock.patch.dict(
                 frontier.os.environ,
                 {"DISK_MAGICIAN_SCAN_USER_HOME": "/Users/fixture"},
                 clear=True,
             ):
            self.assertEqual(frontier.scan_user_home(), "/Users/fixture")
            self.assertEqual(
                frontier.fda_probe_paths("/fixture"),
                {
                    "mobile_sync": "/Users/fixture/Library/Application Support/MobileSync/Backup",
                    "mail": "/Users/fixture/Library/Mail",
                    "messages": "/Users/fixture/Library/Messages",
                },
            )

    def test_nonroot_controlled_home_selects_exact_user_fda_probe_paths_and_report_catalog(self):
        expected = {
            "mobile_sync": "/Users/fixture/Library/Application Support/MobileSync/Backup",
            "mail": "/Users/fixture/Library/Mail",
            "messages": "/Users/fixture/Library/Messages",
        }
        scanner = self.scanner(effective_uid=501)
        with mock.patch.object(frontier.os, "geteuid", return_value=501), \
             mock.patch.dict(frontier.os.environ, {"HOME": "/Users/fixture"}, clear=True):
            self.assertEqual(frontier.scan_user_home(), "/Users/fixture")
            self.assertEqual(frontier.fda_probe_paths("/fixture"), expected)
            scanner.fda_probe_catalog = frontier.fda_probe_paths(scanner.root)
            report = self.report(scanner)

        self.assertEqual(report["fda_probe_paths"], expected)

    def test_nonroot_scan_home_rejects_tmp_before_deriving_fda_paths(self):
        for home in ("/tmp", "/Users/../tmp"):
            with self.subTest(home=home), \
                 mock.patch.object(frontier.os, "geteuid", return_value=501), \
                 mock.patch.dict(frontier.os.environ, {"HOME": home}, clear=True):
                self.assertIsNone(frontier.scan_user_home())
                self.assertEqual(frontier.fda_probe_paths("/fixture"), {})

    def test_fda_preflight_rejects_child_symlink_for_user_probes(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            for symlink_name, symlink_relative in frontier.FDA_PROBE_RELATIVE_PATHS.items():
                with self.subTest(symlink_name=symlink_name):
                    home = pathlib.Path(temp_dir) / symlink_name / "home"
                    outside = pathlib.Path(temp_dir) / symlink_name / "outside"
                    home.mkdir(parents=True)
                    outside.mkdir(parents=True)
                    paths = {}
                    for name, relative in frontier.FDA_PROBE_RELATIVE_PATHS.items():
                        path = home / relative
                        target = outside / relative
                        target.mkdir(parents=True)
                        if name == symlink_name:
                            path.parent.mkdir(parents=True, exist_ok=True)
                            path.symlink_to(target, target_is_directory=True)
                        else:
                            path.mkdir(parents=True)
                        paths[name] = str(path)

                    preflight = frontier.fda_preflight(paths)

                    self.assertNotEqual(preflight["status"], "granted")
                    self.assertIsNone(frontier.fda_user_probe_evidence(preflight))

    def test_fda_preflight_fails_closed_without_dir_fd_open_support(self):
        paths = {
            "mail": "/Users/fixture/Library/Mail",
            "messages": "/Users/fixture/Library/Messages",
        }

        with mock.patch.object(frontier.os, "supports_dir_fd", set()), \
             mock.patch.object(frontier.os, "open") as unsafe_open:
            with self.assertRaises(OSError) as raised:
                frontier._open_directory_no_follow(paths["mail"])
            self.assertEqual(raised.exception.errno, errno.ENOTSUP)
            preflight = frontier.fda_preflight(paths)

        self.assertEqual(preflight["status"], "indeterminate")
        self.assertEqual(preflight["errors"], list(paths))
        self.assertNotEqual(preflight["status"], "granted")
        unsafe_open.assert_not_called()
        for probe in preflight["probes"].values():
            self.assertEqual(probe["status"], "error")
            self.assertEqual(probe["errno"], errno.ENOTSUP)

    def test_fda_preflight_fails_closed_without_directory_open_support(self):
        paths = {
            "mail": "/Users/fixture/Library/Mail",
            "messages": "/Users/fixture/Library/Messages",
        }

        with mock.patch.object(frontier.os, "O_DIRECTORY", None), \
             mock.patch.object(frontier.os, "open") as unsafe_open, \
             mock.patch.object(frontier.os, "supports_dir_fd", {unsafe_open}):
            with self.assertRaises(OSError) as raised:
                frontier._open_directory_no_follow(paths["mail"])
            self.assertEqual(raised.exception.errno, errno.ENOTSUP)
            preflight = frontier.fda_preflight(paths)

        self.assertEqual(preflight["status"], "indeterminate")
        self.assertEqual(preflight["errors"], list(paths))
        self.assertIsNone(frontier.fda_user_probe_evidence(preflight))
        unsafe_open.assert_not_called()
        for probe in preflight["probes"].values():
            self.assertEqual(probe["status"], "error")
            self.assertEqual(probe["errno"], errno.ENOTSUP)

    def test_report_carries_configured_root_scan_home_probe_paths(self):
        scanner = self.scanner()
        with mock.patch.object(frontier.os, "geteuid", return_value=0), \
             mock.patch.dict(
                 frontier.os.environ,
                 {"DISK_MAGICIAN_SCAN_USER_HOME": "/Users/fixture"},
                 clear=True,
             ):
            scanner.fda_probe_catalog = frontier.fda_probe_paths(scanner.root)
            report = self.report(scanner)

        self.assertEqual(
            report["fda_probe_paths"],
            {
                "mobile_sync": "/Users/fixture/Library/Application Support/MobileSync/Backup",
                "mail": "/Users/fixture/Library/Mail",
                "messages": "/Users/fixture/Library/Messages",
            },
        )

    def test_report_preserves_empty_root_scan_home_catalog(self):
        scanner = self.scanner()
        scanner.fda_probe_catalog = {}
        with mock.patch.object(frontier.os, "geteuid", return_value=0), \
             mock.patch.dict(
                 frontier.os.environ,
                 {"DISK_MAGICIAN_SCAN_USER_HOME": "/Users/fixture"},
                 clear=True,
             ):
            report = self.report(scanner)

        self.assertEqual(
            report["fda_probe_paths"],
            {"mobile_sync": None, "mail": None, "messages": None},
        )

    @staticmethod
    def valid_attestation(**overrides):
        attestation = {
            "run_id": "run-1",
            "path": frontier.FDA_SYSTEM_PROBE_PATHS["spotlight"],
            "status": "permission_denied",
            "errno": errno.EACCES,
            "captured_at": 101.0,
            "captured_during_run": True,
            "path_is_symlink": False,
            "verifier": {
                "effective_uid": 0,
                "access_context": "parent_scanner_confirmation",
                "fda": {
                    "status": "granted",
                    "probes": {
                        "mobile_sync": {
                            "path": "/Users/jleechan/Library/Application Support/MobileSync/Backup",
                            "status": "readable",
                        },
                        "mail": {
                            "path": "/Users/jleechan/Library/Mail",
                            "status": "readable",
                        },
                        "messages": {
                            "path": "/Users/jleechan/Library/Messages",
                            "status": "readable",
                        },
                    },
                },
            },
            "identity_before": {"st_dev": 1, "st_ino": 44},
            "identity_after": {"st_dev": 1, "st_ino": 44},
        }
        attestation.update(overrides)
        return attestation

    def test_system_boundary_attestation_requires_all_same_run_evidence(self):
        valid = self.valid_attestation()
        kwargs = {
            "run_id": "run-1",
            "path": frontier.FDA_SYSTEM_PROBE_PATHS["spotlight"],
            "effective_uid": 0,
            "fda_preflight": valid["verifier"]["fda"],
            "run_started_at": 100.0,
            "run_finished_at": 102.0,
            "now": 102.0,
        }

        self.assertTrue(frontier.verify_system_boundary_attestation(valid, **kwargs))
        aggregate_fda = {
            "status": "partial",
            "probes": {
                **valid["verifier"]["fda"]["probes"],
                "spotlight": {"status": "permission_denied_or_tcc"},
                "fseventsd": {"status": "permission_denied_or_tcc"},
                "document_revisions": {"status": "permission_denied_or_tcc"},
            },
        }
        aggregate_candidate = self.valid_attestation(
            verifier={
                "effective_uid": 0,
                "access_context": "parent_scanner_confirmation",
                "fda": valid["verifier"]["fda"],
            }
        )
        self.assertTrue(
            frontier.verify_system_boundary_attestation(
                aggregate_candidate,
                **{**kwargs, "fda_preflight": aggregate_fda},
            )
        )
        for name, change in (
            ("stale run", {"run_id": "old-run"}),
            ("arbitrary path", {"path": "/Users/jleechan/private"}),
            ("readable result", {"status": "readable"}),
            ("timeout result", {"status": "timeout"}),
            ("identity mismatch", {"identity_after": {"st_dev": 1, "st_ino": 45}}),
            ("missing FDA evidence", {"verifier": {"effective_uid": 0}}),
            ("captured before run", {"captured_at": 99.0}),
            ("captured after run", {"captured_at": 103.0}),
        ):
            with self.subTest(name=name):
                candidate = self.valid_attestation(**change)
                self.assertFalse(
                    frontier.verify_system_boundary_attestation(candidate, **kwargs)
                )

    def test_system_boundary_attestation_captures_denial_and_stable_identity(self):
        path = frontier.FDA_SYSTEM_PROBE_PATHS["spotlight"]
        identity = SimpleNamespace(st_dev=7, st_ino=8, st_mode=stat.S_IFDIR)
        fda = self.valid_attestation()["verifier"]["fda"]
        with mock.patch.object(
            frontier.os.path,
            "realpath",
            side_effect=lambda candidate: path if candidate == path else candidate,
        ), \
             mock.patch.object(frontier.os.path, "islink", return_value=False), \
             mock.patch.object(frontier.os, "lstat", return_value=identity), \
             mock.patch.object(
                 frontier.os, "scandir",
                 side_effect=PermissionError(errno.EPERM, "denied", path),
             ):
            attestation = frontier.capture_system_boundary_attestation(
                path,
                run_id="run-1",
                effective_uid=0,
                fda_preflight=fda,
                run_started_at=100.0,
                now=101.0,
            )

        self.assertTrue(
            frontier.verify_system_boundary_attestation(
                attestation,
                run_id="run-1",
                path=path,
                effective_uid=0,
                fda_preflight=fda,
                run_started_at=100.0,
                run_finished_at=102.0,
                now=102.0,
            )
        )
        self.assertEqual(attestation["identity_before"], {"st_dev": 7, "st_ino": 8})
        self.assertEqual(attestation["identity_after"], {"st_dev": 7, "st_ino": 8})

    def scanner(self, *, effective_uid=0):
        return SimpleNamespace(
            root="/fixture",
            root_dev=1,
            effective_uid=effective_uid,
            measured={"/fixture/data": 12 * GIB_KB},
            inventory_buckets=[
                {"path": "/fixture/data [direct 1/3]", "kind": "direct_allocation_segment", "measured_kb": 5 * GIB_KB},
                {"path": "/fixture/data [direct 2/3]", "kind": "direct_allocation_segment", "measured_kb": 5 * GIB_KB},
                {"path": "/fixture/data [direct 3/3]", "kind": "direct_allocation_segment", "measured_kb": 2 * GIB_KB},
            ],
            oversize_files=[],
            frontier_unfinished=[
                {
                    "path": frontier.FDA_SYSTEM_PROBE_PATHS["spotlight"],
                    "reason": "inventory_permission_denied",
                },
                {
                    "path": frontier.FDA_SYSTEM_PROBE_PATHS["fseventsd"],
                    "reason": "inventory_permission_denied",
                },
                {
                    "path": frontier.FDA_SYSTEM_PROBE_PATHS["document_revisions"],
                    "reason": "inventory_permission_denied",
                },
                {"path": "/fixture/data/gone", "reason": "inventory_path_disappeared"},
                {"path": "/fixture/home", "reason": "cross_device_boundary"},
            ],
            deduped=[], warnings=[], nodes_processed=3,
            tracker=SimpleNamespace(peak=lambda: 1),
            level1_paths=["/fixture/data", "/fixture/home"],
            inventory_backend="gdu_one_pass", shallow_enumeration_depth=0,
            fda_preflight={
                "status": "granted",
                "probes": {
                    "mobile_sync": {
                        "path": "/Users/jleechan/Library/Application Support/MobileSync/Backup",
                        "status": "readable",
                    },
                    "mail": {
                        "path": "/Users/jleechan/Library/Mail",
                        "status": "readable",
                    },
                    "messages": {
                        "path": "/Users/jleechan/Library/Messages",
                        "status": "readable",
                    },
                },
            },
            run_id="run-1",
            run_started_at=100.0,
            run_finished_at=102.0,
            system_boundary_attestations=[
                TestIntrinsicGateAccounting.valid_attestation(path=path)
                for path in frontier.FDA_SYSTEM_PROBE_PATHS.values()
            ],
        )

    @staticmethod
    def args():
        return SimpleNamespace(
            workers=1, max_depth=6, max_nodes=100_000_000,
            wall_clock_cap=100, timeout_tiers=[10], granularity_gib=5,
        )

    @staticmethod
    def fake_lstat(path):
        if path.endswith("/gone"):
            raise FileNotFoundError(errno.ENOENT, "gone", path)
        return SimpleNamespace(st_dev=2 if path.endswith("/home") else 1)

    @staticmethod
    def fake_scandir(path):
        if path.endswith(("/denied", "/secret", ".Spotlight-V100")):
            raise PermissionError(errno.EPERM, "denied", path)
        raise AssertionError(f"unexpected scandir: {path}")

    def report(self, scanner):
        with mock.patch.object(frontier.os, "lstat", side_effect=self.fake_lstat), \
             mock.patch.object(frontier.os.path, "realpath", side_effect=lambda path: path), \
             mock.patch.object(frontier.os, "scandir", side_effect=self.fake_scandir):
            return frontier.build_report(
                scanner,
                {"total_kb": 20 * GIB_KB, "used_kb": 10 * GIB_KB, "free_kb": 10 * GIB_KB},
                [],
                {"purgeable_kb": 0, "purgeable_estimate_method": "fixture",
                 "local_snapshots": [], "local_snapshots_count": 0},
                1.0,
                self.args(),
            )

    def test_privileged_persistent_gates_complete_with_signed_adjustment(self):
        report = self.report(self.scanner())

        self.assertEqual(report["mode"], "complete")
        self.assertEqual(report["frontier_unfinished"], [])
        self.assertEqual(
            {item["reason"] for item in report["opaque_intrinsic_gates"]},
            {"permission_denied_intrinsic", "vanished_during_scan", "cross_device_boundary"},
        )
        self.assertEqual(report["accounting_equation"]["clone_shared_adjustment_kb"], -2 * GIB_KB)
        self.assertTrue(report["accounting_equation"]["displayed_balanced"])
        self.assertTrue(report["coverage_envelope"]["complete"])
        self.assertEqual(report["coverage_envelope"]["reachable_top_level_roots"], 1)
        self.assertEqual(report["coverage_envelope"]["measured_top_level_roots"], 1)

    def test_report_serializes_scanner_run_binding(self):
        report = self.report(self.scanner())

        self.assertEqual(report["run_id"], "run-1")
        self.assertEqual(report["run_started_at"], 100.0)
        self.assertEqual(report["run_finished_at"], 102.0)
        self.assertEqual(
            report["fda_probe_paths"],
            {
                "mobile_sync": "/Users/jleechan/Library/Application Support/MobileSync/Backup",
                "mail": "/Users/jleechan/Library/Mail",
                "messages": "/Users/jleechan/Library/Messages",
            },
        )

    def test_aggregate_partial_fda_with_catalog_attestation_is_complete(self):
        scanner = self.scanner()
        scanner.fda_preflight = {
            "status": "partial",
            "probes": {
                **scanner.fda_preflight["probes"],
                "spotlight": {"status": "permission_denied_or_tcc"},
                "fseventsd": {"status": "permission_denied_or_tcc"},
                "document_revisions": {"status": "permission_denied_or_tcc"},
            },
        }

        report = self.report(scanner)

        self.assertEqual(report["mode"], "complete")
        self.assertEqual(report["frontier_unfinished"], [])
        self.assertTrue(report["coverage_envelope"]["complete"])
        self.assertEqual(report["fda_preflight"]["status"], "partial")
        self.assertEqual(report["coverage_envelope"]["fda_preflight_status"], "partial")

    def test_unprivileged_permission_failure_remains_unfinished(self):
        report = self.report(self.scanner(effective_uid=501))

        self.assertEqual(report["mode"], "partial")
        self.assertIn("inventory_permission_denied", {item["reason"] for item in report["frontier_unfinished"]})
        self.assertFalse(report["coverage_envelope"]["complete"])

    def test_unmeasured_top_level_intrinsic_gate_is_opaque_not_unfinished(self):
        scanner = self.scanner()
        scanner.measured = {}
        scanner.inventory_buckets = []
        scanner.frontier_unfinished = [{
            "path": "/fixture/secret",
            "reason": "inventory_permission_denied",
        }]
        scanner.level1_paths = ["/fixture/secret"]

        report = self.report(scanner)

        self.assertEqual(report["mode"], "partial")
        self.assertIn(
            "inventory_permission_denied",
            {item["reason"] for item in report["frontier_unfinished"]},
        )
        self.assertFalse(report["coverage_envelope"]["complete"])
        self.assertEqual(report["top_level_ledger"][0]["status"], "unfinished")

    def test_arbitrary_path_attestation_remains_operational_partial(self):
        scanner = self.scanner()
        scanner.frontier_unfinished = [{
            "path": "/fixture/secret",
            "reason": "inventory_permission_denied",
        }]
        scanner.level1_paths = ["/fixture/secret"]
        scanner.system_boundary_attestations = [
            self.valid_attestation(path="/fixture/secret")
        ]

        report = self.report(scanner)

        self.assertEqual(report["mode"], "partial")
        self.assertEqual(report["opaque_intrinsic_gates"], [])
        self.assertEqual(report["frontier_unfinished"][0]["path"], "/fixture/secret")
        self.assertFalse(report["coverage_envelope"]["complete"])

    def test_transplanted_attestations_from_another_run_are_rejected(self):
        scanner = self.scanner()
        for attestation in scanner.system_boundary_attestations:
            attestation["run_id"] = "run-2"

        report = self.report(scanner)

        self.assertEqual(report["mode"], "partial")
        self.assertFalse(report["coverage_envelope"]["complete"])
        self.assertEqual(
            {item["path"] for item in report["frontier_unfinished"]},
            set(frontier.FDA_SYSTEM_PROBE_PATHS.values()),
        )
        self.assertEqual(
            [g for g in report["opaque_intrinsic_gates"] if g["reason"] == "permission_denied_intrinsic"],
            [],
        )

    def test_attestation_outside_report_run_window_is_rejected(self):
        for bad_time in (99.0, 103.0):
            with self.subTest(bad_time=bad_time):
                scanner = self.scanner()
                scanner.system_boundary_attestations[0]["captured_at"] = bad_time

                report = self.report(scanner)

                self.assertEqual(report["mode"], "partial")
                self.assertFalse(report["coverage_envelope"]["complete"])
                self.assertIn(
                    frontier.FDA_SYSTEM_PROBE_PATHS["spotlight"],
                    {item["path"] for item in report["frontier_unfinished"]},
                )

    def test_user_probe_substitution_is_rejected(self):
        scanner = self.scanner()
        scanner.fda_preflight = {
            "status": "granted",
            "probes": {
                "mobile_sync": {"status": "readable"},
                "mail": {"path": "/tmp/mail", "status": "readable"},
                "messages": {"status": "readable"},
            },
        }

        report = self.report(scanner)

        self.assertEqual(report["mode"], "partial")
        self.assertFalse(report["coverage_envelope"]["complete"])
        self.assertEqual(
            {item["path"] for item in report["frontier_unfinished"]},
            set(frontier.FDA_SYSTEM_PROBE_PATHS.values()),
        )

    def test_user_probe_catalog_rejects_dot_segment_normalization_bypass(self):
        forged_home = "/Users/reviewer/../../tmp/forged"
        catalog = {
            name: os.path.join(forged_home, relative)
            for name, relative in frontier.FDA_PROBE_RELATIVE_PATHS.items()
        }
        preflight = {
            "status": "granted",
            "probes": {
                name: {"path": path, "status": "readable"}
                for name, path in catalog.items()
            },
        }

        self.assertFalse(frontier.valid_user_probe_catalog(catalog))
        self.assertIsNone(frontier.fda_user_probe_evidence(preflight))

    def test_user_probe_catalog_rejects_child_symlink_alias(self):
        catalog = {
            name: os.path.join("/Users/fixture", relative)
            for name, relative in frontier.FDA_PROBE_RELATIVE_PATHS.items()
        }

        def fake_realpath(path):
            if path == catalog["mail"]:
                return "/tmp/forged/Library/Mail"
            return path

        with mock.patch.object(frontier.os.path, "realpath", side_effect=fake_realpath):
            self.assertFalse(frontier.valid_user_probe_catalog(catalog))

    def test_user_probe_catalog_requires_paths_for_readable_probes(self):
        preflight = {
            "status": "granted",
            "probes": {
                name: {"status": "readable"}
                for name in frontier.FDA_PROBE_RELATIVE_PATHS
            },
        }
        attestation = self.valid_attestation(
            verifier={
                "effective_uid": 0,
                "access_context": "parent_scanner_confirmation",
                "fda": preflight,
            }
        )

        self.assertIsNone(frontier.fda_user_probe_evidence(preflight))
        self.assertFalse(
            frontier.verify_system_boundary_attestation(
                attestation,
                run_id="run-1",
                path=frontier.FDA_SYSTEM_PROBE_PATHS["spotlight"],
                effective_uid=0,
                fda_preflight=preflight,
                run_started_at=100.0,
                run_finished_at=102.0,
                now=102.0,
            )
        )

    def test_reappeared_inventory_path_is_remeasured_once(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = pathlib.Path(temp_dir)
            failed = root / "System" / "Library" / "Speech"
            failed.mkdir(parents=True)
            safe = root / "System" / "Library" / "AssetsV2"
            safe.mkdir(parents=True)
            args = SimpleNamespace(
                root=str(root), resolve_root=False, workers=1, max_depth=6,
                max_nodes=100_000, wall_clock_cap=10, timeout_tiers=[10],
                no_sibling_volumes=True, no_purgeable=True, granularity_gib=5,
                shallow_enumeration_depth=0,
            )
            scanner = frontier.FrontierScanner(args)
            scanner.start_time = frontier.time.time()
            result = {
                "usable": True,
                "records": {str(safe): 4},
                "error_paths": [{
                    "path": str(failed),
                    "reason": "inventory_path_disappeared",
                }],
                "unknown_errors": [], "returncode": 1,
                "timed_out": False, "stderr": "",
            }
            with mock.patch.object(frontier, "run_gdu_inventory", return_value=result), \
                 mock.patch.object(frontier, "run_du", return_value=852) as measure:
                self.assertTrue(scanner.run_one_pass_inventory([(str(root / "System"), False)]))

            self.assertEqual(scanner.frontier_unfinished, [])
            self.assertEqual(scanner.measured[str(failed)], 852)
            self.assertEqual(
                [item for item in scanner.inventory_buckets if item["path"] == str(failed)],
                [{"path": str(failed), "measured_kb": 852}],
            )
            self.assertEqual(measure.call_count, 1)
            self.assertEqual(measure.call_args.args[0], str(failed))
            self.assertLessEqual(measure.call_args.args[1], 1)

    def test_reappeared_interrupted_inventory_path_is_remeasured_once(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = pathlib.Path(temp_dir)
            failed = root / "Users" / "jleechan" / "Evernote"
            failed.mkdir(parents=True)
            args = SimpleNamespace(
                root=str(root), resolve_root=False, workers=1, max_depth=6,
                max_nodes=100_000, wall_clock_cap=10, timeout_tiers=[10],
                no_sibling_volumes=True, no_purgeable=True, granularity_gib=5,
                shallow_enumeration_depth=0,
            )
            scanner = frontier.FrontierScanner(args)
            scanner.start_time = frontier.time.time()
            result = {
                "usable": True,
                "records": {},
                "error_paths": [{
                    "path": str(failed),
                    "reason": "inventory_interrupted_system_call",
                }],
                "unknown_errors": [], "returncode": 1,
                "timed_out": False, "stderr": "",
            }
            with mock.patch.object(frontier, "run_gdu_inventory", return_value=result), \
                 mock.patch.object(frontier, "run_du", return_value=852) as measure:
                self.assertTrue(scanner.run_one_pass_inventory([(str(root / "Users"), False)]))

            self.assertEqual(scanner.frontier_unfinished, [])
            self.assertEqual(scanner.measured[str(failed)], 852)
            self.assertEqual(
                scanner.inventory_buckets,
                [{"path": str(failed), "measured_kb": 852}],
            )
            self.assertEqual(measure.call_count, 1)
            self.assertEqual(measure.call_args.args[0], str(failed))
            self.assertLessEqual(measure.call_args.args[1], 1)


if __name__ == "__main__":
    unittest.main()
