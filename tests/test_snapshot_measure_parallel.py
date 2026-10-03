"""Bounded parallel measurement orchestrator (spec 2026-10-03, section 1)."""
import json
import os
import signal
import stat
import subprocess
import sys
import textwrap
import time
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
ORCH = ROOT / "scripts" / "snapshot_measure.py"
SNAP = ROOT / "scripts" / "disk_snapshot.sh"
sys.path.insert(0, str(ROOT / "scripts"))

FAKE_WORKER = textwrap.dedent('''\
    #!/usr/bin/env bash
    # fake `disk_snapshot.sh --measure-one KEY PATH TIMEOUT OUTFILE`
    shift  # --measure-one
    key="$1"; path="$2"; to="$3"; out="$4"
    d="${FAKE_DIR:?}"
    echo "$(date +%s.%N) start $key $to" >> "$d/events.log"
    env > "$d/env.$key"
    touch "$d/running.$key"
    echo "$(ls "$d"/running.* | wc -l)" >> "$d/concurrency.log"
    spec=$(python3 -c "import json,sys; print(json.load(open('$d/spec.json')).get('$key', {}).get('mode','ok'))")
    secs=$(python3 -c "import json; print(json.load(open('$d/spec.json')).get('$key', {}).get('sleep', 0))")
    kb=$(python3 -c "import json; print(json.load(open('$d/spec.json')).get('$key', {}).get('kb', 100))")
    if [[ "$spec" == "children" ]]; then
      timeout 120 sleep 120 & echo $! >> "$d/pids"
      ( sleep 120 & echo $! >> "$d/pids"; wait ) &
      sleep 1; echo "$BASHPID" >> "$d/pids"
      sleep 120
    fi
    sleep "$secs"
    rm -f "$d/running.$key"
    if [[ "$spec" == "crash" ]]; then exit 9; fi
    if [[ "$spec" == "failfirst" && ! -f "$d/seen.$key" ]]; then touch "$d/seen.$key"; printf '{"key":"%s","kb":null,"timed_out":true}' "$key" > "$out"; exit 0; fi
    if [[ "$spec" == "null" ]]; then printf '{"key":"%s","kb":null,"timed_out":true}' "$key" > "$out"; exit 0; fi
    printf '{"key":"%s","kb":%s,"path":"%s","elapsed_s":%s,"timed_out":false}' "$key" "$kb" "$path" "$secs" > "$out"
''')


@pytest.fixture
def env(tmp_path):
    d = tmp_path / "fake"
    d.mkdir()
    w = tmp_path / "fake_snapshot.sh"
    w.write_text(FAKE_WORKER)
    w.chmod(w.stat().st_mode | stat.S_IEXEC)
    return {"dir": d, "worker": w, "tmp": tmp_path}


def make_cfg(tmp_path, items):
    cfg = tmp_path / "config.json"
    cfg.write_text(json.dumps({"monitored_dirs": [
        {"key": k, "path": f"/x/{k}", "timeout": t, **({"retry_timeout": r} if r else {})} for k, t, r in items]}))
    return str(cfg)


def run_orch(env, items, spec, workers=2, deadline_in=30, extra=None, carry=None):
    (env["dir"] / "spec.json").write_text(json.dumps(spec))
    cfg = make_cfg(env["tmp"], items)
    e = dict(os.environ, FAKE_DIR=str(env["dir"]))
    cmd = [sys.executable, str(ORCH), "--config", cfg, "--snapshot-script", str(env["worker"]),
           "--workers", str(workers), "--deadline-epoch", str(int(time.time() + deadline_in)),
           "--tmpdir", str(env["tmp"] / "out"), "--meta-out", str(env["tmp"] / "meta.json")] + (extra or [])
    if carry:
        cmd += ["--carry-state", carry]
    t0 = time.time()
    r = subprocess.run(cmd, env=e, capture_output=True, text=True, timeout=120)
    rows = [l.split("\t") for l in r.stdout.splitlines()]
    return r, rows, time.time() - t0


def test_worker_count_policy():
    import snapshot_measure as sm
    assert sm.worker_count(cores=14, load1=7, pressure=1, avail_gb=20) == 4
    assert sm.worker_count(cores=14, load1=70, pressure=1, avail_gb=20) == 2
    assert sm.worker_count(cores=14, load1=7, pressure=4, avail_gb=20) == 1
    assert sm.worker_count(cores=14, load1=7, pressure=1, avail_gb=3) == 1
    assert sm.worker_count(cores=14, load1=7, pressure=1, avail_gb=20, override=99) == 6
    assert sm.worker_count(cores=2, load1=1, pressure=1, avail_gb=20) == 2


def test_never_exceeds_max_concurrency(env):
    items = [(f"k{i}", 10, 0) for i in range(8)]
    spec = {f"k{i}": {"sleep": 0.4} for i in range(8)}
    r, rows, _ = run_orch(env, items, spec, workers=3)
    assert r.returncode == 0, r.stderr
    peak = max(int(x) for x in (env["dir"] / "concurrency.log").read_text().split())
    assert 1 < peak <= 3


def test_merge_order_matches_config_order_regardless_of_completion(env):
    items = [("slow", 50, 0), ("fast", 5, 0), ("mid", 20, 0)]
    spec = {"slow": {"sleep": 0.8, "kb": 1}, "fast": {"sleep": 0, "kb": 2}, "mid": {"sleep": 0.3, "kb": 3}}
    r, rows, _ = run_orch(env, items, spec, workers=3)
    assert [x[0] for x in rows] == ["slow", "fast", "mid"]
    assert [x[1] for x in rows] == ["1", "2", "3"]


def test_disjoint_outputs_one_file_per_key(env):
    items = [("a", 5, 0), ("b", 5, 0), ("c", 5, 0)]
    r, rows, _ = run_orch(env, items, {})
    files = sorted(p.name for p in (env["tmp"] / "out").iterdir())
    assert len(files) == 3 and len(set(files)) == 3


def test_global_budget_respected(env):
    items = [(f"k{i}", 10, 0) for i in range(10)]
    spec = {f"k{i}": {"sleep": 1} for i in range(10)}
    r, rows, elapsed = run_orch(env, items, spec, workers=1, deadline_in=3)
    assert elapsed <= 3 + 6
    done = [x for x in rows if x[1] != ""]
    assert 1 <= len(done) < 10
    assert len(rows) == 10 and all(x[1] == "" for x in rows if x not in done)  # unfinished keys are null, not zero


def test_worker_crash_yields_null_not_zero(env):
    r, rows, _ = run_orch(env, [("boom", 5, 0), ("fine", 5, 0)], {"boom": {"mode": "crash"}})
    d = {x[0]: x[1] for x in rows}
    assert d["boom"] == "" and d["fine"] == "100"


def test_worker_receives_deadline_epoch_and_dua_threads(env):
    run_orch(env, [("a", 5, 0)], {})
    e = (env["dir"] / "env.a").read_text()
    assert "DUA_THREADS=1" in e
    assert any(l.startswith("DISK_MAGICIAN_WORKER_DEADLINE_EPOCH=") and l.split("=")[1].isdigit() for l in e.splitlines())


def test_shortest_timeout_first_order(env):
    items = [("big", 600, 0), ("small", 5, 0), ("medium", 60, 0)]
    run_orch(env, items, {}, workers=1)
    started = [l.split()[2] for l in (env["dir"] / "events.log").read_text().splitlines()]
    assert started == ["small", "medium", "big"]


def test_phase2_retry_only_with_leftover_time_and_no_inflation(env):
    items = [("flaky", 40, 90), ("ok", 5, 0)]
    r, rows, _ = run_orch(env, items, {"flaky": {"mode": "failfirst"}}, workers=1)
    d = {x[0]: x[1] for x in rows}
    assert d["flaky"] == "100"
    events = [l.split() for l in (env["dir"] / "events.log").read_text().splitlines()]
    flaky = [e for e in events if e[2] == "flaky"]
    assert [e[3] for e in flaky] == ["40", "90"]  # retry uses retry_timeout, never 1.5x
    # every key attempted before any retry
    assert [e[2] for e in events].index("ok") < [e[2] for e in events].index("flaky", 1 + [e[2] for e in events].index("flaky"))
    # no leftover time -> no retry
    for p in env["dir"].glob("*"):
        p.unlink()
    r, rows, _ = run_orch(env, items, {"flaky": {"mode": "null"}}, workers=1, deadline_in=1)
    events = [l.split() for l in (env["dir"] / "events.log").read_text().splitlines()] if (env["dir"] / "events.log").exists() else []
    assert len([e for e in events if e[2] == "flaky"]) <= 1


def test_deadline_kills_descendant_tree(env):
    items = [("tree", 5, 0)]
    run_orch(env, items, {"tree": {"mode": "children"}}, workers=1, deadline_in=3)
    time.sleep(0.5)
    pids = [int(x) for x in (env["dir"] / "pids").read_text().split()]
    assert pids
    alive = []
    for p in pids:
        try:
            os.kill(p, 0)
            alive.append(p)
        except ProcessLookupError:
            pass
    for p in alive:  # cleanup before asserting
        os.kill(p, signal.SIGKILL)
    assert not alive, f"surviving descendants: {alive}"


def test_wall_time_model_on_template_config(env):
    template = json.load(open(ROOT / "config.json.template"))
    dirs = template["monitored_dirs"]
    assert len(dirs) >= 40
    cfg = env["tmp"] / "tmpl.json"
    cfg.write_text(json.dumps({"monitored_dirs": dirs}))
    spec = {d["key"]: {"sleep": round(d.get("timeout", 30) * 0.004, 3)} for d in dirs}
    (env["dir"] / "spec.json").write_text(json.dumps(spec))
    e = dict(os.environ, FAKE_DIR=str(env["dir"]))
    deadline = int(time.time() + 40)
    t0 = time.time()
    r = subprocess.run([sys.executable, str(ORCH), "--config", str(cfg), "--snapshot-script", str(env["worker"]),
                        "--workers", "4", "--deadline-epoch", str(deadline), "--tmpdir", str(env["tmp"] / "o2")],
                       env=e, capture_output=True, text=True, timeout=120)
    assert r.returncode == 0, r.stderr
    assert time.time() - t0 <= 40 + 6
    rows = [l.split("\t") for l in r.stdout.splitlines()]
    assert len(rows) == len(dirs) and all(x[1] != "" for x in rows)


@pytest.fixture
def real_env(tmp_path):
    bindir = tmp_path / "bin"
    bindir.mkdir()
    (bindir / "dua").write_text("#!/usr/bin/env bash\nprintf '%s b total\\n' 2097152\n")
    (bindir / "dua").chmod(0o755)
    (tmp_path / "target").mkdir()
    return dict(os.environ, HOME=str(tmp_path), PATH=f"{bindir}:/opt/homebrew/bin:/usr/bin:/bin",
                DISK_MAGICIAN_SNAPSHOT_REENTRY_DEPTH="1", DISK_MAGICIAN_LOAD_FACTOR_OVERRIDE="1"), tmp_path


def test_real_script_worker_not_rejected_by_reentry_guard(real_env):
    e, tmp = real_env
    out = tmp / "w.json"
    r = subprocess.run(["bash", str(SNAP), "--measure-one", "k", str(tmp / "target"), "10", str(out)],
                       env=dict(e, DISK_MAGICIAN_WORKER_DEADLINE_EPOCH=str(int(time.time()) + 30)),
                       capture_output=True, text=True, timeout=60)
    assert r.returncode == 0, r.stderr
    d = json.loads(out.read_text())
    assert d["kb"] == 2048 and d["key"] == "k"


def test_measure_one_works_without_deadline_env_under_set_u(real_env):
    e, tmp = real_env
    out = tmp / "w2.json"
    r = subprocess.run(["bash", str(SNAP), "--measure-one", "k", str(tmp / "target"), "10", str(out)],
                       env=e, capture_output=True, text=True, timeout=60)
    assert r.returncode == 0, r.stderr
    assert json.loads(out.read_text())["kb"] == 2048


def test_nested_full_snapshot_still_rejected(real_env):
    e, tmp = real_env
    r = subprocess.run(["bash", str(SNAP), "--dry-run"], env=e, capture_output=True, text=True, timeout=60)
    assert r.returncode == 75
