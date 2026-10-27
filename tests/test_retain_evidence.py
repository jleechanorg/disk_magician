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

    def test_compacts_oversize_frontier_measured_entries(self):
        frontier = os.path.join(self.tmp, "frontier_last.json")
        with open(frontier, "w") as f:
            f.write('{"captured_at": "now", "measured": {"/tiny": 4, "/small": 32, "/big": 128}}')
        os.utime(frontier, (3000, 3000))
        env = dict(os.environ, DISK_MAGICIAN_EVIDENCE_MAX_BYTES="10")
        r = subprocess.run(
            ["python3", str(SCRIPT), "--frontier", str(frontier),
             "--evidence-dir", str(self.evidence_dir), "--keep", "4"],
            capture_output=True, text=True, env=env,
        )
        self.assertEqual(r.returncode, 0, r.stderr)
        remaining = glob.glob(os.path.join(self.evidence_dir, "frontier-*.json"))
        self.assertEqual(len(remaining), 1)
        self.assertEqual(os.path.getmtime(remaining[0]), 3000.0)
        import json
        saved = json.load(open(remaining[0]))
        self.assertEqual(saved["measured"], {"/big": 128})

if __name__ == "__main__":
    unittest.main()
