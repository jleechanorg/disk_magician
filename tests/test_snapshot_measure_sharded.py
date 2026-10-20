"""Sharded parallel measurement of big roots (bead disk_magician-snapshot-coverage-below-gate-0c4f)."""
import json
import os
import stat
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
import snapshot_measure as sm  # noqa: E402

STUB_DU = """#!/usr/bin/env bash
# stub du: sleeps FAKE_DU_SLEEP per call (or FAKE_DU_SLOW_SLEEP when an arg ends in FAKE_DU_SLOW_NAME)
s="${FAKE_DU_SLEEP:-0}"
for a in "$@"; do [[ -n "${FAKE_DU_SLOW_NAME:-}" && "$a" == *"/$FAKE_DU_SLOW_NAME" ]] && s="${FAKE_DU_SLOW_SLEEP:-30}"; done
sleep "$s"
for a in "$@"; do [[ "$a" == -* ]] || printf '100\\t%s\\n' "$a"; done
"""


def make_tree(base, names, files=3):
    for n in names:
        d = Path(base) / n
        d.mkdir()
        for i in range(files):
            (d / f"f{i}").write_bytes(b"x" * 100_000)


class WorkerClampTests(unittest.TestCase):
    def test_default_four_clamped_to_half_cores(self):
        self.assertEqual(sm.shard_worker_count(16, 1.0, 1), 4)
        self.assertEqual(sm.shard_worker_count(4, 1.0, 1), 2)
        self.assertEqual(sm.shard_worker_count(1, 0.1, 1), 1)

    def test_requested_never_exceeds_half_cores(self):
        self.assertEqual(sm.shard_worker_count(8, 1.0, 1, requested=16), 4)
        self.assertEqual(sm.shard_worker_count(8, 1.0, 1, requested=2), 2)

    def test_pressure_or_load_falls_back_to_one(self):
        self.assertEqual(sm.shard_worker_count(16, 1.0, 3), 1)
        self.assertEqual(sm.shard_worker_count(16, 1.0, 4), 1)
        self.assertEqual(sm.shard_worker_count(8, 33.0, 1), 1)   # > 4x cores
        self.assertEqual(sm.shard_worker_count(8, 31.0, 1), 4)   # <= 4x cores


class ShardedMeasureTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name) / "bigroot"
        self.root.mkdir()
        self.bin = Path(self.tmp.name) / "bin"
        self.bin.mkdir()
        self.old_path = os.environ["PATH"]
        self.addCleanup(lambda: os.environ.update(PATH=self.old_path))
        for k in ("FAKE_DU_SLEEP", "FAKE_DU_SLOW_NAME", "FAKE_DU_SLOW_SLEEP"):
            self.addCleanup(os.environ.pop, k, None)

    def use_stub_du(self):
        stub = self.bin / "du"
        stub.write_text(STUB_DU)
        stub.chmod(stub.stat().st_mode | stat.S_IEXEC)
        os.environ["PATH"] = f"{self.bin}:{self.old_path}"

    def test_shard_sum_equals_single_measure(self):
        make_tree(self.root, ["a", "b", "c", ".hidden"])
        (self.root / "loose.bin").write_bytes(b"y" * 50_000)
        single = int(subprocess.check_output(["du", "-sk", str(self.root)]).split()[0])
        r = sm.measure_sharded(str(self.root), workers=3, shard_timeout=20,
                               deadline=time.time() + 60, prior={})
        self.assertEqual(r["kb"], single)
        self.assertFalse(r["partial"])
        self.assertEqual(r["timed_out_shards"], [])

    def test_slow_shard_marks_partial_and_others_count(self):
        make_tree(self.root, ["fast1", "fast2", "slow"])
        self.use_stub_du()
        os.environ.update(FAKE_DU_SLOW_NAME="slow", FAKE_DU_SLOW_SLEEP="30")
        t0 = time.time()
        r = sm.measure_sharded(str(self.root), workers=3, shard_timeout=1,
                               deadline=time.time() + 60, prior={})
        self.assertLess(time.time() - t0, 10)
        self.assertTrue(r["partial"])
        self.assertEqual(r["timed_out_shards"], ["slow"])
        self.assertEqual(r["kb"], 200 + int(os.stat(self.root).st_blocks * 512 // 1024))  # 2 fast shards, no stale known
        self.assertEqual(r["stale_shards"], {})

    def test_timed_out_shard_keeps_last_good_flagged_stale(self):
        make_tree(self.root, ["fast1", "slow"])
        self.use_stub_du()
        os.environ.update(FAKE_DU_SLOW_NAME="slow", FAKE_DU_SLOW_SLEEP="30")
        r = sm.measure_sharded(str(self.root), workers=2, shard_timeout=1,
                               deadline=time.time() + 60, prior={"slow": 5000})
        self.assertTrue(r["partial"])
        self.assertEqual(r["stale_shards"], {"slow": 5000})
        self.assertEqual(r["kb"], 100 + 5000 + int(os.stat(self.root).st_blocks * 512 // 1024))

    def test_shards_run_concurrently(self):
        make_tree(self.root, ["a", "b"])
        self.use_stub_du()
        os.environ["FAKE_DU_SLEEP"] = "1"
        t0 = time.time()
        r = sm.measure_sharded(str(self.root), workers=2, shard_timeout=10,
                               deadline=time.time() + 60, prior={})
        self.assertLess(time.time() - t0, 1.9)
        self.assertFalse(r["partial"])

    def test_many_children_are_bucketed(self):
        make_tree(self.root, [f"d{i:03d}" for i in range(150)], files=1)
        shards, _ = sm.list_shards(str(self.root), max_shards=64)
        self.assertLessEqual(len(shards), 64)
        self.assertEqual(sum(len(p) for _, p in shards), 150)

    def test_orchestrate_shards_big_root_and_flags_partial(self):
        make_tree(self.root, ["fast", "slow"])
        self.use_stub_du()
        os.environ.update(FAKE_DU_SLOW_NAME="slow", FAKE_DU_SLOW_SLEEP="30")
        state = Path(self.tmp.name) / "shard_last_good.json"
        state.write_text(json.dumps({"roots": {"big": {"timed_out": False, "shards": {"slow": 7000}}}}))
        entries = [{"key": "big", "path": str(self.root), "timeout": 20, "retry_timeout": 0}]
        diag = {}
        res = sm.orchestrate(entries, "/nonexistent/disk_snapshot.sh", 2, time.time() + 60,
                             str(Path(self.tmp.name) / "out"), {"big": sm.SHARD_MIN_KB},
                             diagnostics_out=diag, shard_state_path=str(state), shard_timeout=1, shard_workers=2)
        own = int(os.stat(self.root).st_blocks * 512 // 1024)
        self.assertEqual(res["big"], own + 100 + 7000)
        part = [f for f in diag["measurement_failures"] if f["key"] == "big"][0]
        self.assertEqual((part["status"], part["timed_out_shards"], part["stale_shards"]),
                         ("partial", ["slow"], {"slow": 7000}))
        saved = json.loads(state.read_text())["roots"]["big"]
        self.assertEqual(saved["shards"], {"fast": 100, "slow": 7000})
        self.assertNotIn("big", diag["lower_bound_keys"])


if __name__ == "__main__":
    unittest.main()
