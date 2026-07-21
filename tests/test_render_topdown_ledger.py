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
