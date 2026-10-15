#!/usr/bin/env python3
"""Producer-to-reader proof for parked accounting (plan Task 14, spec 7.3).

The producer is the canonical lease writer the reaper already owns
(`scripts/lib/worktree_lease.sh`: `lease_set_verdict`). The reader is
`budget_history.measure_parked`. Every fixture is created in an isolated
HOME/state under /tmp; nothing here touches a live reaper or live state.
"""
import datetime
import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
import budget_history as bh  # noqa: E402

GIB = 1 << 30
LEASE_LIB = ROOT / "scripts" / "lib" / "worktree_lease.sh"


def iso(ts):
    return datetime.datetime.fromtimestamp(ts, datetime.timezone.utc).isoformat()


def write_verdict(state, name, target, verdict, checked=None, extra=None):
    checked = time.time() if checked is None else checked
    """Use the canonical writer, not a hand-rolled lease mutation."""
    state = Path(state)
    (state / "worktree_leases").mkdir(parents=True, exist_ok=True)
    lease = state / "worktree_leases" / f"{name}.json"
    row = {"path": str(target), "owner": None, "created_epoch": int(checked) - 7200,
           "last_checked_at": iso(checked), "last_verdict": "sentinel"}
    if extra:
        row.update(extra)
    lease.write_text(json.dumps(row))
    script = f'source "{LEASE_LIB}"; lease_set_verdict "$1" "$2"'
    subprocess.run(["bash", "-c", script, "_", str(lease), verdict], check=True)
    return lease


class ParkedProducerReaderTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory(prefix="parked-proof.")
        self.state = Path(self._tmp.name) / "state"
        self.state.mkdir(parents=True)
        self.home = Path(self._tmp.name) / "home"
        self.home.mkdir()
        self._old_home = os.environ.get("HOME")
        os.environ["HOME"] = str(self.home)

    def tearDown(self):
        if self._old_home is None:
            os.environ.pop("HOME", None)
        else:
            os.environ["HOME"] = self._old_home
        self._tmp.cleanup()

    def _target(self, name):
        target = Path(self._tmp.name) / name
        target.mkdir()
        (target / "blob").write_bytes(b"x")
        return target

    def _terminal(self, at=None):
        return dict(outcome="success", times=dict(ended_at=iso(time.time() if at is None else at)))

    def _fake_du(self, kb=1024):
        def run(cmd, cap=None, deadline=None):
            paths = list(cmd[2:])
            return 0, "".join(f"{kb}\t{p}\n" for p in paths)
        return run

    def measure(self, **kwargs):
        with patch("job_receipt.get_last_receipt", return_value=self._terminal()):
            with patch.object(bh, "_run_bounded", side_effect=kwargs.pop("du", self._fake_du())):
                return bh.measure_parked(self.state, now=time.time(), **kwargs)

    def test_owner_null_and_unproven_content_are_both_parked(self):
        write_verdict(self.state, "owner-null", self._target("null"), "kept:owner-null")
        write_verdict(self.state, "unproven", self._target("unproven"), "kept:unproven-content")
        captured = {}

        def run(cmd, cap=None, deadline=None):
            captured["paths"] = list(cmd[2:])
            return 0, "".join("1024\t%s\n" % p for p in captured["paths"])

        result = self.measure(du=run)
        self.assertEqual(result["status"], "ok")
        self.assertEqual(result["paths"], 2)
        self.assertEqual(len(captured["paths"]), 2)

    def test_reader_counts_all_kept_reasons_not_only_expired_owner_alive(self):
        write_verdict(self.state, "owner-null", self._target("null"), "kept:owner-null")
        write_verdict(self.state, "unproven", self._target("unproven"), "kept:unproven-content")
        write_verdict(self.state, "expired", self._target("expired"), "kept:expired_owner_alive")
        result = self.measure()
        self.assertEqual(result["status"], "ok")
        self.assertEqual(result["paths"], 3)
        self.assertEqual(result["bytes"], 3 * 1024 * 1024)

    def test_released_but_still_kept_is_counted(self):
        target = self._target("released")
        write_verdict(self.state, "released", target, "kept:not-pushed",
                      extra={"released_at": iso(time.time() - 3600)})
        result = self.measure()
        self.assertEqual(result["status"], "ok")
        self.assertEqual(result["bytes"], 1024 * 1024)

    def test_gone_path_is_excluded(self):
        target = self._target("gone")
        write_verdict(self.state, "gone", target, "kept:owner-null")
        os.rename(target, Path(self._tmp.name) / "moved")
        result = self.measure()
        self.assertEqual((result["status"], result["bytes"]), ("ok", 0))

    def test_malformed_lease_is_not_reported_as_zero(self):
        (self.state / "worktree_leases").mkdir()
        (self.state / "worktree_leases" / "broken.json").write_text("{not json")
        result = self.measure()
        self.assertEqual(result["status"], "incomplete")
        self.assertIsNone(result["bytes"])

    def test_stale_lease_is_not_reported_as_zero(self):
        target = self._target("stale")
        write_verdict(self.state, "stale", target, "kept:owner-null")
        stale = self.state / "worktree_leases" / "stale.json"
        row = json.loads(stale.read_text())
        row["last_checked_at"] = iso(time.time() - 3 * 86400)
        stale.write_text(json.dumps(row))
        result = self.measure()
        self.assertEqual(result["status"], "incomplete")
        self.assertIsNone(result["bytes"])

    def test_duplicate_realpaths_are_measured_once(self):
        target = self._target("dup")
        write_verdict(self.state, "one", target, "kept:owner-null")
        write_verdict(self.state, "two", target, "kept:unproven-content")
        captured = {}

        def run(cmd, cap=None, deadline=None):
            captured["paths"] = list(cmd[2:])
            return 0, "".join("2048\t%s\n" % p for p in captured["paths"])

        result = self.measure(du=run)
        self.assertEqual(result["paths"], 1)
        self.assertEqual(len(captured["paths"]), 1)
        self.assertEqual(result["bytes"], 2048 * 1024)

    def test_parked_jsonl_is_materialized_from_the_same_records(self):
        write_verdict(self.state, "listed", self._target("listed"), "kept:unproven-content")
        result = self.measure(du=self._fake_du(kb=512))
        self.assertEqual(result["status"], "ok")
        rows = [json.loads(line) for line in
                (self.state / "parked.jsonl").read_text().splitlines() if line.strip()]
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["reason"], "kept:unproven-content")
        self.assertEqual(rows[0]["bytes"], 512 * 1024)
        self.assertEqual(rows[0]["source"], bh.PARKED_SOURCE)

    def test_live_owner_reason_is_recorded_but_not_parked_bytes(self):
        write_verdict(self.state, "live", self._target("live"), "kept:live-owner")
        result = self.measure()
        self.assertEqual((result["status"], result["bytes"], result["paths"]), ("ok", 0, 0))

    def test_stale_receipt_leaves_status_unknown(self):
        write_verdict(self.state, "old", self._target("old"), "kept:owner-null")
        with patch("job_receipt.get_last_receipt",
                   return_value=self._terminal(at=time.time() - 2 * 86400)):
            result = bh.measure_parked(self.state, now=time.time())
        self.assertEqual(result["status"], "unknown")
        self.assertIsNone(result["bytes"])

    def test_du_failure_is_not_reported_as_zero(self):
        write_verdict(self.state, "fail", self._target("fail"), "kept:owner-null")
        with patch("job_receipt.get_last_receipt", return_value=self._terminal()), \
                patch.object(bh, "_run_bounded", return_value=(1, "")):
            result = bh.measure_parked(self.state, now=time.time())
        self.assertEqual(result["status"], "unknown")
        self.assertIsNone(result["bytes"])


if __name__ == "__main__":
    unittest.main()
