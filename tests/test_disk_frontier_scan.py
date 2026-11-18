import errno
import pathlib
import subprocess
import sys
import unittest
from types import SimpleNamespace
from unittest import mock

REPO = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "scripts"))
import disk_frontier_scan as frontier  # noqa: E402


class _FakeScandirCM:
    def __init__(self, entries, raise_on_iter=None):
        self._entries = entries
        self._raise_on_iter = raise_on_iter

    def __enter__(self):
        return self._iter()

    def __exit__(self, exc_type, exc, tb):
        return False

    def _iter(self):
        for entry in self._entries:
            yield entry
        if self._raise_on_iter is not None:
            raise self._raise_on_iter


class TestListChildrenEintrRetry(unittest.TestCase):
    def test_list_children_retries_scandir_on_eintr_and_succeeds(self):
        entry = SimpleNamespace(
            path="/System/Volumes/Data/Users/jleechan/Library/Containers/com.apple.photoanalysisd/Data/tmp/item",
            is_symlink=mock.Mock(return_value=False),
        )
        calls = []

        def fake_scandir(path):
            calls.append(path)
            if len(calls) == 1:
                raise OSError(errno.EINTR, "Interrupted system call")
            return _FakeScandirCM([entry])

        unfinished = []
        with mock.patch.object(frontier.os, "scandir", side_effect=fake_scandir):
            children, err = frontier.list_children(
                "/System/Volumes/Data/Users/jleechan/Library/Containers/com.apple.photoanalysisd/Data/tmp",
                unfinished=unfinished,
            )

        self.assertIsNone(err)
        self.assertEqual(children, [(entry.path, False)])
        self.assertEqual(unfinished, [])
        self.assertEqual(len(calls), 2)

    def test_list_children_retries_mid_iteration_eintr_without_duplicates(self):
        entry1 = SimpleNamespace(path="/fixture/a", is_symlink=mock.Mock(return_value=False))
        entry2 = SimpleNamespace(path="/fixture/b", is_symlink=mock.Mock(return_value=True))
        calls = []

        def fake_scandir(path):
            calls.append(path)
            if len(calls) == 1:
                return _FakeScandirCM(
                    [entry1],
                    raise_on_iter=OSError(errno.EINTR, "Interrupted system call"),
                )
            return _FakeScandirCM([entry1, entry2])

        unfinished = []
        with mock.patch.object(frontier.os, "scandir", side_effect=fake_scandir):
            children, err = frontier.list_children("/fixture", unfinished=unfinished)

        self.assertIsNone(err)
        self.assertEqual(children, [("/fixture/a", False), ("/fixture/b", True)])
        self.assertEqual(unfinished, [])
        self.assertEqual(len(calls), 2)

    def test_list_children_retries_is_symlink_on_eintr(self):
        is_symlink = mock.Mock(
            side_effect=[OSError(errno.EINTR, "Interrupted system call"), True]
        )
        entry = SimpleNamespace(path="/fixture/link", is_symlink=is_symlink)
        unfinished = []
        with mock.patch.object(
            frontier.os, "scandir", return_value=_FakeScandirCM([entry])
        ):
            children, err = frontier.list_children("/fixture", unfinished=unfinished)

        self.assertIsNone(err)
        self.assertEqual(children, [("/fixture/link", True)])
        self.assertEqual(unfinished, [])
        self.assertEqual(is_symlink.call_count, 2)

    def test_list_children_preserves_fallback_after_exhausting_eintr_retries(self):
        with mock.patch.object(
            frontier.os,
            "scandir",
            side_effect=OSError(errno.EINTR, "Interrupted system call"),
        ) as mocked_scandir:
            children, err = frontier.list_children("/fixture")

        self.assertIsNone(children)
        self.assertEqual(err, f"enumeration_errno_{errno.EINTR}")
        self.assertEqual(mocked_scandir.call_count, 3)

    def test_df_and_diskutil_calls_are_bounded_and_survive_timeout(self):
        timeout = subprocess.TimeoutExpired(cmd="df", timeout=30)
        with mock.patch.object(
            frontier.subprocess, "check_output", side_effect=timeout
        ) as co:
            stats = frontier.get_disk_stats("/fixture")
            warnings = []
            siblings = frontier.get_sibling_volumes("/fixture", warnings)
        self.assertEqual(stats, {"total_kb": 0, "used_kb": 0, "free_kb": 0})
        self.assertEqual(siblings, {})
        self.assertTrue(co.call_args_list)
        for call in co.call_args_list:
            self.assertEqual(call.kwargs.get("timeout"), 30)




class TestFrontierAccountingFixes5fba(unittest.TestCase):
    def test_gdu_inventory_treats_resource_deadlock_avoided_as_localized_error(self):
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            clean = root / "clean"
            dataless = root / "VoiceOver" / "Documents"
            clean.mkdir(parents=True)
            dataless.mkdir(parents=True)
            stdout = f"4\t{clean}\0"
            stderr = (
                f"gdu: cannot read directory '{dataless}': Resource deadlock avoided\n"
                f"gdu: fts_read failed: {dataless}/nested: Resource deadlock avoided\n"
            )
            fake_proc = SimpleNamespace(returncode=1, stdout=stdout, stderr=stderr)
            with mock.patch.object(frontier, "GDU_CMD", "gdu"), \
                 mock.patch.object(frontier.subprocess, "run", return_value=fake_proc):
                result = frontier.run_gdu_inventory([str(clean), str(root / "VoiceOver")], 10.0, frontier.ConcurrencyTracker(), 1000)

        self.assertTrue(result["usable"], result)
        self.assertEqual(result["unknown_errors"], [])
        self.assertEqual(
            result["error_paths"],
            [
                {"path": str(dataless), "reason": "inventory_resource_deadlock"},
                {"path": f"{dataless}/nested", "reason": "inventory_resource_deadlock"},
            ],
        )


    def test_one_pass_inventory_survives_resource_deadlock_and_keeps_clean_siblings(self):
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            clean_dir = root / "clean"
            clean_file = clean_dir / "payload.bin"
            clean_dir.mkdir(parents=True)
            clean_file.write_bytes(b"hello")
            voiceover = root / "VoiceOver"
            dataless = voiceover / "Documents"
            dataless.mkdir(parents=True)

            args = frontier.parse_args([
                "--root", str(root), "--no-sibling-volumes", "--no-purgeable",
                "--workers", "1", "--wall-clock-cap", "20",
            ])
            scanner = frontier.FrontierScanner(args)
            scanner.start_time = frontier.time.time()
            scanner.run_started_at = scanner.start_time

            stdout = f"4\t{clean_file}\08\t{clean_dir}\0"
            stderr = f"gdu: cannot read directory '{dataless}': Resource deadlock avoided\n"
            fake_proc = SimpleNamespace(returncode=1, stdout=stdout, stderr=stderr)

            with mock.patch.object(frontier, "GDU_CMD", "gdu"), \
                 mock.patch.object(frontier.subprocess, "run", return_value=fake_proc):
                used_one_pass = scanner.run_one_pass_inventory([
                    (str(clean_dir), False),
                    (str(voiceover), False),
                ])
            scanner.level1_paths = [str(clean_dir), str(voiceover)]
            scanner.run_finished_at = 101.0
            report = frontier.build_report(
                scanner,
                {"total_kb": 1000, "used_kb": 100, "free_kb": 900},
                {},
                {"purgeable_kb": 0, "purgeable_estimate_method": "fixture",
                 "local_snapshots": [], "local_snapshots_count": 0},
                1.0,
                args,
            )

        self.assertTrue(used_one_pass)
        self.assertEqual(report["config"]["scan_backend"], "gdu_one_pass")
        self.assertEqual(report["mode"], "partial")
        self.assertEqual(scanner.measured[str(clean_dir)], 8)
        self.assertEqual(
            [item["reason"] for item in report["frontier_unfinished"]],
            ["inventory_resource_deadlock"],
        )
        self.assertEqual(report["frontier_unfinished"][0]["path"], str(dataless))

    def test_top_level_symlinks_attributed_without_following_targets(self):
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            base = pathlib.Path(tmp)
            hermes = base / "hermes"
            workspace = hermes / "workspace"
            outside = base / "outside-orch-venv"
            workspace.mkdir(parents=True)
            outside.mkdir(parents=True)
            agents_target = workspace / "AGENTS.md"
            agents_target.write_text("# agents\n", encoding="utf-8")
            (outside / "pyvenv.cfg").write_text("home = /usr/bin\n", encoding="utf-8")
            (hermes / "AGENTS.md").symlink_to(agents_target)
            (hermes / ".venv").symlink_to(outside)

            args = frontier.parse_args([
                "--root", str(hermes), "--no-sibling-volumes", "--no-purgeable",
                "--workers", "1", "--wall-clock-cap", "20",
            ])
            scanner = frontier.FrontierScanner(args)
            scanner.start_time = 100.0
            scanner.run_started_at = 100.0
            scanner.run_finished_at = 101.0
            scanner.level1_paths = [
                str(hermes / ".venv"),
                str(hermes / "AGENTS.md"),
                str(workspace),
            ]
            scanner.measured = {
                str(hermes / ".venv"): 0,
                str(hermes / "AGENTS.md"): 0,
                str(agents_target): 4,
            }
            scanner.apparent_bytes = {
                str(hermes / ".venv"): len(str(outside)),
                str(hermes / "AGENTS.md"): len(str(agents_target)),
                str(agents_target): agents_target.stat().st_size,
                str(workspace): agents_target.stat().st_size,
            }
            report = frontier.build_report(
                scanner,
                {"total_kb": 1000, "used_kb": 100, "free_kb": 900},
                {},
                {"purgeable_kb": 0, "purgeable_estimate_method": "fixture",
                 "local_snapshots": [], "local_snapshots_count": 0},
                1.0,
                args,
            )

        self.assertEqual(report["mode"], "complete", report["top_level_ledger"])
        self.assertEqual(report["coverage_envelope"]["unfinished_top_level_roots"], 0)
        self.assertEqual(report["coverage_envelope"]["measured_top_level_roots"], 3)
        self.assertEqual(report["coverage_envelope"]["reachable_top_level_roots"], 3)
        by_path = {item["path"]: item for item in report["top_level_ledger"]}
        self.assertEqual(set(by_path), {str(hermes / ".venv"), str(hermes / "AGENTS.md"), str(workspace)})
        self.assertEqual(by_path[str(hermes / ".venv")]["status"], "measured")
        self.assertEqual(by_path[str(hermes / ".venv")]["measured_kb"], 0)
        self.assertEqual(by_path[str(hermes / "AGENTS.md")]["status"], "measured")
        self.assertEqual(by_path[str(hermes / "AGENTS.md")]["measured_kb"], 0)
        self.assertEqual(by_path[str(workspace)]["status"], "measured_by_descendants")
        self.assertEqual(by_path[str(workspace)]["measured_kb"], 4)

    def test_mode_is_partial_when_top_level_roots_unfinished_even_without_frontier_unfinished(self):
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp) / "root"
            (root / "ok").mkdir(parents=True)
            (root / "missing").mkdir(parents=True)
            (root / "missing" / "unreported.bin").write_text("x", encoding="utf-8")
            args = frontier.parse_args([
                "--root", str(root), "--no-sibling-volumes", "--no-purgeable",
                "--workers", "1", "--wall-clock-cap", "20",
            ])
            scanner = frontier.FrontierScanner(args)
            scanner.start_time = 100.0
            scanner.run_started_at = 100.0
            scanner.run_finished_at = 101.0
            scanner.level1_paths = [str(root / "ok"), str(root / "missing")]
            scanner.measured = {str(root / "ok"): 4}
            scanner.frontier_unfinished = []
            report = frontier.build_report(
                scanner,
                {"total_kb": 1000, "used_kb": 100, "free_kb": 900},
                {},
                {"purgeable_kb": 0, "purgeable_estimate_method": "fixture",
                 "local_snapshots": [], "local_snapshots_count": 0},
                1.0,
                args,
            )

        self.assertEqual(report["coverage_envelope"]["unfinished_top_level_roots"], 1)
        self.assertFalse(report["coverage_envelope"]["complete"])
        self.assertEqual(report["mode"], "partial")


if __name__ == "__main__":
    unittest.main()
