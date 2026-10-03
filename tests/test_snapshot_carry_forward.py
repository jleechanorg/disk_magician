"""Carry-forward store for last-good snapshot measurements (spec 2026-10-03)."""
import json
import os
import subprocess
import sys
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / "scripts" / "snapshot_carry.py"
NOW = "2026-10-03T12:00:00Z"


def run(*args, check=True):
    return subprocess.run([sys.executable, str(SCRIPT), *args], capture_output=True, text=True, check=check)


def cfg(tmp_path, dirs=None, globs=None):
    dirs = dirs or [{"key": "projects", "path": "~/projects"}, {"key": "claude_root", "path": "~/.claude"}]
    p = tmp_path / "config.json"
    p.write_text(json.dumps({"monitored_dirs": dirs, "monitored_file_globs": globs or []}))
    return str(p)


def write(tmp_path, name, obj):
    p = tmp_path / name
    p.write_text(json.dumps(obj))
    return str(p)


def state_entry(kb, measured_at, path="~/projects"):
    return {"kb": kb, "measured_at": measured_at, "path": path, "source": "du"}


def merge(tmp_path, state, fresh, config=None, max_age=72):
    s = write(tmp_path, "state.json", state)
    f = write(tmp_path, "fresh.json", fresh)
    out = run("merge", "--state", s, "--fresh", f, "--now", NOW, "--max-age-hours", str(max_age),
              "--config", config or cfg(tmp_path))
    return json.loads(out.stdout)


def test_update_only_fresh_non_null(tmp_path):
    state = tmp_path / "state.json"
    state.write_text(json.dumps({"projects": state_entry(500, "2026-10-02T12:00:00Z")}))
    fresh = write(tmp_path, "fresh.json", {"projects": {"kb": None, "path": "~/projects"},
                                           "claude_root": {"kb": 700, "path": "~/.claude"}})
    run("update", "--state", str(state), "--fresh", fresh, "--now", NOW)
    d = json.loads(state.read_text())
    assert d["projects"]["kb"] == 500  # null never overwrites last-good
    assert d["claude_root"] == {"kb": 700, "measured_at": NOW, "path": "~/.claude", "source": "du"}


def test_atomic_write_survives_kill(tmp_path):
    state = tmp_path / "state.json"
    state.write_text(json.dumps({"projects": state_entry(500, NOW)}))
    # A leftover tmp file from an interrupted writer must not corrupt or block the store.
    (tmp_path / "state.json.tmp").write_text("{trunc")
    fresh = write(tmp_path, "fresh.json", {"claude_root": {"kb": 7, "path": "~/.claude"}})
    run("update", "--state", str(state), "--fresh", fresh, "--now", NOW)
    assert json.loads(state.read_text())["projects"]["kb"] == 500
    assert json.loads(state.read_text())["claude_root"]["kb"] == 7


def test_carry_within_72h_tagged_with_age(tmp_path):
    r = merge(tmp_path, {"projects": state_entry(900, "2026-10-01T12:00:00Z")},
              {"projects": {"kb": None, "path": "~/projects"}, "claude_root": {"kb": 5, "path": "~/.claude"}})
    assert r["carried"]["projects"] == {"kb": 900, "age_hours": 24.0}
    assert r["fresh"] == {"claude_root": 5}
    assert r["unmeasured"] == []


def test_expired_carry_becomes_unmeasured_not_zero(tmp_path):
    r = merge(tmp_path, {"projects": state_entry(900, "2026-09-29T12:00:00Z")},  # 96 h old
              {"projects": {"kb": None, "path": "~/projects"}, "claude_root": {"kb": 5, "path": "~/.claude"}})
    assert "projects" in r["unmeasured"] and "projects" not in r["carried"] and "projects" not in r["fresh"]
    assert r["gap_estimate_kb"]["projects"] == 900  # stale value only feeds the gap estimate


def test_corrupt_file_moved_aside_treated_empty(tmp_path):
    state = tmp_path / "state.json"
    state.write_text("{not json")
    f = write(tmp_path, "fresh.json", {"projects": {"kb": None, "path": "~/projects"}})
    out = run("merge", "--state", str(state), "--fresh", f, "--now", NOW, "--max-age-hours", "72",
              "--config", cfg(tmp_path))
    r = json.loads(out.stdout)
    assert "projects" in r["unmeasured"]
    assert not state.exists() or json.loads(state.read_text()) == {}
    assert any(p.name.startswith("state.json.corrupt") for p in tmp_path.iterdir())


def test_path_change_invalidates_carry(tmp_path):
    r = merge(tmp_path, {"projects": state_entry(900, "2026-10-02T12:00:00Z", path="~/old_projects")},
              {"projects": {"kb": None, "path": "~/projects"}})
    assert "projects" in r["unmeasured"] and "projects" not in r["carried"]


def test_never_emits_zero_for_missing(tmp_path):
    r = merge(tmp_path, {}, {"projects": {"kb": None, "path": "~/projects"}})
    assert r["fresh"] == {} and r["carried"] == {} and set(r["unmeasured"]) >= {"projects", "claude_root"}


def test_lc_and_glob_keys_never_carried(tmp_path):
    config = cfg(tmp_path, globs=[{"key": "worktrees_home", "pattern": "~/worktree_*"}])
    state = {"worktrees_home": state_entry(40, "2026-10-02T12:00:00Z", "~/worktree_*"),
             "lc_foo": state_entry(10, "2026-10-02T12:00:00Z", "/x/lc_foo")}
    r = merge(tmp_path, state, {"worktrees_home": {"kb": None, "path": "~/worktree_*"},
                                "lc_foo": {"kb": None, "path": "/x/lc_foo"}}, config=config)
    assert "worktrees_home" in r["unmeasured"] and "worktrees_home" not in r["carried"]
    assert "lc_foo" not in r["carried"]
    # update never stores them either
    s = tmp_path / "u.json"
    f = write(tmp_path, "uf.json", {"worktrees_home": {"kb": 3, "path": "~/worktree_*"},
                                    "lc_foo": {"kb": 3, "path": "/x"}, "projects": {"kb": 3, "path": "~/projects"}})
    run("update", "--state", str(s), "--fresh", f, "--now", NOW)
    assert set(json.loads(s.read_text())) == {"projects"}


def test_72h_retention_and_48h_alert_age(tmp_path):
    r = merge(tmp_path, {"projects": state_entry(900, "2026-09-30T11:00:00Z")},  # 49 h old
              {"projects": {"kb": None, "path": "~/projects"}, "claude_root": {"kb": 5, "path": "~/.claude"}})
    assert r["carried"]["projects"]["age_hours"] == 49.0  # still carried: retention 72 > alert 48


def test_from_tsv_contract(tmp_path):
    tsv = tmp_path / "dirs.tsv"
    tsv.write_text("projects\t123\t~/projects\nclaude_root\tnull\t~/.claude\nbad line\n")
    out = json.loads(run("from-tsv", "--tsv", str(tsv)).stdout)
    assert out == {"projects": {"kb": 123, "path": "~/projects"}, "claude_root": {"kb": None, "path": "~/.claude"}}
