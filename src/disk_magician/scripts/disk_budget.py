#!/usr/bin/env python3
"""diskm admit: decide on zone(df_free - est - margin) under state.lock; one event line per call (spec §7.1)."""
import argparse, fcntl, json, os, signal, subprocess, sys, tempfile, time, uuid, resolve_config
from pathlib import Path
import budget_controls
import budget_history
from c14_probe import _run_bounded
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
def state_update(state, keys, events=()):
    """Merge this owner's fields under the shared lock; malformed state is kept."""
    def mutate(data):
        data.update(keys)
        for event in events:
            budget_history._append_locked(state, event)
    return budget_controls.locked_mutate(state, mutate)


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

def _write_govern_receipt(state, class_name, result, before, after, actuator_receipt, raw_ledger_path=None):
    delta = after - before if isinstance(before, int) and isinstance(after, int) else None
    candidates = actuator_receipt.get("candidates", {}) if isinstance(actuator_receipt, dict) else {}
    removed = candidates.get("removed_count") if isinstance(candidates, dict) else None
    deferred = candidates.get("deferred_count", 0) if isinstance(candidates, dict) else 0
    interrupted = candidates.get("interrupted_count", 0) if isinstance(candidates, dict) else 0
    valid_counts = all(isinstance(v, int) and not isinstance(v, bool) and v >= 0
                       for v in (removed, deferred, interrupted))
    rc = result["rc"]
    allowed_outcomes = {"skipped_lock", "skipped_threshold", "blocked_safety", "error",
                        "timeout", "partial", "success_noop", "success"}
    source_outcome = actuator_receipt.get("outcome") if isinstance(actuator_receipt, dict) else None
    source_reason = actuator_receipt.get("reason") if isinstance(actuator_receipt, dict) else None
    typed_outcome = source_outcome in allowed_outcomes and valid_counts
    if typed_outcome:
        # The adapter is the authority for its semantic result. In particular,
        # a completed safety skip is not a successful cleanup.
        outcome = source_outcome
        reason = source_reason if isinstance(source_reason, str) and source_reason else "adapter_terminal"
    else:
        outcome = "success" if rc == 0 and not result["hard_stop"] and not result["orphan_survivors"] else "partial"
        reason = "actuator_completed"
        if result["hard_stop"]: outcome, reason = "timeout", "hard_stop"
        elif result["orphan_survivors"]: outcome, reason = "partial", "orphan_survivors"
        elif rc != 0: outcome, reason = "error", f"adapter_rc:{rc}"
    if delta is None or not valid_counts:
        # Keep typed safety/error outcomes and their reason visible even if
        # measurement fields are incomplete; success cannot claim valid work.
        if outcome in {"success", "success_noop"}:
            outcome, reason = "error", "adapter_metrics_unavailable"
        removed = removed if isinstance(removed, int) and not isinstance(removed, bool) and removed >= 0 else None
        deferred = deferred if isinstance(deferred, int) and not isinstance(deferred, bool) and deferred >= 0 else 0
        interrupted = interrupted if isinstance(interrupted, int) and not isinstance(interrupted, bool) and interrupted >= 0 else 0
    post = {"df_delta_bytes": delta, "freed_bytes": max(0, delta) if delta is not None else None,
            "free_bytes_before": before, "free_bytes_after": after,
            "hard_stop": result["hard_stop"], "orphan_survivors": result["orphan_survivors"]}
    # The govern wrapper copies the owning adapter's already-folded C14 fields;
    # it must not fold the shared ledger a second time.
    adapter_post = actuator_receipt.get("postcondition", {}) if isinstance(actuator_receipt, dict) else {}
    if isinstance(adapter_post, dict):
        kept = adapter_post.get("c14_kept_bytes")
        if isinstance(kept, dict) and all(
                isinstance(k, str) and k and isinstance(v, int) and not isinstance(v, bool) and v >= 0
                for k, v in kept.items()):
            post["c14_kept_bytes"] = kept
        ledger_status = adapter_post.get("c14_ledger_status")
        if isinstance(ledger_status, str) and ledger_status:
            post["c14_ledger_status"] = ledger_status
    import job_receipt
    # If the owning adapter never wrote a terminal receipt, its scoped ledger
    # still holds real keep rows. Fold it at most once, mark the accounting
    # explicitly incomplete, and never infer a completed removal or success.
    if raw_ledger_path and not any(k in post for k in ("c14_kept_bytes", "c14_ledger_status")):
        folded = job_receipt.fold_c14_ledger(str(raw_ledger_path))
        if folded and folded.get("c14_kept_bytes"):
            post["c14_kept_bytes"] = folded["c14_kept_bytes"]
            post["c14_ledger_status"] = "incomplete"
            post["c14_ledger_source"] = "owner_terminal_absent"
    store = job_receipt.JobReceiptStore(state_dir=str(state))
    run_id = store.begin(f"govern_{class_name}", trigger="act")
    saved_ledger = os.environ.pop(job_receipt.C14_LEDGER_ENV, None)
    saved_owner = os.environ.pop(job_receipt.C14_LEDGER_OWNER_ENV, None)
    try:
        terminal = store.finish(f"govern_{class_name}", run_id=run_id, outcome=outcome, reason=reason,
                     candidates={"removed_count": removed, "deferred_count": deferred,
                                 "interrupted_count": interrupted}, postcondition=post)
    finally:
        if saved_ledger is not None: os.environ[job_receipt.C14_LEDGER_ENV] = saved_ledger
        if saved_owner is not None: os.environ[job_receipt.C14_LEDGER_OWNER_ENV] = saved_owner
    budget_history.record_event(state, "govern_receipt", receipt=terminal)
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
        old_approval = os.environ.get("WORKTREE_APPROVED")
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
        old_trigger = os.environ.get("DISK_MAGICIAN_ACTUATOR_TRIGGER")
        old_ledger = os.environ.get("DISK_MAGICIAN_C14_LEDGER")
        old_owner = os.environ.get("DISK_MAGICIAN_C14_LEDGER_OWNER")
        c14_ledger = Path(state) / f"c14_{row['class']}_{os.getpid()}_{uuid.uuid4().hex}.jsonl"
        if row["kind"] == "atomic":
            os.environ["DISK_MAGICIAN_ACTUATOR_TRIGGER"] = "act"
        # One C14 kept-byte ledger per class run. Only the owning top-level adapter
        # folds it, so nested adapters and the govern receipt cannot double count.
        os.environ["DISK_MAGICIAN_C14_LEDGER"] = str(c14_ledger)
        os.environ["DISK_MAGICIAN_C14_LEDGER_OWNER"] = row["job"]
        try:
            result = supervise_actuator(command, row["slice_end"])
        finally:
            if old_approval is None: os.environ.pop("WORKTREE_APPROVED", None)
            else: os.environ["WORKTREE_APPROVED"] = old_approval
            if old_trigger is None: os.environ.pop("DISK_MAGICIAN_ACTUATOR_TRIGGER", None)
            else: os.environ["DISK_MAGICIAN_ACTUATOR_TRIGGER"] = old_trigger
            if old_ledger is None: os.environ.pop("DISK_MAGICIAN_C14_LEDGER", None)
            else: os.environ["DISK_MAGICIAN_C14_LEDGER"] = old_ledger
            if old_owner is None: os.environ.pop("DISK_MAGICIAN_C14_LEDGER_OWNER", None)
            else: os.environ["DISK_MAGICIAN_C14_LEDGER_OWNER"] = old_owner
        after = _df_free_bytes(state)
        current = _receipt_data(state, row["job"])
        adapter_receipt = current if current.get("id") != prior.get("id") else {}
        # No owning terminal receipt -> fold the raw scoped ledger once into the
        # govern receipt (explicit incomplete quality). A terminal-presence means
        # the owner already folded it, so pass nothing (no double count).
        metrics = _write_govern_receipt(state, row["class"], result, before, after, adapter_receipt,
                                        c14_ledger if not adapter_receipt else None)
        # Only release the ephemeral ledger after the terminal govern receipt is
        # persisted; a raise above leaves the raw ledger in place for recovery.
        try: c14_ledger.unlink()
        except OSError: pass
        completed = (metrics["outcome"] in {"success", "success_noop"}
                     and metrics["deferred_count"] == 0
                     and metrics["interrupted_count"] == 0
                     and not result["hard_stop"] and not result["orphan_survivors"])
        if metrics["deferred_count"] > 0 or metrics["interrupted_count"] > 0:
            queue = list(dict.fromkeys([*queue, row["class"]]))
        schedule["deferred_queue"] = queue
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

def _measure_lock(state):
    """Non-blocking daily-measure lock; None means the daily job owns measurement."""
    fd = -1
    try:
        fd = os.open(Path(state) / "measure.lock", os.O_RDWR | os.O_CREAT, 0o600)
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return fd
    except OSError:
        if fd >= 0: os.close(fd)
        return None

def _measure_unlock(fd):
    try:
        fcntl.flock(fd, fcntl.LOCK_UN)
    finally:
        os.close(fd)

# Fixed class -> roots table (spec 7.2 class table). Read-only measurement only;
# no actuator is invoked from here. DISK_MAGICIAN_MEASURE_ROOTS_JSON overrides
# the whole table for hermetic tests.
def class_measure_roots(class_name):
    override = os.environ.get("DISK_MAGICIAN_MEASURE_ROOTS_JSON")
    if override:
        try:
            rows = json.loads(override).get(class_name)
            return [str(Path(p).expanduser()) for p in rows] if isinstance(rows, list) else []
        except (ValueError, TypeError, AttributeError):
            return []
    home = Path(os.environ.get("HOME") or str(Path.home()))
    table = {
        "worktrees": [home / ".worktrees"],
        "tmp_containers": [Path(os.environ.get("DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE", "/private/tmp"))],
        "tmpdir_scratch": [Path(os.environ.get("TMPDIR", "/tmp"))],
        "codex_documents": [home / "Documents" / "Codex"],
        "claude_codex_state": [home / ".claude" / "state", home / ".codex"],
        "colima": [home / ".colima" / "_lima"],
    }
    return [str(p) for p in table.get(class_name, [])]

def _run_group(argv, timeout, stdout=None):
    """Use the shared process-group deadline owner for measurement subprocesses."""
    try:
        result = _run_bounded(argv, cap=max(0.01, timeout))
    except OSError:
        return 127, "", ""
    if result is None:
        return -9, "", ""
    rc, raw = result
    out = raw.decode(errors="replace")
    if stdout is not None:
        stdout.write(out)
    return rc, out, ""

def _du_kb(paths, timeout, deadline=None):
    """Sum one `du -sk` over every existing root (one invocation, one deadline).

    A single invocation shares one timeout and lets du dedup cross-root hardlinks.
    None on timeout/error or when no root exists.
    """
    existing = [p for p in paths if os.path.isdir(p)]
    if not existing:
        return None
    if deadline is not None:
        timeout = min(timeout, deadline - time.monotonic())
    if timeout <= 0:
        return None
    rc, out, _ = _run_group([os.environ.get("DISK_MAGICIAN_DU_BIN", "du"), "-sk", *existing], timeout)
    if rc != 0:
        return None
    total = 0
    for line in out.splitlines():
        parts = line.split()
        if parts and parts[0].isdigit():
            total += int(parts[0])
    return total

def merge_classes(state, updates, events=()):
    """Merge only measured class fields under the same state lock as controls."""
    def mutate(data):
        classes = data.setdefault("classes", {})
        if not isinstance(classes, dict):
            raise ValueError("malformed class measurements")
        for name, values in updates.items():
            current = classes.get(name, {})
            if not isinstance(current, dict):
                raise ValueError("malformed class measurement")
            classes[name] = {**current, **values}
        for event in events:
            budget_history._append_locked(state, event)
    return budget_controls.locked_mutate(state, mutate)

OBSERVER_FRESH_S = 900

def _observer_colima(state, now):
    """Latest canonical observer record's ``colima.root_allocated_kb`` (no du).

    Reuses disk_observer.read_records so the nested ``colima`` object is parsed by
    the producer's own parser. A row older than ``OBSERVER_FRESH_S`` is returned
    with ``fresh=False`` -- never recorded as if measured now.
    """
    paths = [Path(state) / name for name in
             ("disk_observer.jsonl", "disk_observer.jsonl.1", "disk_observer.jsonl.2")]
    records = []
    try:
        import disk_observer
        records = [r for r in disk_observer.read_records(paths) if isinstance(r, dict)]
    except (ImportError, OSError, ValueError, TypeError):
        records = []
    for row in reversed(records):
        colima = row.get("colima")
        kb = colima.get("root_allocated_kb") if isinstance(colima, dict) else None
        if not isinstance(kb, (int, float)) or isinstance(kb, bool) or kb < 0:
            kb = row.get("colima.root_allocated_kb")
        if not isinstance(kb, (int, float)) or isinstance(kb, bool) or kb < 0:
            continue
        epoch = row.get("epoch")
        if isinstance(epoch, bool) or not isinstance(epoch, (int, float)):
            continue
        return {"kb": kb, "observed_at": epoch, "fresh": 0 <= now - epoch <= OBSERVER_FRESH_S}
    return None

def _rotation_stamp(stats):
    """Round-robin key: always the last *attempt*, success or timeout.

    Ordering on measured_at alone starves a class that keeps timing out, because
    its measured_at never advances and it is chosen every tick.
    """
    for field in ("attempted_at", "measured_at"):
        value = stats.get(field)
        if isinstance(value, (int, float)) and not isinstance(value, bool):
            return value
    return 0

def measure_tick_class(state, budgets, now, deadline):
    """Measure exactly one du class (round-robin by oldest attempt).

    A class with no prior stats is still a candidate, so a fresh budget
    bootstraps every configured class before the nightly job runs. A timeout
    advances ``attempted_at`` without touching ``measured_at``/``used_gb``.
    """
    classes = budgets.get("classes", {}) if isinstance(budgets, dict) else {}
    data = _read_json(Path(state) / "budget.json")
    measured = data.get("classes") if isinstance(data.get("classes"), dict) else {}
    candidates = []
    for name, config in classes.items():
        if not isinstance(config, dict) or config.get("measure") != "du":
            continue
        roots = class_measure_roots(name)
        if not any(os.path.isdir(p) for p in roots):
            continue
        stats = measured.get(name) if isinstance(measured.get(name), dict) else {}
        candidates.append((_rotation_stamp(stats), name, stats, roots))
    if not candidates:
        return None
    _, name, stats, roots = min(candidates, key=lambda row: (row[0], row[1]))
    lock = _measure_lock(state)
    if lock is None:
        print("skipped_measure_lock")
        return None
    try:
        timeout = 60.0
        if deadline is not None:
            timeout = max(1.0, min(60.0, deadline - time.monotonic() - 40))
        if deadline is not None and time.monotonic() >= deadline:
            return None
        kb = _du_kb(roots, timeout, deadline=deadline)
        if kb is None:
            base = stats.get("measured_at") if isinstance(stats.get("measured_at"), (int, float)) \
                and not isinstance(stats.get("measured_at"), bool) else now
            merge_classes(state, {name: {"attempted_at": now, "stale_s": int(max(0, now - base))}})
        else:
            merge_classes(state, {name: {"used_gb": kb / 1024.0 / 1024.0, "measured_at": now,
                                         "attempted_at": now, "stale_s": 0, "carried": False}})
        return name
    finally:
        _measure_unlock(lock)

def observer_refresh(state, budgets, now):
    """Step 4 observer classes (spec 7.1): colima root_allocated_kb, no du.

    Only a fresh observer row refreshes ``measured_at``; a stale row grows
    ``stale_s`` and advances the rotation instead of pretending it is now.
    """
    classes = budgets.get("classes", {}) if isinstance(budgets, dict) else {}
    prior = _read_json(Path(state) / "budget.json").get("classes")
    prior = prior if isinstance(prior, dict) else {}
    updates = {}
    for name, config in classes.items():
        if not isinstance(config, dict) or config.get("measure") != "observer":
            continue
        stats = prior.get(name) if isinstance(prior.get(name), dict) else {}
        seen = _observer_colima(state, now)
        base = stats.get("measured_at") if isinstance(stats.get("measured_at"), (int, float)) \
            and not isinstance(stats.get("measured_at"), bool) else None
        if seen is not None and seen["fresh"]:
            updates[name] = {"used_gb": seen["kb"] / 1024.0 / 1024.0,
                             "measured_at": seen["observed_at"], "attempted_at": now,
                             "stale_s": 0, "carried": False}
        elif base is not None:
            # A stale observer row must not invent a first observation; only grow
            # the age of one already recorded.
            updates[name] = {"attempted_at": now, "stale_s": int(max(0, now - base))}
    if updates:
        merge_classes(state, updates)

def daily_measure(state, budgets, tick_seconds=900):
    """03:00 job: measure every class once; timeouts carried; one merge at the end.

    du classes get 60 s, df_delta_only classes get the plan's 120 s accounting
    du (never a fabricated measured_at with no measurement).
    """
    state = Path(state)
    deadline = time.monotonic() + tick_seconds
    lock = _measure_lock(state)
    if lock is None:
        print("skipped_measure_lock")
        return 3  # deferred, not completed: govern must retain its pending request
    updates, events, snapshot, carried = {}, [], {}, []
    try:
        data = _read_json(state / "budget.json")
        prior = data.get("classes") if isinstance(data.get("classes"), dict) else {}
        classes = budgets.get("classes", {}) if isinstance(budgets, dict) else {}
        for name, config in classes.items():
            if not isinstance(config, dict):
                continue
            now = time.time()
            stats = prior.get(name) if isinstance(prior.get(name), dict) else {}
            base = stats.get("measured_at") if isinstance(stats.get("measured_at"), (int, float)) \
                and not isinstance(stats.get("measured_at"), bool) else now
            carry = {"attempted_at": now, "carried": True, "stale_s": int(max(0, now - base))}
            if config.get("measure") == "observer":
                seen = _observer_colima(state, now)
                if seen is not None and seen["fresh"]:
                    updates[name] = {"used_gb": seen["kb"] / 1024.0 / 1024.0, "measured_at": seen["observed_at"],
                                     "attempted_at": now, "stale_s": 0, "carried": False}
                    snapshot[name] = {"used_gb": updates[name]["used_gb"]}
                else:
                    updates[name] = carry
                    carried.append(name)
                continue
            df_delta_only = config.get("measure") == "df_delta_only"
            budget = 120.0 if df_delta_only else 60.0
            remaining = deadline - time.monotonic()
            if remaining <= 1:
                updates[name] = carry
                carried.append(name)
                events.append(dict(event="daily_measure_carried", at=now, **{"class": name}))
                continue
            timeout = max(1.0, min(budget, remaining - 40))
            kb = _du_kb(class_measure_roots(name), timeout, deadline=deadline)
            if kb is None:
                updates[name] = carry
                carried.append(name)
                events.append(dict(event="daily_measure_carried", at=now, **{"class": name}))
            else:
                updates[name] = {"used_gb": kb / 1024.0 / 1024.0, "measured_at": now,
                                 "attempted_at": now, "stale_s": 0, "carried": False}
                snapshot[name] = {"used_gb": updates[name]["used_gb"]}
        pause = os.environ.get("DISK_MAGICIAN_TEST_PAUSE_BEFORE_MERGE")
        if pause:
            ready = Path(pause) / "ready"
            release = Path(pause) / "release"
            try:
                ready.parent.mkdir(parents=True, exist_ok=True)
                ready.write_text("")
                wait_end = time.monotonic() + 60
                while not release.exists() and time.monotonic() < wait_end:
                    time.sleep(0.02)
            except OSError:
                pass
        merge_classes(state, updates, events)
        # A failed snapshot write must propagate so govern retains the request.
        budget_history.record_measurement(state, now=time.time(), classes=snapshot, carried=carried)
        try:
            state_update(state, {"parked_measurement": budget_history.measure_parked(state, deadline)})
        except (OSError, ValueError, TypeError):
            pass
    finally:
        _measure_unlock(lock)
    return 0

def _run_reconcile(state, deadline_mono):
    """Step 2 C14 reconciliation under one bounded monotonic deadline."""
    script = Path(__file__).resolve().parent / "quarantine_rename.py"
    if not script.is_file():
        return "reconcile_unavailable"
    remaining = deadline_mono - time.monotonic()
    if remaining <= 0:
        print("reconcile_deferred:deadline")
        return None
    command = ["python3", str(script), "reconcile", "--deadline-at", f"{deadline_mono:.6f}",
               "--cursor", str(Path(state) / "reconcile_cursor.json")]
    rc, out, _ = _run_group(command, remaining)
    if rc == -9:
        print("reconcile_timeout")
        return None
    if out:
        print(out.rstrip())
    return rc

BIRTH_AUDIT_PERSIST_RESERVE_S = 10.0  # time to publish estimates after du stops

def _run_birth_audit(state, deadline_mono):
    """Stop du early enough to persist births before the outer deadline."""
    script = Path(__file__).resolve().parent / "birth_audit.sh"
    if not script.is_file():
        return None
    remaining = deadline_mono - time.monotonic()
    if remaining <= 0:
        print("birth_audit_timeout", file=sys.stderr)
        return None
    budget_s = max(0.0, remaining - BIRTH_AUDIT_PERSIST_RESERVE_S)
    rc, _, _ = _run_group(["bash", str(script), "--budget-seconds", f"{budget_s:.6f}"], remaining)
    if rc == -9:
        print("birth_audit_timeout", file=sys.stderr)
    return rc

def _record_govern_tick(state, budgets, now, deadline, zone_name):
    """Hand one tick to the budget_history producer (its fields, not ours)."""
    classes = budgets.get("classes", {}) if isinstance(budgets, dict) else {}
    measured = _read_json(Path(state) / "budget.json").get("classes")
    measured = measured if isinstance(measured, dict) else {}
    fresh = {}
    for name, config in classes.items():
        if not isinstance(config, dict) or config.get("measure") != "du":
            continue
        stats = measured.get(name) if isinstance(measured.get(name), dict) else {}
        stamp = stats.get("measured_at")
        fresh[name] = (isinstance(stamp, (int, float)) and not isinstance(stamp, bool)
                       and 0 <= now - stamp <= 3 * 3600 and stats.get("carried") is not True)
    try:
        fleet, _ = budget_history.collect_fleet_health(state, now, deadline_at=deadline)
        budget_history.record_tick(state, now=now, classes_fresh=fresh, fleet_status=fleet, zone=zone_name,
                             colima_status=budget_history.collect_colima_status(deadline))
    except (OSError, ValueError, TypeError):
        pass

DAILY_LOCK_WAIT_S = 600.0  # ordinary ticks have a 540 s budget and run every 600 s

def _consume_daily_request(state, budgets, tick_seconds, zone_name=None):
    """Serve pending work under govern.lock, without borrowing a tick's deadline."""
    pending = _read_json(state / "budget.json").get("daily_measure_pending")
    if not pending:
        return 0
    if zone_name in EMERGENCY or tick_seconds <= 1:
        reason = "emergency" if zone_name in EMERGENCY else "deadline"
        return print(f"daily_measure_deferred:{reason}", file=sys.stderr) or 3
    try:
        rc = daily_measure(state, budgets, tick_seconds)
        if rc == 0:
            def complete(data):
                # A newer request may arrive while du runs. Clear only the
                # token this snapshot served, under the existing state.lock.
                if data.get("daily_measure_pending") == pending:
                    data.pop("daily_measure_pending")
            budget_controls.locked_mutate(state, complete)
        return rc
    except (OSError, ValueError, TypeError, budget_controls.MalformedState) as e:
        return print(f"govern_error:{type(e).__name__}", file=sys.stderr) or 3

def govern(argv, state):  # observe tick, daily measure, or C10 act scheduler
    p = argparse.ArgumentParser(prog="diskm govern")
    p.add_argument("--mode", choices=["observe", "act"], default="observe")
    p.add_argument("--daily-measure", action="store_true")
    p.add_argument("--tick-seconds", type=est_gb, default=540.0)
    args = p.parse_args(argv)
    state = Path(state)
    (state / "admission").mkdir(parents=True, exist_ok=True)
    budgets = {}
    try:
        config_path = resolve_config.resolve()
        if config_path:
            budgets = _read_json(config_path).get("budgets", {})
            if not isinstance(budgets, dict):
                budgets = {}
    except (OSError, ValueError, TypeError):
        budgets = {}
    if args.daily_measure:
        if args.tick_seconds == 540.0:
            args.tick_seconds = 900.0
        # launchd's 03:00 calendar job does not retry a skipped invocation. Save
        # the request before waiting so a timeout or process restart cannot lose
        # it; the existing 600 s govern job will service it under the same lock.
        try:
            state_update(state, {"daily_measure_pending": uuid.uuid4().hex})
        except (OSError, ValueError, TypeError, budget_controls.MalformedState) as e:
            return print(f"govern_error:{type(e).__name__}", file=sys.stderr) or 3
    with open(state / "govern.lock", "a+") as lock:
        wait_until = time.monotonic() + min(DAILY_LOCK_WAIT_S, args.tick_seconds)
        while True:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if not args.daily_measure:
                    return print("skipped_tick_lock") or 0
                remaining = wait_until - time.monotonic()
                if remaining <= 0:
                    return print("daily_measure_deferred:govern_lock", file=sys.stderr) or 3
                time.sleep(min(0.05, remaining))
            except OSError as e:
                return print(f"govern_error:{type(e).__name__}", file=sys.stderr) or 3
        lock.truncate(0); lock.write(str(os.getpid())); lock.flush()
        if args.daily_measure:
            return _consume_daily_request(state, budgets, args.tick_seconds)
        tick_start = time.monotonic()
        tick_deadline = tick_start + max(1.0, args.tick_seconds)
        try:
            out = subprocess.run([os.environ.get("DISK_MAGICIAN_DF_BIN", "df"), "-k", str(Path.home())],
                                 capture_output=True, text=True, timeout=5, check=True).stdout
            now, free = time.time(), int(out.splitlines()[-1].split()[3]) * 1024
            state_update(state, dict(zone=(z := zone(free / GIB)), zone_at=now, free_bytes=free, daily_min_used=daily_min_used(state, now, int(out.splitlines()[-1].split()[2]) * 1024)),
                         [dict(event="floor_breach", at=now, df_free_bytes=free)] if z == "FLOOR" else [])
            if z in EMERGENCY:  # artifact_verdict.sh is absent until Task 11, so this stays blocked
                lib = Path(__file__).resolve().parent / "lib" / "artifact_verdict.sh"
                cap = min(60.0, max(0.0, tick_deadline - time.monotonic()))
                check_rc, check_out, _ = _run_group(["bash", "-c", 'source "$1" && artifact_removal_verdict --self-test', "-", str(lib)], cap) if lib.is_file() and cap > 0 else (1, "", "")
                c14 = check_rc == 0 and check_out.strip() == "ok"
                kick = None
                cap = min(30.0, max(0.0, tick_deadline - time.monotonic()))
                if c14 and cap > 0:
                    kick, _, _ = _run_group([os.environ.get("DISK_MAGICIAN_LAUNCHCTL_BIN", "launchctl"), "kickstart",
                                            f"gui/{os.getuid()}/com.jleechanorg.disk-magician-pressure-sweep"], cap)
                state_update(state, {}, [dict(event=(ev := "govern_emergency" if c14 and kick == 0 else "kickstart_blocked:c14_missing" if not c14 else "kickstart_blocked:launchctl"),
                                              at=time.time(), zone=z, rc=kick if c14 else None)])
                print(ev)
            # Step 2: bounded quarantine reconciliation before du/audit (60s in
            # BLACK/FLOOR, else min(120, D - now - 300)); never past D.
            recon_budget = 60.0 if z in EMERGENCY else min(120.0, max(0.0, tick_deadline - time.monotonic() - 300.0))
            _run_reconcile(state, min(time.monotonic() + recon_budget, tick_deadline))
            if z not in EMERGENCY:
                # Steps 3-5: one du class, observer refresh, birth audit (120 s
                # cap, 60 s receipt reserve), every phase inside D.
                measure_tick_class(state, budgets, now, tick_deadline)
                observer_refresh(state, budgets, now)
                audit_budget = max(0.0, min(120.0, tick_deadline - time.monotonic() - 60.0))
                if audit_budget > 0:
                    _run_birth_audit(state, time.monotonic() + audit_budget)
            if args.mode == "act":
                if not budgets:
                    print("activation_blocked:config_missing")
                else:
                    budget_state = _read_json(state / "budget.json")
                    schedule = load_govern_schedule(state / "govern_sched.json")
                    dispatch_actuators(Path(__file__).resolve().parent, state, budgets,
                                       budget_state, z, now, tick_deadline, schedule)
            _record_govern_tick(state, budgets, now, tick_deadline, z)
            # Retrying daily accounting never preempts ordinary df/emergency,
            # reconciliation, actuation or tick history. Defer if the normal
            # work used the deadline, or if emergency pressure forbids scans.
            daily_rc = _consume_daily_request(state, budgets, tick_deadline - time.monotonic(), z)
        except (OSError, ValueError, IndexError, subprocess.SubprocessError) as e:
            return print(f"govern_error:{type(e).__name__}", file=sys.stderr) or 3
    return print(f"zone={z}") or daily_rc
def admit(a, budgets, state, now, d2):
    estimate_degraded = None
    if a.est_gb is None:
        a.est_gb = budget_controls.effective_estimate(state, a.producer)
        if a.est_gb is None:
            a.est_gb, estimate_degraded = 0.0, "producer_estimate"
    try:  # a corrupt or wrong-typed budget.json, or a partial budgets block, degrades to the blind decision
        last, degraded = json.loads((state / "budget.json").read_text()) if (state / "budget.json").is_file() else {}, estimate_degraded
        cls, age = last.get("classes", {}).get(a.cls, {}), now - last.get("zone_at", 0)
        stage = budget_controls.effective_stage(last, budgets, strict=True)
        margin = budget_controls.effective_margin(last, budgets, strict=True)
        over = budgets["classes"][a.cls].get("measure") != "df_delta_only" and now - cls.get("measured_at", 0) <= 3 * 3600 and cls.get("used_gb", 0) > budgets["classes"][a.cls].get("budget_gb", 1e9)
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
    if estimate_degraded and z not in EMERGENCY:
        decision = 10
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
    if a.confirm is None and a.confirm_tool_use is None and (a.cls is None or (a.est_gb is None and not a.producer)):
        p.error("--class and either --est-gb or --producer are required unless confirming")
    (state / "admission").mkdir(parents=True, exist_ok=True)
    d2 = d2_approved()
    with open(state / "state.lock", "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if a.confirm is not None or a.confirm_tool_use is not None:
            return confirm(state, *(("admit_id", a.confirm) if a.confirm is not None else ("tool_use_id", a.confirm_tool_use)), time.time())
        return admit(a, budgets, state, time.time(), d2)
if __name__ == "__main__":
    sys.exit(main())
