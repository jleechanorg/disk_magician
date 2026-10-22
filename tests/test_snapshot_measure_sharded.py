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
                               deadline=time.time() + 60, prior={"slow": {"kb": 5000, "ts": time.time() - 60}})
        self.assertTrue(r["partial"])
        self.assertEqual(r["stale_shards"], {"slow": 5000})
        self.assertTrue(r["lower_bound"])
        # the last-good value is part of the root's value (flagged stale), so the sum never collapses to the fresh shards
        self.assertEqual(r["kb"], 100 + 5000 + int(os.stat(self.root).st_blocks * 512 // 1024))
        self.assertEqual(r["fresh_kb"], 100 + int(os.stat(self.root).st_blocks * 512 // 1024))

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
        state.write_text(json.dumps({"roots": {"big": {"timed_out": False, "shards": {"slow": {"kb": 7000, "ts": time.time() - 60}}}}}))
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
        self.assertEqual({k: v["kb"] for k, v in saved["shards"].items()}, {"fast": 100, "slow": 7000})
        self.assertIn("big", diag["lower_bound_keys"])
        self.assertIn("big", diag["partial_keys"])
        meta = diag["sharded_roots"]["big"]
        self.assertEqual((meta["shards_total"], meta["shards_fresh"], meta["shards_stale"], meta["partial"]), (2, 1, 1, True))

    def test_stale_carry_expires_after_max_age(self):
        make_tree(self.root, ["fast1", "slow"])
        self.use_stub_du()
        os.environ.update(FAKE_DU_SLOW_NAME="slow", FAKE_DU_SLOW_SLEEP="30")
        old = time.time() - 49 * 3600
        r = sm.measure_sharded(str(self.root), workers=2, shard_timeout=1, deadline=time.time() + 60,
                               prior={"slow": {"kb": 5000, "ts": old}}, carry_max_s=48 * 3600)
        self.assertEqual(r["stale_shards"], {})
        self.assertEqual(r["expired_shards"], ["slow"])
        self.assertIsNone(r["carry"]["slow"]["kb"])  # expired value dropped; only the attempt record stays
        self.assertTrue(r["partial"] and r["lower_bound"])

    def test_legacy_untimestamped_carry_is_expired(self):
        make_tree(self.root, ["fast1", "slow"])
        self.use_stub_du()
        os.environ.update(FAKE_DU_SLOW_NAME="slow", FAKE_DU_SLOW_SLEEP="30")
        r = sm.measure_sharded(str(self.root), workers=2, shard_timeout=1, deadline=time.time() + 60,
                               prior={"slow": 5000})
        self.assertEqual((r["stale_shards"], r["expired_shards"]), ({}, ["slow"]))

    def test_permission_errors_are_lower_bound_not_carried_complete(self):
        make_tree(self.root, ["ok", "denied"])
        (self.bin / "du").write_text(
            "#!/usr/bin/env bash\n"
            "for a in \"$@\"; do [[ \"$a\" == -* ]] && continue\n"
            "  if [[ \"$a\" == */denied ]]; then echo \"du: $a/x: Permission denied\" >&2; rc=1; fi\n"
            "  printf '100\\t%s\\n' \"$a\"; done\n"
            "exit ${rc:-0}\n")
        (self.bin / "du").chmod(0o755)
        os.environ["PATH"] = f"{self.bin}:{self.old_path}"
        r = sm.measure_sharded(str(self.root), workers=2, shard_timeout=10, deadline=time.time() + 60, prior={})
        self.assertEqual(r["lower_bound_shards"], ["denied"])
        self.assertTrue(r["partial"] and r["lower_bound"])
        self.assertIsNone(r["carry"]["denied"]["kb"])  # partial result never persisted as a complete measurement
        self.assertEqual(r["carry"]["ok"]["kb"], 100)
        self.assertEqual(r["kb"], 200 + int(os.stat(self.root).st_blocks * 512 // 1024))



class IncrementalShardTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name) / "bigroot"
        self.root.mkdir()
        self.bin = Path(self.tmp.name) / "bin"
        self.bin.mkdir()
        stub = self.bin / "du"
        stub.write_text(STUB_DU)
        stub.chmod(stub.stat().st_mode | stat.S_IEXEC)
        self.old_path = os.environ["PATH"]
        os.environ["PATH"] = f"{self.bin}:{self.old_path}"
        self.addCleanup(lambda: os.environ.update(PATH=self.old_path))
        for k in ("FAKE_DU_SLEEP", "FAKE_DU_SLOW_NAME", "FAKE_DU_SLOW_SLEEP"):
            self.addCleanup(os.environ.pop, k, None)

    def own(self, *dirs):
        return sum(int(os.stat(d).st_blocks * 512 // 1024) for d in (self.root, *dirs))

    def test_rotation_refreshes_every_shard_within_n_runs(self):
        make_tree(self.root, ["a", "b", "c", "d", "e", "f"])
        prior, t = {}, time.time()
        seen = []
        for run in range(3):
            r = sm.measure_sharded(str(self.root), workers=2, shard_timeout=5, deadline=t + 600, prior=prior,
                                   now=t + run * 60, max_per_run=2)
            prior = r["carry"]
            seen.append(sorted(r["fresh_shards"]))
            if run == 0:  # four shards have never been measured: partial, 2 of 6 fresh, not a full value
                self.assertTrue(r["partial"])
                self.assertEqual((r["shards_fresh"], r["shards_missing"], r["fresh_fraction"]), (2, 4, 0.333))
                self.assertEqual(r["kb"], self.own() + 200)
        self.assertEqual(sorted(sum(seen, [])), ["a", "b", "c", "d", "e", "f"])  # disjoint, each exactly once
        self.assertFalse(r["partial"])
        self.assertEqual(r["kb"], self.own() + 600)  # sum of per-shard latest values
        self.assertEqual((r["shards_fresh"], r["shards_carried"], r["runs_to_full_refresh"]), (2, 4, 3))
        self.assertAlmostEqual(r["max_shard_age_hours"], 2 / 60, places=1)

    def test_timed_out_shard_goes_to_back_of_queue_and_retries_longer(self):
        make_tree(self.root, ["a", "slow", "z"])
        os.environ.update(FAKE_DU_SLOW_NAME="slow", FAKE_DU_SLOW_SLEEP="30")
        t = time.time()
        r1 = sm.measure_sharded(str(self.root), workers=1, shard_timeout=1, deadline=t + 600, prior={}, now=t, max_per_run=1)
        r2 = sm.measure_sharded(str(self.root), workers=1, shard_timeout=1, deadline=t + 600, prior=r1["carry"],
                                now=t + 60, max_per_run=1)
        r3 = sm.measure_sharded(str(self.root), workers=1, shard_timeout=1, deadline=t + 600, prior=r2["carry"],
                                now=t + 120, max_per_run=1)
        self.assertEqual([sorted(r["fresh_shards"]) for r in (r1, r2, r3)], [["a"], [], ["z"]])
        self.assertEqual(r2["timed_out_shards"], ["slow"])  # attempted second (a was just measured), starved nobody

    def test_twice_timed_out_dir_is_split_into_children(self):
        make_tree(self.root, ["ok"])
        (self.root / "rep").mkdir()
        make_tree(self.root / "rep", ["x", "y"])
        os.environ.update(FAKE_DU_SLOW_NAME="rep", FAKE_DU_SLOW_SLEEP="30")
        t = time.time()
        prior = {}
        for run in range(2):
            r = sm.measure_sharded(str(self.root), workers=1, shard_timeout=1, deadline=t + 600, prior=prior, now=t + run)
            prior = r["carry"]
        self.assertEqual(r["split"], ["rep"])
        self.assertIn("rep", r["timed_out_shards"])
        r = sm.measure_sharded(str(self.root), workers=2, shard_timeout=1, deadline=t + 600, prior=prior, now=t + 2,
                               split=["rep"])
        self.assertEqual(sorted(r["fresh_shards"]), ["ok", "rep/x", "rep/y"])
        self.assertEqual(r["kb"], self.own(self.root / "rep") + 300)  # ok + rep/x + rep/y
        self.assertFalse(r["partial"])

    def test_split_dir_keeps_old_value_until_children_measured(self):
        (self.root / "rep").mkdir()
        make_tree(self.root / "rep", ["x", "y"])
        t = time.time()
        prior = {"rep": {"kb": 5000, "ts": t - 60, "at": t - 60, "fails": 0}}
        r = sm.measure_sharded(str(self.root), workers=1, shard_timeout=5, deadline=t + 600, prior=prior, now=t,
                               max_per_run=1, split=["rep"])
        self.assertTrue(r["partial"])
        self.assertEqual(r["kb"], self.own(self.root / "rep") + 5000)  # umbrella: max(old value, children present)
        self.assertIn("rep", r["carry"])

    def test_orchestrate_shard_flag_runs_sharded_without_carry_size(self):
        make_tree(self.root, ["a", "b"])
        entries = [{"key": "r", "path": str(self.root), "timeout": 30, "retry_timeout": 0, "shard": True}]
        diag = {}
        res = sm.orchestrate(entries, "/nonexistent/disk_snapshot.sh", 1, time.time() + 60, str(Path(self.tmp.name) / "o"),
                             {}, diagnostics_out=diag, shard_state_path=str(Path(self.tmp.name) / "s.json"),
                             shard_timeout=5, shard_workers=2)
        self.assertEqual(res["r"], self.own() + 200)
        self.assertEqual(diag["sharded_roots"]["r"]["shards_total"], 2)
        saved = json.loads((Path(self.tmp.name) / "s.json").read_text())["roots"]["r"]
        self.assertIn("run_ts", saved)

    def test_diskm_measure_only_updates_carry_and_shard_state(self):
        make_tree(self.root, ["a", "b"])
        cfg = Path(self.tmp.name) / "config.json"
        cfg.write_text(json.dumps({"monitored_dirs": [{"key": "r", "path": str(self.root), "timeout": 5}]}))
        state = Path(self.tmp.name) / "state"
        env = dict(os.environ, DISK_MAGICIAN_CONFIG=str(cfg), DISK_MAGICIAN_STATE_DIR=str(state))
        out = subprocess.run([sys.executable, str(ROOT / "scripts" / "snapshot_measure.py"), "--only", "r", "--timeout", "30"],
                             env=env, capture_output=True, text=True, timeout=60)
        self.assertEqual(out.returncode, 0, out.stderr)
        row = json.loads(out.stdout)[0]
        self.assertEqual((row["key"], row["kb"], row["lower_bound"]), ("r", self.own() + 200, False))
        self.assertEqual(row["sharded"]["shards_total"], 2)
        self.assertEqual(json.loads((state / "last_good_measurements.json").read_text())["r"]["kb"], row["kb"])
        self.assertIn("r", json.loads((state / "shard_last_good.json").read_text())["roots"])
        bad = subprocess.run([sys.executable, str(ROOT / "scripts" / "snapshot_measure.py"), "--only", "nope"],
                             env=env, capture_output=True, text=True, timeout=60)
        self.assertEqual(bad.returncode, 2)


if __name__ == "__main__":
    unittest.main()
