#!/usr/bin/env python3
"""diskm admit: decide on zone(df_free - est - margin) under state.lock; one event line per call (spec §7.1)."""
import argparse, fcntl, json, os, signal, subprocess, sys, tempfile, time, uuid, resolve_config
from pathlib import Path
GIB, ZONES, EMERGENCY = 1 << 30, ((100, "GREEN"), (60, "ORANGE"), (30, "RED"), (15, "BLACK")), {"BLACK": 76, "FLOOR": 75}
STAGES = ("observe", "warn", "refuse_red", "refuse_orange")
def d2_approved():  # decision_approved admission_enforcement; an unreadable record is not approved (rc stays 0)
    try: import policy_provenance; return policy_provenance.main("approved", "admission_enforcement") == 0
    except Exception: return False
def zone(free_gb):
    return next((name for floor, name in ZONES if free_gb >= floor), "FLOOR")
def est_gb(text):  # finite and >= 0, else argparse exits 2 before any event is written
    if not 0 <= (gb := float(text)) < float("inf"): raise ValueError(text)
    return gb
def decide(stage, free_gb, est_gb, margin_gb, over_budget, d2):
    z = "FLOOR" if free_gb - est_gb < 15 else zone(free_gb - est_gb - margin_gb)
    if z in EMERGENCY or z == "GREEN" or stage == "observe":
        return z, (EMERGENCY[z] if d2 else 10) if z in EMERGENCY else 0
    return z, 75 if z == "RED" and stage != "warn" or over_budget and stage == "refuse_orange" else 10
def daily_min_used(state, now, used):  # C12 trough baseline: per-day minimum used bytes, last 31 days (observer files rotate out after ~7-11)
    try: m = {k: v for k, v in json.loads((state / "budget.json").read_text())["daily_min_used"].items() if type(v) is int}
    except (OSError, ValueError, KeyError, TypeError, AttributeError): m = {}
    return dict(sorted({**m, (d := time.strftime("%Y-%m-%d", time.localtime(now))): min(used, m.get(d, used))}.items())[-31:])
def state_update(state, keys, events=()):  # under state.lock: reread, merge only our keys, atomic replace
    with open(state / "state.lock", "a") as lock, open(state / "admission" / "events.jsonl", "a") as log:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try: data = json.loads((state / "budget.json").read_text())
        except (OSError, ValueError): data = {}
        (tmp := state / f".budget.{os.getpid()}.tmp").write_text(json.dumps({**data, **keys}))
        os.replace(tmp, state / "budget.json")
        log.writelines(json.dumps(e) + "\n" for e in events)

def next_actuator(eligible, schedule, wall_now, mono_now, deadline, zone_name, reserve=60):
    """Choose one serial C10 slice; callers re-evaluate against the clock after it returns."""
    rows = [dict(row) for row in eligible]
    if not isinstance(schedule, dict): schedule = {"schema": 1, "classes": {}}
    if not isinstance(schedule.get("classes"), dict): schedule["classes"] = {}
    classes = schedule.setdefault("classes", {})
    def count(state, key):
        value = state.get(key, 0)
        return value if isinstance(value, int) and not isinstance(value, bool) and value >= 0 else 0
    def priority(row):
        state = classes.get(row["class"], {})
        if not isinstance(state, dict): state = {}
        deferred, starved = count(state, "deferred_ticks"), count(state, "no_progress_ticks")
        queue = schedule.get("deferred_queue", [])
        queued = isinstance(queue, list) and row["class"] in queue
        black_yield = row.get("df_delta_7d", 0) if zone_name == "BLACK" else 0
        if isinstance(black_yield, bool) or not isinstance(black_yield, (int, float)): black_yield = 0
        last_ran = state.get("last_ran_at", 0)
        if isinstance(last_ran, bool) or not isinstance(last_ran, (int, float)): last_ran = 0
        return (-int(queued), -int(deferred >= 3), -int(starved >= 3), -black_yield, last_ran, row["class"])
    rows.sort(key=priority)
    deferred = []
    pending = len(rows)
    for row in rows:
        name = row["class"]
        state = classes.get(name)
        if not isinstance(state, dict): state = classes[name] = {}
        unit_budget = row.get("unit_budget_s", 20)
        if isinstance(unit_budget, bool) or not isinstance(unit_budget, (int, float)) or unit_budget < 0:
            unit_budget = 20
        min_slice = max(60, unit_budget + 40)
        if count(state, "deferred_ticks") >= 3 or count(state, "no_progress_ticks") >= 3:
            min_slice = 300
        if row.get("kind") == "atomic":
            max_runtime = row.get("max_runtime_s")
            if isinstance(max_runtime, bool) or not isinstance(max_runtime, (int, float)) or max_runtime <= 0:
                deferred.append(name)
                state["deferred_ticks"] = state.get("deferred_ticks", 0) + 1
                pending -= 1
                continue
            min_slice = max(min_slice, max_runtime + 10)
        usable = max(0.0, deadline - mono_now - reserve)
        if usable < min_slice:
            deferred.append(name)
            state["deferred_ticks"] = state.get("deferred_ticks", 0) + 1
            pending -= 1
            continue
        slice_s = min(300.0, max(float(min_slice), usable / max(1, pending)))
        if row.get("kind") == "atomic" and slice_s < row["max_runtime_s"]:
            deferred.append(name)
            state["deferred_ticks"] = state.get("deferred_ticks", 0) + 1
            pending -= 1
            continue
        row["slice_s"] = slice_s
        row["soft_deadline"] = mono_now + slice_s - 40
        row["slice_end"] = mono_now + slice_s
        state["last_ran_at"] = wall_now
        state["deferred_ticks"] = 0
        schedule["updated_at"] = wall_now
        return row, deferred
    schedule["updated_at"] = wall_now
    return None, deferred

def record_actuator_result(schedule, class_name, wall_now, *, completed,
                           df_delta_bytes=None, removed_count=0, hard_stop=False,
                           orphan_survivors=False):
    """Persist per-class progress so three empty ticks earn an exclusive slice."""
    if not isinstance(schedule, dict): schedule = {"schema": 1, "classes": {}}
    classes = schedule.setdefault("classes", {})
    if not isinstance(classes, dict): schedule["classes"] = classes = {}
    state = classes.get(class_name)
    if not isinstance(state, dict): classes[class_name] = state = {}
    old = state.get("no_progress_ticks", 0)
    if isinstance(old, bool) or not isinstance(old, int) or old < 0: old = 0
    progress = (isinstance(df_delta_bytes, int) and not isinstance(df_delta_bytes, bool)
                and df_delta_bytes > 0) or (isinstance(removed_count, int)
                and not isinstance(removed_count, bool) and removed_count > 0)
    state["no_progress_ticks"] = 0 if progress else old + 1
    state["last_finished_at"] = wall_now if completed else state.get("last_finished_at")
    state["last_df_delta_bytes"] = df_delta_bytes
    state["last_removed_count"] = removed_count
    state["last_hard_stop"] = bool(hard_stop)
    state["last_orphan_survivors"] = bool(orphan_survivors)
    state["last_interrupted"] = not completed
    schedule["updated_at"] = wall_now
    return schedule

def save_govern_schedule(path, schedule):
    """Crash-safe replace of the small C10 scheduler checkpoint."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(schedule, stream, separators=(",", ":"))
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(tmp, path)
        dirfd = os.open(path.parent, os.O_RDONLY)
        try: os.fsync(dirfd)
        finally: os.close(dirfd)
    except Exception:
        try: os.unlink(tmp)
        except OSError: pass
        raise

def load_govern_schedule(path):
    try:
        value = json.loads(Path(path).read_text(encoding="utf-8"))
        if isinstance(value, dict) and isinstance(value.get("classes", {}), dict):
            return value
    except (OSError, ValueError, TypeError):
        pass
    return {"schema": 1, "classes": {}}

def _process_group_has_live_members(pgid):
    """Treat zombies as exited; they cannot continue an actuator's work."""
    try:
        result = subprocess.run(["ps", "-Ao", "pgid=,stat="], capture_output=True,
                                text=True, timeout=2, check=True)
        for line in result.stdout.splitlines():
            fields = line.split(None, 1)
            if len(fields) == 2 and fields[0].isdigit() and int(fields[0]) == pgid:
                if "Z" not in fields[1]:
                    return True
        return False
    except (OSError, subprocess.SubprocessError, ValueError):
        try: os.killpg(pgid, 0)
        except ProcessLookupError: return False
        else: return True

def supervise_actuator(command, slice_end, term_grace=10, poll_s=0.1):
    """Run one fixed adapter in its own process group; terminate and reap all children."""
    hard_stop = False
    with tempfile.TemporaryFile() as output_file:
        proc = subprocess.Popen(command, start_new_session=True, stdout=output_file,
                                stderr=subprocess.STDOUT)
        while proc.poll() is None and time.monotonic() < slice_end - term_grace:
            time.sleep(min(poll_s, max(0.0, slice_end - term_grace - time.monotonic())))
        hard_stop = proc.poll() is None
        if hard_stop:
            try: os.killpg(proc.pid, signal.SIGTERM)
            except ProcessLookupError: pass
            term_end = min(slice_end, time.monotonic() + term_grace)
            while proc.poll() is None and time.monotonic() < term_end:
                time.sleep(min(poll_s, max(0.0, term_end - time.monotonic())))
        leader_running = proc.poll() is None
        if leader_running:
            try: os.killpg(proc.pid, signal.SIGKILL)
            except ProcessLookupError: pass
        proc.wait()
        # A wrapper can exit while a child keeps running in the same group.
        # The slice owns the whole group, not merely the direct adapter PID.
        try:
            os.killpg(proc.pid, 0)
            group_exists = True
        except ProcessLookupError:
            group_exists = False
        if group_exists:
            try: os.killpg(proc.pid, signal.SIGTERM)
            except ProcessLookupError: pass
            end = min(slice_end, time.monotonic() + term_grace)
            while _process_group_has_live_members(proc.pid) and time.monotonic() < end:
                time.sleep(min(poll_s, max(0.0, end - time.monotonic())))
            else:
                if _process_group_has_live_members(proc.pid):
                    try: os.killpg(proc.pid, signal.SIGKILL)
                    except ProcessLookupError: pass
        output_file.seek(0)
        output = output_file.read().decode("utf-8", errors="replace")
    survivors = _process_group_has_live_members(proc.pid)
    return {"rc": proc.returncode, "output": output, "hard_stop": hard_stop,
            "orphan_survivors": survivors}
ACTUATORS = {
    "worktree_reap_remove": ("unit", "worktree_reap", ["bash", "worktree_reap.sh", "--mode", "remove"]),
    "worktree_reap_nominate": ("unit", "worktree_reap", ["bash", "worktree_reap.sh", "--mode", "nominate"]),
    "worktree_cleanup": ("unit", "cleanup_worktrees", ["bash", "cleanup_worktrees.sh", "--clean"]),
    "tmp_containers": ("unit", "cleanup_tmp", ["bash", "cleanup_tmp.sh", "--clean"]),
    "tmpdir_scratch": ("unit", "tmp_scratch_sweep", ["bash", "tmp_scratch_sweep.sh", "--clean"]),
    "codex_documents": ("unit", "cleanup_codex_documents", ["bash", "cleanup_codex_documents.sh", "--clean"]),
    "colima": ("atomic", "cleanup_colima", ["bash", "cleanup_colima.sh", "--clean"]),
    "codex_db": ("atomic", "cleanup_codex_db", ["bash", "cleanup_codex_db.sh", "--clean"]),
}
REMOVE_ACTUATORS = {"worktree_reap_remove", "worktree_cleanup", "tmp_containers",
                    "tmpdir_scratch", "codex_documents", "colima", "codex_db"}

def _read_json(path, default=None):
    try:
        value = json.loads(Path(path).read_text(encoding="utf-8"))
        return value if isinstance(value, dict) else (default or {})
    except (OSError, ValueError, TypeError):
        return default or {}

def eligible_actuators(budgets, budget_state, zone_name, now, script_dir=None):
    """Resolve only the fixed C10 adapter table; unknown config values never become commands."""
    classes = budgets.get("classes", {}) if isinstance(budgets, dict) else {}
    measured = budget_state.get("classes", {}) if isinstance(budget_state, dict) else {}
    rows, reasons = [], []
    if not isinstance(classes, dict): return rows, ["budgets_unreadable"]
    for class_name, config in classes.items():
        if not isinstance(config, dict):
            reasons.append(f"actuator_unadapted:{class_name}"); continue
        act = config.get("act")
        if act == "always" and class_name in ACTUATORS:
            # The prior template used `always` to mean the class's fixed adapter.
            act = class_name
        if class_name == "claude_codex_state" and act == "claude_state_cleanup":
            # Only the online Codex DB adapter is in C10's fixed table; Claude state is never dispatched.
            reasons.append("actuator_unadapted:cleanup_claude_state")
            act = "codex_db"
        adapter = ACTUATORS.get(act)
        if adapter is None:
            reasons.append(f"actuator_unadapted:{class_name}:{act}"); continue
        trigger = config.get("trigger")
        stats = measured.get(class_name, {}) if isinstance(measured, dict) else {}
        fresh = isinstance(stats, dict) and isinstance(stats.get("measured_at"), (int, float)) \
                and 0 <= now - stats["measured_at"] <= 3 * 3600
        if trigger == "always":
            eligible = True
        elif trigger == "zone":
            eligible = zone_name in {"RED", "BLACK", "FLOOR"}
        elif trigger == "overage":
            eligible = fresh and isinstance(stats.get("used_gb"), (int, float)) \
                       and isinstance(config.get("budget_gb"), (int, float)) \
                       and stats["used_gb"] > config["budget_gb"]
            if not fresh: reasons.append(f"class_stale:{class_name}")
        else:
            reasons.append(f"trigger_unadapted:{class_name}"); continue
        if not eligible: continue
        kind, job, command = adapter
        unit = config.get("unit_budget_s", 20)
        row = {"class": class_name, "act": act, "kind": kind, "job": job,
               "command": command, "unit_budget_s": unit,
               "df_delta_7d": stats.get("df_delta_7d", 0) if isinstance(stats, dict) else 0}
        if kind == "atomic": row["max_runtime_s"] = config.get("max_runtime_s")
        rows.append(row)
        if class_name == "worktrees":
            cleanup_kind, cleanup_job, cleanup_command = ACTUATORS["worktree_cleanup"]
            rows.append({"class": "worktree_cleanup", "act": "worktree_cleanup", "kind": cleanup_kind,
                         "job": cleanup_job, "command": cleanup_command,
                         "unit_budget_s": config.get("unit_budget_s", 20),
                         "df_delta_7d": row["df_delta_7d"]})
    return rows, reasons

def _c14_complete(script_dir):
    lib = Path(script_dir) / "lib" / "artifact_verdict.sh"
    if not lib.is_file(): return False
    try:
        result = subprocess.run(["bash", "-c", 'source "$1" && artifact_removal_verdict --self-test', "-", str(lib)],
                                capture_output=True, text=True, timeout=60, check=False)
        return result.returncode == 0 and result.stdout.strip() == "ok"
    except (OSError, subprocess.SubprocessError): return False

def _activation_ok(script_dir, decision):
    lib = Path(script_dir) / "lib" / "removal_activation.sh"
    if not lib.is_file(): return False
    try:
        return subprocess.run(["bash", "-c", 'source "$1" && removal_activation_ok "$2"', "-",
                               str(lib), decision], stdout=subprocess.DEVNULL,
                              stderr=subprocess.DEVNULL, timeout=60).returncode == 0
    except (OSError, subprocess.SubprocessError): return False

def _adapter_command(row, script_dir, state, soft_deadline):
    kind, job, args = ACTUATORS[row["act"]]
    executable = Path(script_dir) / args[1]
    if not executable.is_file(): return None
    command = [args[0], str(executable), *args[2:]]
    if kind == "unit":
        command += ["--deadline-at", f"{soft_deadline:.6f}", "--cursor",
                    str(Path(state) / f"cursor_{row['class']}.json")]
    return command

def _receipt_data(state, job):
    try:
        import job_receipt
        return job_receipt.get_last_receipt(job, str(state)) or {}
    except (ImportError, OSError, ValueError, TypeError): return {}

def _write_govern_receipt(state, class_name, result, before, after, actuator_receipt):
    delta = after - before if isinstance(before, int) and isinstance(after, int) else None
    candidates = actuator_receipt.get("candidates", {}) if isinstance(actuator_receipt, dict) else {}
    removed = candidates.get("removed_count") if isinstance(candidates, dict) else None
    deferred = candidates.get("deferred_count", 0) if isinstance(candidates, dict) else 0
    interrupted = candidates.get("interrupted_count", 0) if isinstance(candidates, dict) else 0
    valid_counts = all(isinstance(v, int) and not isinstance(v, bool) and v >= 0
                       for v in (removed, deferred, interrupted))
    rc = result["rc"]
    outcome = "success" if rc == 0 and not result["hard_stop"] and not result["orphan_survivors"] else "partial"
    reason = "actuator_completed"
    if result["hard_stop"]: reason = "hard_stop"
    elif result["orphan_survivors"]: reason = "orphan_survivors"
    elif rc != 0: outcome, reason = "error", f"adapter_rc:{rc}"
    if delta is None or not valid_counts:
        outcome, reason = "error", "adapter_metrics_unavailable"
        removed = removed if isinstance(removed, int) and not isinstance(removed, bool) and removed >= 0 else None
        deferred = deferred if isinstance(deferred, int) and not isinstance(deferred, bool) and deferred >= 0 else 0
        interrupted = interrupted if isinstance(interrupted, int) and not isinstance(interrupted, bool) and interrupted >= 0 else 0
    post = {"df_delta_bytes": delta, "freed_bytes": max(0, delta) if delta is not None else None,
            "free_bytes_before": before, "free_bytes_after": after,
            "hard_stop": result["hard_stop"], "orphan_survivors": result["orphan_survivors"]}
    import job_receipt
    store = job_receipt.JobReceiptStore(state_dir=str(state))
    run_id = store.begin(f"govern_{class_name}", trigger="act")
    store.finish(f"govern_{class_name}", run_id=run_id, outcome=outcome, reason=reason,
                 candidates={"removed_count": removed, "deferred_count": deferred,
                             "interrupted_count": interrupted}, postcondition=post)
    return {"outcome": outcome, "reason": reason, "df_delta_bytes": delta,
            "removed_count": removed, "deferred_count": deferred,
            "interrupted_count": interrupted}

def _write_govern_skip(state, class_name, reason, outcome="skipped_threshold"):
    import job_receipt
    store = job_receipt.JobReceiptStore(state_dir=str(state))
    run_id = store.begin(f"govern_{class_name}", trigger="act")
    store.finish(f"govern_{class_name}", run_id=run_id, outcome=outcome, reason=reason,
                 candidates={"removed_count": 0, "deferred_count": 0,
                             "interrupted_count": 0},
                 postcondition={"df_delta_bytes": 0, "freed_bytes": 0})

def dispatch_actuators(script_dir, state, budgets, budget_state, zone_name, now, deadline, schedule):
    rows, reasons = eligible_actuators(budgets, budget_state, zone_name, now, script_dir)
    for reason in reasons: print(reason)
    if not rows: return
    if not _c14_complete(script_dir):
        print("activation_blocked:c14_incomplete")
        for row in rows: _write_govern_skip(state, row["class"], "activation_blocked:c14_incomplete", "blocked_safety")
        return
    # Task14's prerequisites include wired checkpoint-aware adapters. Unknown or absent adapters fail closed.
    for row in rows:
        command = _adapter_command(row, script_dir, state, 0.0)
        if command is None:
            print(f"actuator_unadapted:{row['class']}:missing_entrypoint")
            _write_govern_skip(state, row["class"], "actuator_unadapted:missing_entrypoint", "blocked_safety")
            return
        if row["act"] == "worktree_reap_remove" and not (
                (Path(state) / "worktree_reap.remove_approved").is_file()
                and _activation_ok(script_dir, "worktree_reap_remove")):
            row["act"] = "worktree_reap_nominate"
    queue = schedule.get("deferred_queue", [])
    if not isinstance(queue, list): queue = []
    pending = list(rows)
    while pending:
        mono_now = time.monotonic()
        selected, deferred = next_actuator(pending, schedule, now, mono_now, deadline, zone_name)
        for class_name in deferred:
            queue = list(dict.fromkeys([*queue, class_name]))
            pending = [r for r in pending if r["class"] != class_name]
            print(f"deferred:{class_name}")
            _write_govern_skip(state, class_name, "deferred:insufficient_slice")
        schedule["deferred_queue"] = queue
        if selected is None:
            save_govern_schedule(Path(state) / "govern_sched.json", schedule)
            break
        row = selected
        queue = [name for name in queue if name != row["class"]]
        schedule["deferred_queue"] = queue
        command = _adapter_command(row, script_dir, state, row["soft_deadline"])
        if command is None:
            print(f"actuator_unadapted:{row['class']}:missing_entrypoint")
            _write_govern_skip(state, row["class"], "actuator_unadapted:missing_entrypoint", "blocked_safety")
            pending = [r for r in pending if r["class"] != row["class"]]
            continue
        if row["act"] == "worktree_cleanup":
            # The governed approval becomes the script's explicit --clean approval only after policy approval.
            if not _activation_ok(script_dir, "worktree_cleanup"):
                pending = [r for r in pending if r["class"] != row["class"]]
                print("activation_blocked:worktree_cleanup")
                _write_govern_skip(state, row["class"], "activation_blocked:worktree_cleanup", "blocked_safety")
                continue
            os.environ["WORKTREE_APPROVED"] = "1"
        before = _df_free_bytes(state)
        prior = _receipt_data(state, row["job"])
        result = supervise_actuator(command, row["slice_end"])
        after = _df_free_bytes(state)
        current = _receipt_data(state, row["job"])
        adapter_receipt = current if current.get("id") != prior.get("id") else {}
        metrics = _write_govern_receipt(state, row["class"], result, before, after, adapter_receipt)
        completed = metrics["interrupted_count"] == 0 and not result["hard_stop"] and not result["orphan_survivors"]
        record_actuator_result(schedule, row["class"], time.time(), completed=completed,
                               df_delta_bytes=metrics["df_delta_bytes"],
                               removed_count=metrics["removed_count"] or 0,
                               hard_stop=result["hard_stop"], orphan_survivors=result["orphan_survivors"])
        if result["output"]: print(result["output"].rstrip())
        print(f"govern_{row['class']}:{metrics['outcome']} df_delta_bytes={metrics['df_delta_bytes']} removed_count={metrics['removed_count']}")
        pending = [r for r in pending if r["class"] != row["class"]]
        save_govern_schedule(Path(state) / "govern_sched.json", schedule)

def _df_free_bytes(path):
    try:
        out = subprocess.run([os.environ.get("DISK_MAGICIAN_DF_BIN", "df"), "-k", str(path)],
                             capture_output=True, text=True, timeout=5, check=True).stdout
        return int(out.splitlines()[-1].split()[3]) * 1024
    except (OSError, ValueError, IndexError, subprocess.SubprocessError): return None

def govern(argv, state):  # observe tick or C10 act scheduler
    p = argparse.ArgumentParser(prog="diskm govern")
    p.add_argument("--mode", choices=["observe", "act"], default="observe")
    args = p.parse_args(argv)
    (state / "admission").mkdir(parents=True, exist_ok=True)
    with open(state / "govern.lock", "a+") as lock:
        try: fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError: return print("skipped_tick_lock") or 0
        lock.truncate(0); lock.write(str(os.getpid())); lock.flush()
        tick_deadline = time.monotonic() + 600
        try:
            out = subprocess.run([os.environ.get("DISK_MAGICIAN_DF_BIN", "df"), "-k", str(Path.home())],
                                 capture_output=True, text=True, timeout=5, check=True).stdout
            now, free = time.time(), int(out.splitlines()[-1].split()[3]) * 1024
            state_update(state, dict(zone=(z := zone(free / GIB)), zone_at=now, free_bytes=free, daily_min_used=daily_min_used(state, now, int(out.splitlines()[-1].split()[2]) * 1024)),
                         [dict(event="floor_breach", at=now, df_free_bytes=free)] if z == "FLOOR" else [])
            if z in EMERGENCY:  # artifact_verdict.sh is absent until Task 11, so this stays blocked
                lib = Path(__file__).resolve().parent / "lib" / "artifact_verdict.sh"
                c14 = lib.is_file() and subprocess.run(["bash", "-c", 'source "$1" && artifact_removal_verdict --self-test', "-", lib],
                                                       capture_output=True, text=True, timeout=60).stdout.strip() == "ok"
                kick = c14 and subprocess.run([os.environ.get("DISK_MAGICIAN_LAUNCHCTL_BIN", "launchctl"), "kickstart",
                                               f"gui/{os.getuid()}/com.jleechanorg.disk-magician-pressure-sweep"], timeout=30).returncode
                state_update(state, {}, [dict(event=(ev := "govern_emergency" if c14 else "kickstart_blocked:c14_missing"),
                                              at=time.time(), zone=z, rc=kick if c14 else None)])
                print(ev)
            try: subprocess.run(["bash", str(Path(__file__).resolve().parent / "birth_audit.sh")], stdout=subprocess.DEVNULL, timeout=150)
            except subprocess.TimeoutExpired: print("birth_audit_timeout", file=sys.stderr)
            if args.mode == "act":
                config_path = resolve_config.resolve()
                if not config_path:
                    print("activation_blocked:config_missing")
                else:
                    config = _read_json(config_path)
                    budget_config = config.get("budgets", {})
                    budget_state = _read_json(state / "budget.json")
                    schedule = load_govern_schedule(state / "govern_sched.json")
                    dispatch_actuators(Path(__file__).resolve().parent, state, budget_config,
                                       budget_state, z, now, tick_deadline, schedule)
        except (OSError, ValueError, IndexError, subprocess.SubprocessError) as e:
            return print(f"govern_error:{type(e).__name__}", file=sys.stderr) or 3
    return print(f"zone={z}") or 0
def admit(a, budgets, state, now, d2):
    try:  # a corrupt or wrong-typed budget.json, or a partial budgets block, degrades to the blind decision
        last, degraded = json.loads((state / "budget.json").read_text()) if (state / "budget.json").is_file() else {}, None
        cls, age, stage, margin = last.get("classes", {}).get(a.cls, {}), now - last.get("zone_at", 0), budgets["enforcement"], budgets["concurrency_margin_gb"]
        over = budgets["classes"][a.cls].get("measure") != "df_delta_only" and now - cls.get("measured_at", 0) <= 3 * 3600 and cls.get("used_gb", 0) > cls.get("budget_gb", 1e9)
        if stage not in STAGES or not all(isinstance(v, (int, float)) for v in (margin, last.get("free_bytes", 0))) \
                or not isinstance(last.get("zone") or "", str): raise TypeError("budget value type")
        try:
            out = subprocess.run([os.environ.get("DISK_MAGICIAN_DF_BIN", "df"), "-k", str(Path.home())],
                                 capture_output=True, text=True, timeout=5, check=True).stdout
            free = int(out.splitlines()[-1].split()[3]) * 1024
        except (OSError, ValueError, IndexError, subprocess.SubprocessError):
            free = last.get("free_bytes") if age <= 900 else None
            degraded = "stale_df" if free is not None else "blind"
    except (OSError, ValueError, KeyError, TypeError, AttributeError):
        last, free, degraded = {}, None, "blind"
    if degraded: print(f"admission_degraded:{degraded}", file=sys.stderr)
    if free is not None:
        z, decision = decide(stage, free / GIB, a.est_gb, margin, over, d2)
    else:  # blind -> 10, unless the last zone within 60 min was BLACK/FLOOR
        z = last.get("zone") if last.get("zone") in EMERGENCY and age <= 3600 else None
        decision = EMERGENCY[z] if z and d2 else 10
    event = dict(event="emergency_probe" if a.probe else "admit", admit_id=str(uuid.uuid4()), at=now, est_bytes=int(a.est_gb * GIB), decision=decision,
                 zone=z, df_free_bytes=free, degraded=degraded, **{"class": a.cls}, **{k: getattr(a, k) for k in
                 ("producer", "source", "dest", "ci_job", "tool_use_id", "compound")})
    try:
        if not a.dry_run:
            with open(state / "admission" / "events.jsonl", "a") as log: log.write(json.dumps(event) + "\n")
    except OSError:
        print("admission_degraded:log", file=sys.stderr)
    print(f"admit_id={event['admit_id']}")
    return decision if d2 else 0
def confirm(state, key, value, now):  # admit_confirm with the admitted dest's dev + inode; rc 2 if it is missing
    hit, log = None, state / "admission" / "events.jsonl"
    try:
        for line in open(log):
            try: e = json.loads(line)
            except ValueError: continue
            if isinstance(e, dict) and e.get("event") == "admit" and e.get(key) == value: hit = e
        st = os.stat(hit["dest"])
    except (OSError, TypeError, KeyError):
        return print(f"admit_confirm: no admitted dest for {key}={value}", file=sys.stderr) or 2
    try:
        with open(log, "a") as f: f.write(json.dumps(dict(event="admit_confirm", admit_id=hit["admit_id"], at=now,
                                   tool_use_id=hit.get("tool_use_id"), dest=hit["dest"], dev=st.st_dev, inode=st.st_ino)) + "\n")
    except OSError:
        print("admission_degraded:log", file=sys.stderr)
    return 0
def main():
    if sys.argv[1:2] == ["--govern"]:
        return govern(sys.argv[2:], Path(os.environ.get("DISK_MAGICIAN_STATE_DIR", Path.home() / ".disk_magician_state")))
    tmpl = json.loads((Path(__file__).resolve().parents[1] / "config.json.template").read_text())["budgets"]
    p, budgets = argparse.ArgumentParser(prog="diskm admit"), json.loads(Path(resolve_config.resolve()).read_text()).get("budgets") or tmpl
    for flag in ("--producer", "--dest", "--source", "--ci-job", "--tool-use-id"): p.add_argument(flag)
    p.add_argument("--class", dest="cls", choices=sorted((budgets if isinstance(budgets, dict) else {}).get("classes") or tmpl["classes"]))
    p.add_argument("--est-gb", type=est_gb); p.add_argument("--compound", action="store_true")
    mode = p.add_mutually_exclusive_group()
    for flag in ("--dry-run", "--probe"): mode.add_argument(flag, action="store_true")
    for flag in ("--confirm", "--confirm-tool-use"): mode.add_argument(flag)
    a, state = p.parse_args(), Path(os.environ.get("DISK_MAGICIAN_STATE_DIR", Path.home() / ".disk_magician_state"))
    if a.confirm is None and a.confirm_tool_use is None and None in (a.cls, a.est_gb):
        p.error("--class and --est-gb are required unless confirming")
    (state / "admission").mkdir(parents=True, exist_ok=True)
    d2 = d2_approved()
    with open(state / "state.lock", "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if a.confirm is not None or a.confirm_tool_use is not None:
            return confirm(state, *(("admit_id", a.confirm) if a.confirm is not None else ("tool_use_id", a.confirm_tool_use)), time.time())
        return admit(a, budgets, state, time.time(), d2)
if __name__ == "__main__":
    sys.exit(main())
