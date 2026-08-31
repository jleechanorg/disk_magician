import datetime, json, os, subprocess, tempfile, unittest, pathlib, sys
from unittest import mock
REPO = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = REPO / "scripts" / "render_topdown_ledger.py"
sys.path.insert(0, str(REPO / "scripts"))
import render_topdown_ledger as renderer  # noqa: E402
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

    def _fixture(self, age_hours, *, mode="complete", envelope_complete=True):
        captured = (datetime.datetime.utcnow() - datetime.timedelta(hours=age_hours)).strftime(
            "%Y-%m-%dT%H:%M:%SZ"
        )
        data = {
            "schema_version": 2,
            "mode": mode,
            "coverage_envelope": {
                "complete": envelope_complete,
                "status": "complete" if envelope_complete else "partial",
                "fda_preflight_status": "granted",
                "reachable_top_level_roots": 1,
                "measured_top_level_roots": 1,
                "unfinished_top_level_roots": 0,
            },
            "captured_at": captured,
            "run_id": "run-1",
            "run_started_at": 100.0,
            "run_finished_at": 102.0,
            "fda_probe_paths": dict(USER_PROBE_PATHS),
            "hostname": "testhost",
            "disk_used_kb": 500 * 1024 * 1024,
            "residual_kb": 524288,  # 0.5 GiB
            "purgeable_kb": 1024,
            "granularity_buckets": [
                {"path": "/Users/x/big", "measured_kb": 3145728},    # 3.0 GiB
                {"path": "/Users/x/small", "measured_kb": 1048576},  # 1.0 GiB
            ],
            "oversize_indivisible_files": [],
            "accounting_equation": {
                "displayed_balanced": True, "display_ledger_valid": True,
                "data_used_kb": 500 * 1024 * 1024,
                "displayed_buckets_kb": 4194304,
                "oversize_indivisible_files_kb": 0,
                "sub_granularity_tail_kb": 519568384,
                "purgeable_kb": 1024, "residual_kb": 524288,
                "clone_shared_adjustment_kb": 0,
            },
            "frontier_unfinished": [],
            "opaque_intrinsic_gates": [],
        }
        path = os.path.join(self.tmp, "frontier_last.json")
        with open(path, "w") as f:
            json.dump(data, f)
        return path

    def _attested_partial_fixture(self):
        path = self._fixture(age_hours=1)
        with open(path) as f:
            data = json.load(f)
        user_probes = {
            name: {"path": path, "status": "readable"}
            for name, path in USER_PROBE_PATHS.items()
        }
        data["coverage_envelope"].update(
            fda_preflight_status="partial", fda_user_preflight_status="granted"
        )
        data["fda_preflight"] = {
            "status": "partial",
            "probes": {
                **user_probes,
                "spotlight": {"path": SYSTEM_BOUNDARY_PATHS[0], "status": "permission_denied_or_tcc", "errno": 13},
                "fseventsd": {"path": SYSTEM_BOUNDARY_PATHS[1], "status": "permission_denied_or_tcc", "errno": 13},
                "document_revisions": {"path": SYSTEM_BOUNDARY_PATHS[2], "status": "permission_denied_or_tcc", "errno": 13},
            },
        }
        data["system_boundary_attestations"] = [
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
        data["opaque_intrinsic_gates"] = [
            {
                "path": path, "reason": "permission_denied_intrinsic", "errno": 13,
                "root_device": 1, "path_device": 1,
                "verification": "parent_scanner_system_boundary_confirmation",
                "reclaimable": False,
            }
            for path in SYSTEM_BOUNDARY_PATHS
        ]
        with open(path, "w") as f:
            json.dump(data, f)
        return path

    def test_attested_partial_system_boundary_publishes_and_preserves_evidence(self):
        frontier = self._attested_partial_fixture()

        rc, _, err = run(frontier, self.out_dir)

        self.assertEqual(rc, 0, err)
        ledger_path = os.path.join(self.out_dir, "topdown-5g.json")
        self.assertTrue(os.path.exists(ledger_path))
        ledger = json.load(open(ledger_path))
        self.assertEqual(ledger["coverage_envelope"]["fda_preflight_status"], "partial")
        self.assertEqual(ledger["coverage_envelope"]["fda_user_preflight_status"], "granted")
        self.assertEqual(len(ledger["system_boundary_attestations"]), 3)
        self.assertEqual(
            {gate["path"] for gate in ledger["opaque_intrinsic_gates"]},
            set(SYSTEM_BOUNDARY_PATHS),
        )
        self.assertEqual(ledger["run_id"], "run-1")
        self.assertEqual(ledger["run_started_at"], 100.0)
        self.assertEqual(ledger["run_finished_at"], 102.0)
        self.assertEqual(ledger["fda_probe_paths"], USER_PROBE_PATHS)
        validated = subprocess.run(
            ["python3", str(REPO / "scripts" / "history_diff.py"), "--validate", ledger_path],
            capture_output=True,
            text=True,
        )
        self.assertEqual(validated.returncode, 0, validated.stderr)
        self.assertIn("valid full-attribution ledger", validated.stdout)

    def test_transplanted_attestations_from_another_run_are_not_published(self):
        frontier = self._attested_partial_fixture()
        with open(frontier) as f:
            data = json.load(f)
        for attestation in data["system_boundary_attestations"]:
            attestation["run_id"] = "run-2"
        with open(frontier, "w") as f:
            json.dump(data, f)

        rc, _, err = run(frontier, self.out_dir)

        self.assertEqual(rc, 0, err)
        self.assertFalse(os.path.exists(os.path.join(self.out_dir, "topdown-5g.json")))
        status = json.load(open(os.path.join(self.out_dir, "topdown-5g.status.json")))
        self.assertEqual(status["status"], "partial")

    def test_attestation_outside_report_run_window_is_not_published(self):
        frontier = self._attested_partial_fixture()
        with open(frontier) as f:
            data = json.load(f)
        data["system_boundary_attestations"][0]["captured_at"] = 103.0
        with open(frontier, "w") as f:
            json.dump(data, f)

        rc, _, err = run(frontier, self.out_dir)

        self.assertEqual(rc, 0, err)
        self.assertFalse(os.path.exists(os.path.join(self.out_dir, "topdown-5g.json")))

    def test_user_probe_substitution_is_not_published(self):
        cases = [
            ("single_probe_tmp", lambda d: d["fda_preflight"]["probes"]["mail"].update(path="/tmp/mail")),
            ("catalog_tmp_exact", lambda d: (
                d["fda_probe_paths"].update(mail="/tmp"),
                d["fda_preflight"]["probes"]["mail"].update(path="/tmp"),
                [a["verifier"]["fda"]["probes"]["mail"].update(path="/tmp") for a in d["system_boundary_attestations"]],
            )),
            ("catalog_tmp_mail", lambda d: (
                d["fda_probe_paths"].update(mail="/tmp/mail"),
                d["fda_preflight"]["probes"]["mail"].update(path="/tmp/mail"),
                [a["verifier"]["fda"]["probes"]["mail"].update(path="/tmp/mail") for a in d["system_boundary_attestations"]],
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
            ("catalog_var_root_home", lambda d: (
                d["fda_probe_paths"].update(
                    mobile_sync="/var/root/Library/Application Support/MobileSync/Backup",
                    mail="/var/root/Library/Mail",
                    messages="/var/root/Library/Messages",
                ),
                d["fda_preflight"]["probes"].update({
                    name: {"path": path, "status": "readable"}
                    for name, path in d["fda_probe_paths"].items()
                }),
                [a["verifier"]["fda"].update(probes={
                    name: {"path": path, "status": "readable"}
                    for name, path in d["fda_probe_paths"].items()
                }) for a in d["system_boundary_attestations"]],
            )),
            ("catalog_var_empty_home", lambda d: (
                d["fda_probe_paths"].update(
                    mobile_sync="/var/empty/Library/Application Support/MobileSync/Backup",
                    mail="/var/empty/Library/Mail",
                    messages="/var/empty/Library/Messages",
                ),
                d["fda_preflight"]["probes"].update({
                    name: {"path": path, "status": "readable"}
                    for name, path in d["fda_probe_paths"].items()
                }),
                [a["verifier"]["fda"].update(probes={
                    name: {"path": path, "status": "readable"}
                    for name, path in d["fda_probe_paths"].items()
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
                frontier = self._attested_partial_fixture()
                with open(frontier) as f:
                    data = json.load(f)
                mutate(data)
                with open(frontier, "w") as f:
                    json.dump(data, f)

                rc, _, err = run(frontier, self.out_dir)

                self.assertEqual(rc, 0, err)
                self.assertFalse(os.path.exists(os.path.join(self.out_dir, "topdown-5g.json")))

    def test_user_probe_catalog_rejects_symlink_alias_home(self):
        catalog = {
            name: os.path.join("/Users/link", relative)
            for name, relative in renderer.USER_PROBE_RELATIVE_PATHS.items()
        }
        with mock.patch.object(renderer.os.path, "realpath", return_value="/Users/real"):
            self.assertFalse(renderer.valid_user_probe_catalog(catalog))

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
                frontier = self._attested_partial_fixture()
                with open(frontier) as f:
                    data = json.load(f)
                mutate(data)
                with open(frontier, "w") as f:
                    json.dump(data, f)

                rc, _, err = run(frontier, self.out_dir)

                self.assertEqual(rc, 0, err)
                self.assertFalse(os.path.exists(os.path.join(self.out_dir, "topdown-5g.json")))

    def test_fresh_report_writes_json_and_md(self):
        frontier = self._fixture(age_hours=1)
        rc, out, err = run(frontier, self.out_dir)
        self.assertEqual(rc, 0, err)
        j = json.load(open(os.path.join(self.out_dir, "topdown-5g.json")))
        self.assertEqual(j["schema_version"], 2)
        self.assertEqual(j["residual_kb"], 524288)
        self.assertEqual(len(j["granularity_buckets"]), 2)
        md = open(os.path.join(self.out_dir, "topdown-5g.md")).read()
        self.assertIn("residual (unattributed)", md)
        self.assertIn("3.0", md)
        self.assertIn("1.0", md)
        self.assertIn("0.5", md)
        status = json.load(open(os.path.join(self.out_dir, "topdown-5g.status.json")))
        self.assertEqual(status["status"], "published")

    def test_exact_5g_bucket_publishes_and_history_accepts_it(self):
        frontier = self._fixture(age_hours=1)
        with open(frontier) as f:
            data = json.load(f)
        data["granularity_buckets"][0]["measured_kb"] = 5 * 1024 * 1024
        data["accounting_equation"].update(
            displayed_buckets_kb=6 * 1024 * 1024,
            sub_granularity_tail_kb=517471232,
        )
        with open(frontier, "w") as f:
            json.dump(data, f)

        rc, out, err = run(frontier, self.out_dir)

        self.assertEqual(rc, 0, err)
        ledger = os.path.join(self.out_dir, "topdown-5g.json")
        self.assertTrue(os.path.exists(ledger))
        validated = subprocess.run(
            ["python3", str(REPO / "scripts" / "history_diff.py"), "--validate", ledger],
            capture_output=True,
            text=True,
        )
        self.assertEqual(validated.returncode, 0, validated.stderr)
        self.assertIn("valid full-attribution ledger", validated.stdout)

    def test_opaque_intrinsic_gate_is_published_without_a_size(self):
        frontier = self._fixture(age_hours=1)
        with open(frontier) as f:
            data = json.load(f)
        gate = {
            "path": "/private/var/db/protected",
            "reason": "permission_denied_intrinsic",
            "errno": 1,
            "verification": "root-owned persistent state",
            "reclaimable": False,
        }
        data["opaque_intrinsic_gates"] = [gate]
        with open(frontier, "w") as f:
            json.dump(data, f)

        rc, _, err = run(frontier, self.out_dir)

        self.assertEqual(rc, 0, err)
        ledger = json.load(open(os.path.join(self.out_dir, "topdown-5g.json")))
        self.assertEqual(ledger["opaque_intrinsic_gates"], [gate])

    def test_opaque_intrinsic_gate_with_size_is_rejected(self):
        frontier = self._fixture(age_hours=1)
        with open(frontier) as f:
            data = json.load(f)
        data["opaque_intrinsic_gates"] = [{
            "path": "/private/var/db/protected",
            "reason": "permission_denied_intrinsic",
            "verification": "root-owned persistent state",
            "reclaimable": False,
            "measured_kb": 123,
        }]
        with open(frontier, "w") as f:
            json.dump(data, f)

        rc, _, err = run(frontier, self.out_dir)

        self.assertEqual(rc, 0, err)
        self.assertFalse(os.path.exists(os.path.join(self.out_dir, "topdown-5g.json")))

    def test_negative_clone_adjustment_is_preserved_in_display_equation(self):
        frontier = self._fixture(age_hours=1)
        with open(frontier) as f:
            data = json.load(f)
        adjustment = -1 * 1024 * 1024
        data["accounting_equation"]["clone_shared_adjustment_kb"] = adjustment
        data["accounting_equation"]["sub_granularity_tail_kb"] += -adjustment
        with open(frontier, "w") as f:
            json.dump(data, f)

        rc, _, err = run(frontier, self.out_dir)

        self.assertEqual(rc, 0, err)
        ledger = json.load(open(os.path.join(self.out_dir, "topdown-5g.json")))
        self.assertEqual(
            ledger["accounting_equation"]["clone_shared_adjustment_kb"], adjustment
        )

    def test_publisher_requires_every_full_attribution_evidence_gate(self):
        mutations = {
            "mode": lambda d: d.update(mode="partial"),
            "envelope_complete": lambda d: d["coverage_envelope"].update(complete=False),
            "fda": lambda d: d["coverage_envelope"].update(fda_preflight_status="denied"),
            "root_count": lambda d: d["coverage_envelope"].update(measured_top_level_roots=0),
            "unfinished_root": lambda d: d["coverage_envelope"].update(unfinished_top_level_roots=1),
            "frontier": lambda d: d.update(frontier_unfinished=[{"path": "/blocked"}]),
            "equation": lambda d: d["accounting_equation"].update(displayed_balanced=False),
            "forged_equation": lambda d: d["accounting_equation"].update(displayed_buckets_kb=1),
            "oversize_directory_bucket": lambda d: (
                d["granularity_buckets"][0].update(measured_kb=6 * 1024 * 1024),
                d.update(disk_used_kb=7 * 1024 * 1024, residual_kb=0, purgeable_kb=0),
                d["accounting_equation"].update(
                    data_used_kb=7 * 1024 * 1024,
                    displayed_buckets_kb=7 * 1024 * 1024,
                    sub_granularity_tail_kb=0,
                    purgeable_kb=0,
                    residual_kb=0,
                ),
            ),
        }
        for label, mutate in mutations.items():
            with self.subTest(label=label):
                frontier = self._fixture(age_hours=1)
                data = json.load(open(frontier))
                mutate(data)
                with open(frontier, "w") as f:
                    json.dump(data, f)
                rc, out, err = run(frontier, self.out_dir)
                self.assertEqual(rc, 0, err)
                self.assertFalse(os.path.exists(os.path.join(self.out_dir, "topdown-5g.json")))
                status = json.load(open(os.path.join(self.out_dir, "topdown-5g.status.json")))
                self.assertEqual(status["status"], "partial")

    def test_partial_envelope_preserves_published_table_and_records_status(self):
        frontier = self._fixture(age_hours=1, mode="partial", envelope_complete=False)
        os.makedirs(self.out_dir)
        sentinel_json = os.path.join(self.out_dir, "topdown-5g.json")
        sentinel_md = os.path.join(self.out_dir, "topdown-5g.md")
        with open(sentinel_json, "w") as f:
            f.write('{"published": true}\n')
        with open(sentinel_md, "w") as f:
            f.write("previous table\n")

        rc, out, err = run(frontier, self.out_dir)

        self.assertEqual(rc, 0, err)
        self.assertEqual(open(sentinel_json).read(), '{"published": true}\n')
        self.assertEqual(open(sentinel_md).read(), "previous table\n")
        status = json.load(open(os.path.join(self.out_dir, "topdown-5g.status.json")))
        self.assertEqual(status["status"], "partial")
        self.assertEqual(status["reason"], "coverage_incomplete")

    def test_complete_mode_without_complete_envelope_is_rejected(self):
        frontier = self._fixture(age_hours=1, mode="complete", envelope_complete=False)
        os.makedirs(self.out_dir)
        sentinel = os.path.join(self.out_dir, "topdown-5g.json")
        with open(sentinel, "w") as f:
            f.write('{"published": true}\n')

        rc, out, err = run(frontier, self.out_dir)

        self.assertEqual(rc, 0, err)
        self.assertEqual(open(sentinel).read(), '{"published": true}\n')
        status = json.load(open(os.path.join(self.out_dir, "topdown-5g.status.json")))
        self.assertEqual(status["status"], "partial")

    def test_stale_report_leaves_ledger_untouched(self):
        frontier = self._fixture(age_hours=40)
        os.makedirs(self.out_dir)
        sentinel = os.path.join(self.out_dir, "topdown-5g.json")
        with open(sentinel, "w") as f:
            f.write('{"prior": true}')
        rc, out, err = run(frontier, self.out_dir)
        self.assertEqual(rc, 0, err)
        self.assertEqual(json.load(open(sentinel)), {"prior": True})
        status = json.load(open(os.path.join(self.out_dir, "topdown-5g.status.json")))
        self.assertEqual(status["status"], "stale")

    def test_missing_report_is_a_noop(self):
        rc, out, err = run(os.path.join(self.tmp, "nope.json"), self.out_dir)
        self.assertEqual(rc, 0, err)
        self.assertFalse(os.path.isdir(self.out_dir))

if __name__ == "__main__":
    unittest.main()
