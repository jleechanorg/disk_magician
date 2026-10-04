"""Public CLI fixtures for bounded snapshot measurement diagnostics."""

import json
import os
import stat
import subprocess
import sys
import tempfile
import textwrap
import time
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
ORCH = ROOT / "scripts" / "snapshot_measure.py"
SNAP = ROOT / "scripts" / "disk_snapshot.sh"


WORKER = textwrap.dedent(
    r"""
    #!/usr/bin/env bash
    shift
    key="$1"; path="$2"; timeout_s="$3"; out="$4"
    mode="${FAKE_MODE:-backend_error}"
    case "$mode" in
      backend_error)
        printf '{"key":"%s","kb":null,"path":"%s","elapsed_s":0.25,"timed_out":false,"reason":"backend_error","backend":"du","backend_exit":13,"stderr":"permission denied"}\n' "$key" "$path" > "$out"
        ;;
      malformed)
        printf '{not-json\n' > "$out"
        ;;
      long_reason)
        python3 - "$out" <<'PY'
import json, sys
with open(sys.argv[1], "w") as output:
    json.dump({"kb": None, "reason": "worker\nfailed\r" + "x" * 1000}, output)
PY
        ;;
      missing)
        exit 0
        ;;
      deadline)
        sleep 30
        ;;
      retry)
        marker="${FAKE_DIR:?}/seen"
        if [[ ! -e "$marker" ]]; then
          touch "$marker"
          printf '{"key":"%s","kb":null,"path":"%s","elapsed_s":0.10,"timed_out":false,"reason":"backend_error","backend":"du","backend_exit":7,"stderr":"temporary scanner failure"}\n' "$key" "$path" > "$out"
        else
          printf '{"key":"%s","kb":123,"path":"%s","elapsed_s":0.20,"timed_out":false}\n' "$key" "$path" > "$out"
        fi
        ;;
    esac
    """
)


class SnapshotDiagnosticsCliTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="snapshot-diag-"))
        self.addCleanup(lambda: subprocess.run(["rm", "-rf", str(self.tmp)], check=False))
        self.worker = self.tmp / "fake_snapshot.sh"
        self.worker.write_text(WORKER)
        self.worker.chmod(self.worker.stat().st_mode | stat.S_IEXEC)
        self.cfg = self.tmp / "config.json"
        self.cfg.write_text(
            json.dumps(
                {
                    "monitored_dirs": [
                        {"key": "projects", "path": str(self.tmp / "projects"), "timeout": 5, "retry_timeout": 5}
                    ]
                }
            )
        )
        (self.tmp / "projects").mkdir()

    def run_orch(self, mode, *, deadline=20, snapshot_script=None):
        meta = self.tmp / f"meta-{mode}.json"
        env = dict(os.environ, FAKE_MODE=mode, FAKE_DIR=str(self.tmp))
        command = [
            sys.executable,
            str(ORCH),
            "--config",
            str(self.cfg),
            "--snapshot-script",
            str(snapshot_script or self.worker),
            "--workers",
            "1",
            "--deadline-epoch",
            str(int(time.time() + deadline)),
            "--tmpdir",
            str(self.tmp / f"out-{mode}"),
            "--meta-out",
            str(meta),
        ]
        result = subprocess.run(command, env=env, capture_output=True, text=True, timeout=15)
        return result, [line.split("\t") for line in result.stdout.splitlines()], json.loads(meta.read_text())

    def test_regression_snapshot_diag_backend_error_preserves_reason(self):
        result, rows, meta = self.run_orch("backend_error")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(rows[0][1], "")
        failure = meta["measurement_failures"][0]
        self.assertEqual(failure["key"], "projects")
        self.assertEqual(failure["status"], "failed")
        self.assertEqual(failure["attempts"][0]["reason"], "backend_error")
        self.assertEqual(failure["attempts"][0]["backend_exit"], 13)
        self.assertIn("permission denied", failure["attempts"][0]["stderr"])

    def test_regression_snapshot_diag_malformed_and_missing_worker_result(self):
        for mode in ("malformed", "missing"):
            with self.subTest(mode=mode):
                result, rows, meta = self.run_orch(mode)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(rows[0][1], "")
                self.assertEqual(meta["measurement_failures"][0]["status"], "failed")
                self.assertIn(meta["measurement_failures"][0]["attempts"][0]["reason"], {"malformed_result", "missing_result"})

    def test_regression_snapshot_diag_worker_reason_is_bounded_single_line(self):
        result, rows, meta = self.run_orch("long_reason")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(rows[0][1], "")
        for attempt in meta["measurement_failures"][0]["attempts"]:
            self.assertEqual(attempt["reason"], "worker failed " + "x" * 242)

    def test_regression_snapshot_diag_deadline_and_launch_failure(self):
        result, rows, meta = self.run_orch("deadline", deadline=1)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(rows[0][1], "")
        self.assertEqual(meta["measurement_failures"][0]["attempts"][0]["reason"], "orchestrator_deadline")

        result, rows, meta = self.run_orch("backend_error", snapshot_script=self.tmp / "does-not-exist.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(rows[0][1], "")
        self.assertEqual(meta["measurement_failures"][0]["attempts"][0]["reason"], "launch_failure")

    def test_regression_snapshot_diag_successful_retry_is_recovered(self):
        result, rows, meta = self.run_orch("retry")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(rows[0][1], "123")
        failure = meta["measurement_failures"][0]
        self.assertEqual(failure["status"], "recovered")
        self.assertEqual([attempt["reason"] for attempt in failure["attempts"]], ["backend_error", "success"])

    def test_regression_measure_one_rejects_partial_nonzero_du_output(self):
        bindir = self.tmp / "bin"
        bindir.mkdir()
        dua = bindir / "dua"
        dua.write_text("#!/usr/bin/env bash\necho 'dua permission denied' >&2\nexit 13\n")
        dua.chmod(0o755)
        du = bindir / "du"
        du.write_text("#!/usr/bin/env bash\nprintf '4096\\t%s\\n' \"${@: -1}\"\necho 'du permission denied' >&2\nexit 13\n")
        du.chmod(0o755)
        output = self.tmp / "worker.json"
        env = dict(
            os.environ,
            PATH=f"{bindir}:/opt/homebrew/bin:/usr/bin:/bin",
            HOME=str(self.tmp),
            DISK_MAGICIAN_LOAD_FACTOR_OVERRIDE="1",
            DISK_MAGICIAN_WORKER_DEADLINE_EPOCH=str(int(time.time() + 10)),
        )
        result = subprocess.run(
            ["bash", str(SNAP), "--measure-one", "projects", str(self.tmp / "projects"), "5", str(output)],
            env=env,
            capture_output=True,
            text=True,
            timeout=10,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        worker = json.loads(output.read_text())
        self.assertIsNone(worker["kb"])
        self.assertEqual(worker["reason"], "backend_error")
        self.assertEqual(worker["backend_exit"], 13)
        self.assertIn("permission denied", worker["stderr"])

    def test_regression_measure_one_distinguishes_backend_timeout(self):
        bindir = self.tmp / "bin-timeout"
        bindir.mkdir()
        for name in ("dua", "du"):
            executable = bindir / name
            executable.write_text("#!/usr/bin/env bash\nsleep 5\n")
            executable.chmod(0o755)
        output = self.tmp / "timeout-worker.json"
        env = dict(
            os.environ,
            PATH=f"{bindir}:/opt/homebrew/bin:/usr/bin:/bin",
            HOME=str(self.tmp),
            DISK_MAGICIAN_LOAD_FACTOR_OVERRIDE="1",
            DISK_MAGICIAN_WORKER_DEADLINE_EPOCH=str(int(time.time() + 10)),
        )
        result = subprocess.run(
            ["bash", str(SNAP), "--measure-one", "projects", str(self.tmp / "projects"), "1", str(output)],
            env=env,
            capture_output=True,
            text=True,
            timeout=10,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        worker = json.loads(output.read_text())
        self.assertIsNone(worker["kb"])
        self.assertEqual(worker["reason"], "backend_timeout")
        self.assertEqual(worker["backend_exit"], 124)

    def test_measure_one_rejects_dua_success_when_du_reports_unreadable_child(self):
        bindir = self.tmp / "bin-partial-success"
        bindir.mkdir()
        for name, script in {
            "dua": "#!/bin/sh\nprintf '4096 total\\n'\n",
            "du": "#!/bin/sh\nprintf '4\\tpartial\\n'\necho 'permission denied' >&2\nexit 1\n",
        }.items():
            executable = bindir / name
            executable.write_text(script)
            executable.chmod(0o755)
        output = self.tmp / "partial-worker.json"
        env = dict(os.environ, PATH=f"{bindir}:/opt/homebrew/bin:/usr/bin:/bin",
                   HOME=str(self.tmp), DISK_MAGICIAN_LOAD_FACTOR_OVERRIDE="1",
                   DISK_MAGICIAN_WORKER_DEADLINE_EPOCH=str(int(time.time() + 10)))
        result = subprocess.run(
            ["bash", str(SNAP), "--measure-one", "projects", str(self.tmp / "projects"), "5", str(output)],
            env=env, capture_output=True, text=True, timeout=10,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        worker = json.loads(output.read_text())
        self.assertIsNone(worker["kb"])
        self.assertEqual(worker["reason"], "backend_error")
        self.assertEqual(worker["backend"], "du")
        self.assertEqual(worker["backend_exit"], 1)
        self.assertFalse(worker["timed_out"])

    @unittest.skipIf(os.geteuid() == 0, "root can read chmod-000 children")
    def test_measure_one_real_unreadable_child_is_not_a_complete_measurement(self):
        child = self.tmp / "projects" / "unreadable"
        child.mkdir()
        (child / "payload").write_bytes(b"x" * 4096)
        self.addCleanup(lambda: child.chmod(0o700))
        child.chmod(0)
        output = self.tmp / "unreadable-worker.json"
        env = dict(os.environ, PATH="/opt/homebrew/bin:/usr/bin:/bin",
                   HOME=str(self.tmp), DISK_MAGICIAN_LOAD_FACTOR_OVERRIDE="1",
                   DISK_MAGICIAN_WORKER_DEADLINE_EPOCH=str(int(time.time() + 10)))
        result = subprocess.run(
            ["bash", str(SNAP), "--measure-one", "projects", str(self.tmp / "projects"), "5", str(output)],
            env=env, capture_output=True, text=True, timeout=10,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        worker = json.loads(output.read_text())
        self.assertIsNone(worker["kb"])
        self.assertEqual(worker["reason"], "backend_error")
        self.assertEqual(worker["backend"], "du")
        self.assertNotEqual(worker["backend_exit"], 0)

    def test_measure_one_without_bounded_backend_or_remaining_time_is_not_backend_timeout(self):
        for mode in ("no-timeout", "deadline"):
            with self.subTest(mode=mode):
                output = self.tmp / f"{mode}-worker.json"
                env = dict(os.environ, PATH="/usr/bin:/bin" if mode == "no-timeout" else "/opt/homebrew/bin:/usr/bin:/bin",
                           HOME=str(self.tmp), DISK_MAGICIAN_LOAD_FACTOR_OVERRIDE="1",
                           DISK_MAGICIAN_WORKER_DEADLINE_EPOCH=str(int(time.time() + (10 if mode == "no-timeout" else -1))))
                result = subprocess.run(
                    ["bash", str(SNAP), "--measure-one", "projects", str(self.tmp / "projects"), "5", str(output)],
                    env=env, capture_output=True, text=True, timeout=10,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                worker = json.loads(output.read_text())
                self.assertIsNone(worker["kb"])
                self.assertEqual(worker["reason"], "backend_unavailable" if mode == "no-timeout" else "orchestrator_deadline")
                self.assertFalse(worker["timed_out"])

    def test_signal_exit_codes_do_not_assert_timeout(self):
        bindir = self.tmp / "bin-signals"
        bindir.mkdir()
        for code in (137, 143):
            with self.subTest(exit_code=code):
                for name in ("dua", "du"):
                    executable = bindir / name
                    executable.write_text(f"#!/bin/sh\nexit {code}\n")
                    executable.chmod(0o755)
                output = self.tmp / f"signal-{code}.json"
                env = dict(os.environ, PATH=f"{bindir}:/opt/homebrew/bin:/usr/bin:/bin",
                           HOME=str(self.tmp), DISK_MAGICIAN_LOAD_FACTOR_OVERRIDE="1",
                           DISK_MAGICIAN_WORKER_DEADLINE_EPOCH=str(int(time.time() + 10)))
                result = subprocess.run(
                    ["bash", str(SNAP), "--measure-one", "projects", str(self.tmp / "projects"), "5", str(output)],
                    env=env, capture_output=True, text=True, timeout=10,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                worker = json.loads(output.read_text())
                self.assertIsNone(worker["kb"])
                self.assertEqual(worker["reason"], "backend_error")
                self.assertFalse(worker["timed_out"])
                self.assertEqual(worker["backend_exit"], code)

    def test_regression_full_snapshot_persists_orchestrator_failures(self):
        bindir = self.tmp / "bin-full"
        bindir.mkdir()
        dua = bindir / "dua"
        dua.write_text("#!/usr/bin/env bash\necho 'dua permission denied' >&2\nexit 13\n")
        dua.chmod(0o755)
        du = bindir / "du"
        du.write_text("#!/usr/bin/env bash\nprintf '4096\\t%s\\n' \"${@: -1}\"\necho 'du permission denied' >&2\nexit 13\n")
        du.chmod(0o755)
        output = self.tmp / "snapshot.json"
        env = dict(
            os.environ,
            PATH=f"{bindir}:/opt/homebrew/bin:/usr/bin:/bin",
            HOME=str(self.tmp),
            DISK_MAGICIAN_CONFIG=str(self.cfg),
            DISK_MAGICIAN_STATE_DIR=str(self.tmp / "state"),
            DISK_MAGICIAN_MEASURE_WORKERS="1",
            DISK_MAGICIAN_LOAD_FACTOR_OVERRIDE="1",
            DISK_MAGICIAN_SNAPSHOT_BUDGET_SECONDS="10",
        )
        result = subprocess.run(
            ["bash", str(SNAP), "--output", str(output)],
            env=env,
            capture_output=True,
            text=True,
            timeout=20,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        snapshot = json.loads(output.read_text())
        failure = snapshot["snapshot_metadata"]["measurement_failures"][0]
        self.assertEqual(failure["key"], "projects")
        self.assertEqual(failure["attempts"][0]["reason"], "backend_error")
        self.assertEqual(failure["attempts"][0]["backend_exit"], 13)

    def test_serial_and_orchestrator_fallback_preserve_backend_diagnostics(self):
        bindir = self.tmp / "bin-serial"
        bindir.mkdir()
        scanner = bindir / "du"
        scanner.write_text("#!/bin/sh\nprintf '4096\\tpartial\\n'\necho 'permission denied' >&2\nexit 1\n")
        scanner.chmod(0o755)
        failing_orchestrator = self.tmp / "failed-orchestrator.py"
        failing_orchestrator.write_text("raise SystemExit(1)\n")
        for mode in ("serial", "failing", "absent"):
            with self.subTest(mode=mode):
                output = self.tmp / f"snapshot-{mode}.json"
                env = dict(os.environ, PATH=f"{bindir}:/opt/homebrew/bin:/usr/bin:/bin",
                           HOME=str(self.tmp), DISK_MAGICIAN_CONFIG=str(self.cfg),
                           DISK_MAGICIAN_STATE_DIR=str(self.tmp / f"state-{mode}"),
                           DISK_MAGICIAN_MEASURE_WORKERS="0" if mode == "serial" else "1",
                           DISK_MAGICIAN_LOAD_FACTOR_OVERRIDE="1", DISK_MAGICIAN_SNAPSHOT_BUDGET_SECONDS="20")
                if mode != "serial":
                    env["DISK_MAGICIAN_MEASURE_ORCHESTRATOR"] = str(failing_orchestrator if mode == "failing" else self.tmp / "absent.py")
                result = subprocess.run(["bash", str(SNAP), "--output", str(output)], env=env,
                                        capture_output=True, text=True, timeout=25)
                self.assertEqual(result.returncode, 0, result.stderr)
                snapshot = json.loads(output.read_text())
                self.assertIsNone(snapshot["directories"]["projects"])
                self.assertEqual(snapshot["snapshot_metadata"]["measure_mode"], "serial" if mode == "serial" else "serial_fallback")
                failure = next(item for item in snapshot["snapshot_metadata"]["measurement_failures"] if item["key"] == "projects")
                self.assertEqual(failure["status"], "failed")
                self.assertEqual([attempt["attempt"] for attempt in failure["attempts"]], [1, 2])
                for attempt in failure["attempts"]:
                    self.assertEqual(attempt["reason"], "backend_error")
                    self.assertEqual(attempt["backend_exit"], 1)
                    self.assertIn("permission denied", attempt["stderr"])
                    self.assertLessEqual(len(attempt["stderr"]), 256)


if __name__ == "__main__":
    unittest.main()
