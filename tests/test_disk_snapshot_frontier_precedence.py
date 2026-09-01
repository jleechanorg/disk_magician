import datetime
import json
import os
import shutil
import tempfile
import unittest


def rank_frontier_candidates(enabled, explicit_override_path, root_path, user_path):
    candidates = [p for p in [explicit_override_path, root_path, user_path] if p]
    if enabled != "true" or not candidates:
        return None

    explicit_override = bool(explicit_override_path)
    loaded = []

    for idx, path in enumerate(candidates):
        if not os.path.isfile(path) or not os.access(path, os.R_OK):
            if explicit_override and idx == 0:
                break
            continue
        try:
            with open(path) as f:
                d = json.load(f)
            captured_at = d["captured_at"]
            ts = datetime.datetime.strptime(captured_at, "%Y-%m-%dT%H:%M:%SZ").replace(
                tzinfo=datetime.timezone.utc
            )
            age_hours = (
                datetime.datetime.now(datetime.timezone.utc) - ts
            ).total_seconds() / 3600.0
            is_complete = d.get("mode") == "complete" or bool(
                d.get("coverage_envelope", {}).get("complete")
            )
            is_fresh = age_hours <= 36.0
            loaded.append(
                {
                    "path": path,
                    "data": d,
                    "captured_at": captured_at,
                    "age_hours": age_hours,
                    "is_complete": is_complete,
                    "is_fresh": is_fresh,
                    "ts": ts,
                }
            )
            if explicit_override and idx == 0:
                break
        except Exception:
            continue

    if not loaded:
        return None

    def score(c):
        return (
            1 if c["is_fresh"] and c["is_complete"] else 0,
            1 if c["is_fresh"] else 0,
            c["ts"].timestamp(),
        )

    best = max(loaded, key=score)
    if not best["is_fresh"]:
        return {
            "stale": True,
            "captured_at": best["captured_at"],
            "age_hours": round(best["age_hours"], 1),
            "source_path": best["path"],
        }
    d = best["data"]
    return {
        "mode": d.get("mode"),
        "captured_at": best["captured_at"],
        "age_hours": round(best["age_hours"], 1),
        "source_path": best["path"],
        "measured_total_kb": d.get("measured_total_kb"),
        "frontier_unfinished_count": len(d.get("frontier_unfinished") or []),
        "residual_kb": d.get("residual_kb"),
        "sibling_volumes_count": len(d.get("sibling_volumes") or {}),
        "local_snapshots_count": d.get("local_snapshots_count"),
    }


class TestFrontierCandidateRanking(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def _write_json(self, name, data):
        path = os.path.join(self.tmp, name)
        with open(path, "w") as f:
            json.dump(data, f)
        return path

    def test_complete_user_scan_beats_newer_partial_root_scan(self):
        now = datetime.datetime.now(datetime.timezone.utc)
        user_ts = (now - datetime.timedelta(hours=2)).strftime("%Y-%m-%dT%H:%M:%SZ")
        root_ts = (now - datetime.timedelta(minutes=30)).strftime("%Y-%m-%dT%H:%M:%SZ")

        user_file = self._write_json(
            "user.json",
            {
                "captured_at": user_ts,
                "mode": "complete",
                "coverage_envelope": {"complete": True},
                "measured_total_kb": 1000,
            },
        )
        root_file = self._write_json(
            "root.json",
            {
                "captured_at": root_ts,
                "mode": "partial",
                "coverage_envelope": {"complete": False},
                "measured_total_kb": 800,
            },
        )

        res = rank_frontier_candidates("true", "", root_file, user_file)
        self.assertIsNotNone(res)
        self.assertEqual(res["source_path"], user_file)
        self.assertEqual(res["mode"], "complete")

    def test_complete_root_scan_beats_older_complete_user_scan(self):
        now = datetime.datetime.now(datetime.timezone.utc)
        user_ts = (now - datetime.timedelta(hours=5)).strftime("%Y-%m-%dT%H:%M:%SZ")
        root_ts = (now - datetime.timedelta(hours=1)).strftime("%Y-%m-%dT%H:%M:%SZ")

        user_file = self._write_json(
            "user.json",
            {
                "captured_at": user_ts,
                "mode": "complete",
                "coverage_envelope": {"complete": True},
                "measured_total_kb": 1000,
            },
        )
        root_file = self._write_json(
            "root.json",
            {
                "captured_at": root_ts,
                "mode": "complete",
                "coverage_envelope": {"complete": True},
                "measured_total_kb": 1200,
            },
        )

        res = rank_frontier_candidates("true", "", root_file, user_file)
        self.assertIsNotNone(res)
        self.assertEqual(res["source_path"], root_file)
        self.assertEqual(res["measured_total_kb"], 1200)

    def test_explicit_override_is_used_strictly_without_fallback(self):
        now = datetime.datetime.now(datetime.timezone.utc)
        override_ts = (now - datetime.timedelta(hours=1)).strftime("%Y-%m-%dT%H:%M:%SZ")
        root_ts = (now - datetime.timedelta(minutes=10)).strftime("%Y-%m-%dT%H:%M:%SZ")

        override_file = self._write_json(
            "override.json",
            {
                "captured_at": override_ts,
                "mode": "complete",
                "coverage_envelope": {"complete": True},
                "measured_total_kb": 9999,
            },
        )
        root_file = self._write_json(
            "root.json",
            {
                "captured_at": root_ts,
                "mode": "complete",
                "coverage_envelope": {"complete": True},
                "measured_total_kb": 1200,
            },
        )

        res = rank_frontier_candidates("true", override_file, root_file, "")
        self.assertIsNotNone(res)
        self.assertEqual(res["source_path"], override_file)
        self.assertEqual(res["measured_total_kb"], 9999)


if __name__ == "__main__":
    unittest.main()
