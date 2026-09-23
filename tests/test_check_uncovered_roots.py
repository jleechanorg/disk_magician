"""tests/test_check_uncovered_roots.py — bead disk_magician-8to.

Verifies scripts/check_uncovered_roots.py flags >=threshold directories with
no registered sweeper owner (config/sweeper_roots.txt), from
frontier/discover fixture data only — it must never shell out to du.
"""
import json
import os
import subprocess
import sys
import tempfile
import unittest

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT = os.path.join(REPO_ROOT, "scripts", "check_uncovered_roots.py")

sys.path.insert(0, os.path.join(REPO_ROOT, "scripts"))
import check_uncovered_roots as cur_module  # noqa: E402

GIB_KB = 1024 * 1024


def write_json(path, data):
    with open(path, "w") as f:
        json.dump(data, f)


def run(args):
    proc = subprocess.run(
        [sys.executable, SCRIPT] + args,
        capture_output=True, text=True, timeout=30, check=False,
    )
    return proc


class TestCheckUncoveredRoots(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="dm_uncovered_")
        self.home = os.path.join(self.tmp, "home")
        os.makedirs(self.home)
        self.snapshot = os.path.join(self.tmp, "frontier_last.json")
        self.discover = os.path.join(self.tmp, "discover_last.json")
        self.registry = os.path.join(self.tmp, "sweeper_roots.txt")

    def _run_json(self, extra=None):
        args = [
            "--snapshot", self.snapshot,
            "--discover", self.discover,
            "--registry", self.registry,
            "--home", self.home,
            "--darwin-tmp", "",  # resolvable-but-absent by default in tests
            "--json",
        ]
        if extra:
            args += extra
        proc = run(args)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        return json.loads(proc.stdout)

    def test_uncovered_dir_flagged_covered_dir_excluded(self):
        uncovered_dir = os.path.join(self.home, "uncovered_big")
        covered_dir = os.path.join(self.home, "covered_big")
        # Bucket paths are the target dirs themselves (leaf entries, no
        # deeper nesting) — matching how real frontier granularity_buckets
        # entries are already-leaf directories at whatever depth the scan
        # stopped subdividing.
        write_json(self.snapshot, {
            "captured_at": None,
            "granularity_buckets": [
                {"path": uncovered_dir, "measured_kb": 6 * GIB_KB},
                {"path": covered_dir, "measured_kb": 6 * GIB_KB},
            ],
        })
        with open(self.registry, "w") as f:
            f.write(f"{covered_dir}\tcleanup_fixture.sh\tfixture covered root\n")

        result = self._run_json()
        paths = [e["path"] for e in result["uncovered"]]
        self.assertIn(uncovered_dir, paths)
        self.assertNotIn(covered_dir, paths)
        # Every returned entry must independently satisfy the threshold.
        for e in result["uncovered"]:
            self.assertGreaterEqual(e["size_kb"], result["threshold_gib"] * GIB_KB)

    def test_below_threshold_not_flagged(self):
        small_dir = os.path.join(self.home, "small")
        write_json(self.snapshot, {
            "granularity_buckets": [
                {"path": os.path.join(small_dir, "a"), "measured_kb": 2 * GIB_KB},
            ],
        })
        open(self.registry, "w").close()
        result = self._run_json()
        self.assertEqual(result["uncovered"], [])

    def test_no_data_available_returns_empty_not_error(self):
        # Neither snapshot nor discover file exists.
        open(self.registry, "w").close()
        result = self._run_json()
        self.assertEqual(result["uncovered"], [])
        self.assertEqual(result["source"], "none")

    def test_discover_fallback_when_snapshot_missing(self):
        uncovered_dir = os.path.join(self.home, "discover_only_big")
        write_json(self.discover, {
            "generated_at": "2026-09-22T00:00:00Z",
            "cache_hits": 0,
            "cache_misses": 1,
            "entries": [
                {"path": uncovered_dir, "size_kb": 8 * GIB_KB, "size_gb": 8.0, "tracked": False},
            ],
        })
        open(self.registry, "w").close()
        result = self._run_json()
        self.assertEqual(result["source"], f"discover:{self.discover}")
        paths = [e["path"] for e in result["uncovered"]]
        self.assertIn(uncovered_dir, paths)

    def test_stale_snapshot_falls_back_to_discover(self):
        stale_dir = os.path.join(self.home, "stale_snapshot_big")
        fresh_dir = os.path.join(self.home, "fresh_discover_big")
        write_json(self.snapshot, {
            "captured_at": "2000-01-01T00:00:00Z",  # decades old -> always stale
            "granularity_buckets": [
                {"path": os.path.join(stale_dir, "a"), "measured_kb": 9 * GIB_KB},
            ],
        })
        write_json(self.discover, {
            "entries": [
                {"path": fresh_dir, "size_kb": 9 * GIB_KB, "tracked": False},
            ],
        })
        open(self.registry, "w").close()
        result = self._run_json(extra=["--max-age-hours", "1"])
        self.assertEqual(result["source"], f"discover:{self.discover}")
        paths = [e["path"] for e in result["uncovered"]]
        self.assertIn(fresh_dir, paths)
        self.assertNotIn(stale_dir, paths)

    def test_darwin_user_temp_dir_token_expansion(self):
        darwin_tmp = os.path.join(self.tmp, "var_folders_T")
        covered_sub = os.path.join(darwin_tmp, "ao-session1")
        uncovered_sub = os.path.join(darwin_tmp, "pr-review-scratch")
        write_json(self.snapshot, {
            "granularity_buckets": [
                {"path": covered_sub, "measured_kb": 6 * GIB_KB},
                {"path": uncovered_sub, "measured_kb": 6 * GIB_KB},
            ],
        })
        with open(self.registry, "w") as f:
            f.write("$DARWIN_USER_TEMP_DIR/ao-session1\tcleanup_sessions.sh\tnarrow ao subpath only\n")

        args = [
            "--snapshot", self.snapshot,
            "--discover", self.discover,
            "--registry", self.registry,
            "--home", self.home,
            "--darwin-tmp", darwin_tmp,
            "--json",
        ]
        proc = run(args)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        result = json.loads(proc.stdout)
        paths = [e["path"] for e in result["uncovered"]]
        self.assertIn(uncovered_sub, paths)
        self.assertNotIn(covered_sub, paths)

    def test_darwin_user_temp_dir_unresolvable_drops_registry_entry(self):
        # No --darwin-tmp override and getconf is unlikely to match a fixture
        # path anyway — the entry must be silently dropped (fail closed:
        # never fabricate coverage), not crash.
        with open(self.registry, "w") as f:
            f.write("$DARWIN_USER_TEMP_DIR/whatever\tcleanup_sessions.sh\tunresolvable in test env\n")
        write_json(self.snapshot, {"granularity_buckets": []})
        result = self._run_json()
        self.assertEqual(result["uncovered"], [])  # no crash, just no data

    def test_path_equal_or_under_never_delete_is_protected(self):
        # Reproduces the PR #72 review finding at 4e15d24: ~/.codex/sessions/...
        # and ~/.claude/projects printed as UNCOVERED, identical wording to a
        # real gap like /Applications. Both are on the real, committed
        # safety.local.json.template never_delete list. classify_path_protection
        # is loaded from that same file (HOME overridden to this fixture home,
        # so it resolves to the committed template rather than this machine's
        # real ~/.config override) — case (a): equal-to-or-under only.
        #
        # The codex-sessions bucket is placed one level DEEPER than the
        # "~/.codex/sessions*" glob boundary (.../sessions/2026/08) on
        # purpose: fnmatch's "*" absorbs the remaining path, so the walk
        # classifies the *ancestor* ".../sessions" as the direct match and
        # stops drilling there — the review-finding fix's whole point is
        # that this reports the boundary, not a fragment two levels deeper.
        codex_sessions_leaf = os.path.join(self.home, ".codex", "sessions", "2026", "08")
        codex_sessions_boundary = os.path.join(self.home, ".codex", "sessions")
        claude_projects = os.path.join(self.home, ".claude", "projects")
        real_gap = os.path.join(self.home, "Applications")
        write_json(self.snapshot, {
            "granularity_buckets": [
                {"path": codex_sessions_leaf, "measured_kb": 20 * GIB_KB},
                {"path": claude_projects, "measured_kb": 6 * GIB_KB},
                {"path": real_gap, "measured_kb": 25 * GIB_KB},
            ],
        })
        open(self.registry, "w").close()  # no sweeper covers anything

        result = self._run_json()
        uncovered_paths = [e["path"] for e in result["uncovered"]]
        protected_paths = [e["path"] for e in result["protected"]]

        self.assertIn(real_gap, uncovered_paths)
        self.assertNotIn(real_gap, protected_paths)

        for p in (codex_sessions_boundary, claude_projects):
            self.assertIn(p, protected_paths, f"{p} should be PROTECTED")
            self.assertNotIn(p, uncovered_paths, f"{p} must not also appear as UNCOVERED")
        self.assertNotIn(codex_sessions_leaf, protected_paths + uncovered_paths,
                          "the fragment below the never_delete boundary must not be "
                          "reported separately — the boundary node covers it")

        for e in result["protected"]:
            self.assertIn("never_delete", e["reason"])

        # Text-mode output must use the exact wording the review asked for.
        text_proc = run([
            "--snapshot", self.snapshot, "--discover", self.discover,
            "--registry", self.registry, "--home", self.home, "--darwin-tmp", "",
        ])
        self.assertEqual(text_proc.returncode, 0, text_proc.stderr)
        self.assertIn("PROTECTED (never-delete, no sweeper by policy):", text_proc.stdout)
        self.assertNotIn(f"UNCOVERED: {codex_sessions_boundary}", text_proc.stdout)
        self.assertNotIn(f"UNCOVERED: {claude_projects}", text_proc.stdout)
        self.assertIn(f"UNCOVERED: {real_gap}", text_proc.stdout)

    def test_ancestor_containing_never_delete_child_is_not_protected(self):
        # PR #72 round-2 review finding at 81315fc: a directory that merely
        # CONTAINS a never_delete path (but isn't itself equal to/under one)
        # was wrongly reported PROTECTED. ~/.hermes/state.db* is a real
        # never_delete literal in the committed template; make it small
        # enough that it can't be isolated as its own >=threshold child, so
        # the parent falls into the leaf-reporting remainder path.
        # Every child stays individually below the 5 GiB threshold (so none
        # of them can be isolated as its own drilled "big child") while the
        # parent's combined total clears it — this is what forces the
        # leaf-reporting remainder fallback at the PARENT level instead of
        # the walk simply recursing into a big protected child on its own.
        parent = os.path.join(self.home, ".hermes")
        protected_child = os.path.join(parent, "state.db")   # matches never_delete
        plain_child_a = os.path.join(parent, "other_state_a")
        plain_child_b = os.path.join(parent, "other_state_b")
        write_json(self.snapshot, {
            "granularity_buckets": [
                {"path": protected_child, "measured_kb": 2 * GIB_KB},
                {"path": plain_child_a, "measured_kb": 4 * GIB_KB},
                {"path": plain_child_b, "measured_kb": 4 * GIB_KB},
            ],
        })
        open(self.registry, "w").close()

        result = self._run_json()
        protected_paths = [e["path"] for e in result["protected"]]
        self.assertNotIn(parent, protected_paths,
                          "a directory that only CONTAINS a never_delete path must "
                          "not itself be PROTECTED")
        self.assertNotIn(protected_child, protected_paths,
                          "the protected child is too small to isolate on its own "
                          "and must not be fabricated as its own PROTECTED entry")

        contains = [e for e in result["uncovered"] if e["path"] == parent]
        self.assertEqual(len(contains), 1, f"expected exactly one entry for {parent}: "
                          f"{result['uncovered']}")
        entry = contains[0]
        self.assertEqual(entry["label"], "CONTAINS-PROTECTED")
        # 10 GiB total minus the 2 GiB never_delete child == 8 GiB remainder.
        self.assertAlmostEqual(entry["size_kb"], 8 * GIB_KB, delta=1)
        self.assertIn("never_delete", entry["note"])

    def test_needs_decision_path_is_labelled_needs_decision(self):
        # Case (c): needs_decision is not never-delete — it gets its own
        # label and still counts as an unswept gap. ~/.openclaw/repo-backups
        # is a real needs_decision entry in the committed template.
        nd_path = os.path.join(self.home, ".openclaw", "repo-backups")
        write_json(self.snapshot, {
            "granularity_buckets": [
                {"path": nd_path, "measured_kb": 8 * GIB_KB},
            ],
        })
        open(self.registry, "w").close()

        result = self._run_json()
        nd_paths = [e["path"] for e in result["needs_decision"]]
        self.assertIn(nd_path, nd_paths)
        self.assertNotIn(nd_path, [e["path"] for e in result["protected"]])
        self.assertNotIn(nd_path, [e["path"] for e in result["uncovered"]])
        entry = next(e for e in result["needs_decision"] if e["path"] == nd_path)
        self.assertIn("needs_decision", entry["reason"])

        text_proc = run([
            "--snapshot", self.snapshot, "--discover", self.discover,
            "--registry", self.registry, "--home", self.home, "--darwin-tmp", "",
        ])
        self.assertIn("NEEDS-DECISION (operator):", text_proc.stdout)
        self.assertNotIn("PROTECTED (never-delete", text_proc.stdout)

    def test_matches_real_safety_check_sh(self):
        # Cross-validation guard against the in-process port
        # (classify_path_protection) drifting from the real
        # scripts/safety_check.sh / safety_lib.sh it mirrors.
        repo_root = REPO_ROOT
        rules = cur_module.load_safety_rules(repo_root, self.home)
        cases = [
            os.path.join(self.home, ".codex", "sessions", "2026", "08"),  # under never_delete
            os.path.join(self.home, ".claude", "projects"),               # exact never_delete
            os.path.join(self.home, "projects_other"),                    # not protected at all
            os.path.join(self.home, ".openclaw", "repo-backups"),         # needs_decision
        ]
        env = dict(os.environ)
        env["HOME"] = self.home
        safety_check = os.path.join(repo_root, "scripts", "safety_check.sh")
        proc = subprocess.run(["bash", safety_check] + cases, capture_output=True,
                               text=True, timeout=30, check=False, env=env)
        real_protected = set()
        for line in proc.stdout.splitlines():
            if line.startswith("PROTECTED  "):
                real_protected.add(line[len("PROTECTED  "):].split("  ", 1)[0])
        for case in cases:
            direct_hits, _descendant_hits = cur_module.classify_path_protection(case, rules, self.home)
            mine_protected = bool(direct_hits)
            self.assertEqual(
                mine_protected, case in real_protected,
                f"classify_path_protection disagrees with safety_check.sh for {case}: "
                f"mine={mine_protected} real={case in real_protected}",
            )

    def test_colima_registry_narrowed_to_actual_sweeper_subpaths(self):
        # bead disk_magician-ka4 review finding: a bare $HOME/.colima entry
        # over-claimed coverage of the whole tree; cleanup_colima.sh only
        # ever touches _lima and default/docker.sock.
        colima_lima = os.path.join(self.home, ".colima", "_lima")
        colima_other = os.path.join(self.home, ".colima", "not_touched_by_sweeper")
        write_json(self.snapshot, {
            "granularity_buckets": [
                {"path": colima_lima, "measured_kb": 30 * GIB_KB},
                {"path": colima_other, "measured_kb": 6 * GIB_KB},
            ],
        })
        with open(self.registry, "w") as f:
            f.write(f"{os.path.join(self.home, '.colima', '_lima')}\tcleanup_colima.sh\tCOLIMA_LIMA\n")
            f.write(f"{os.path.join(self.home, '.colima', 'default', 'docker.sock')}\tcleanup_colima.sh\tCOLIMA_DOCKER_SOCKET\n")

        result = self._run_json()
        paths = [e["path"] for e in result["uncovered"]]
        self.assertNotIn(colima_lima, paths)
        self.assertIn(colima_other, paths)

    def test_repo_registry_colima_entries_are_narrowed(self):
        # Guards against a future regression re-widening config/sweeper_roots.txt
        # back to a bare $HOME/.colima entry.
        registry_path = os.path.join(REPO_ROOT, "config", "sweeper_roots.txt")
        with open(registry_path) as f:
            content = f.read()
        for line in content.splitlines():
            if line.lstrip().startswith("#") or not line.strip():
                continue
            pattern = line.split("\t", 1)[0].strip()
            if pattern == "$HOME/.colima":
                self.fail("config/sweeper_roots.txt must not list the bare $HOME/.colima "
                          "root — narrow it to the exact cleanup_colima.sh subpaths "
                          "(_lima, default/docker.sock)")
        self.assertIn("$HOME/.colima/_lima", content)
        self.assertIn("$HOME/.colima/default/docker.sock", content)

    def test_drill_down_finds_uncovered_sibling_under_partially_covered_parent(self):
        parent = os.path.join(self.home, "parent")
        covered_child = os.path.join(parent, "covered_child")
        uncovered_child = os.path.join(parent, "uncovered_child")
        write_json(self.snapshot, {
            "granularity_buckets": [
                {"path": covered_child, "measured_kb": 6 * GIB_KB},
                {"path": uncovered_child, "measured_kb": 6 * GIB_KB},
            ],
        })
        with open(self.registry, "w") as f:
            f.write(f"{covered_child}\tcleanup_fixture.sh\tonly this child is swept\n")
        result = self._run_json()
        paths = [e["path"] for e in result["uncovered"]]
        # The parent as a whole is not covered, but since one of its two
        # >=threshold children IS covered, drill-down must report the
        # specific uncovered child rather than the whole (partially-owned)
        # parent blob.
        self.assertIn(uncovered_child, paths)
        self.assertNotIn(covered_child, paths)
        self.assertNotIn(parent, paths)


if __name__ == "__main__":
    unittest.main()
