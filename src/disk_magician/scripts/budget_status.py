#!/usr/bin/env python3
"""diskm budget status: governor alerts from budget.json, the admission event log and observer df samples (plan Task 10)."""
import datetime, json, os, sys, time
from pathlib import Path
import disk_observer
GIB, DAY = 1 << 30, 86400
RUNBOOK = ("  runbook: identify the producer (top growing roots: admission/events.jsonl, birth audit, observer)", "  runbook: ask the user before pausing CI runners (launchctl bootout gui/$UID/<ezgha label>)",
           "  runbook: colima stop && colima start, then colima ssh -- sudo fstrim -av", "  runbook: list parked worktrees; never hand-rm")
def parse(text):  # one JSON value, or None when malformed
    try: return json.loads(text)
    except ValueError: return None
def samples(state):  # (epoch, used B, free B) from disk_observer.jsonl{,.1,.2}
    recs = disk_observer.read_records([state / f"disk_observer.jsonl{s}" for s in (".2", ".1", "")])
    return [(r["epoch"], d["used_kb"] * 1024, d["available_kb"] * 1024) for r in recs
            if isinstance(r.get("epoch"), (int, float)) and isinstance(d := r.get("host_disk"), dict)
            and all(isinstance(d.get(k), (int, float)) for k in ("used_kb", "available_kb"))]
def events(state, lo, hi):
    try: lines = (state / "admission" / "events.jsonl").read_text().splitlines()
    except OSError: return []
    return [e for e in map(parse, lines) if isinstance(e, dict) and isinstance(e.get("at"), (int, float)) and lo <= e["at"] <= hi]
def window_max(points, width=600):  # max sum of (t, bytes) inside any [t, t + width) window
    from budget_acceptance import _window_max
    return _window_max(points, width)
def daily_mins(budget, now, n):  # C12: govern's per-day minimum used bytes (budget.json daily_min_used); observer files rotate out after ~7-11 days
    m = budget.get("daily_min_used") if isinstance(budget, dict) else None
    return [v for d in range(n) if isinstance(m, dict) and type(v := m.get(time.strftime("%Y-%m-%d", time.localtime(now - d * DAY)))) is int]
def raised(lines): return any(line.startswith("ALERT:") for line in lines)
def _int_or_none(value): return value if isinstance(value, int) and not isinstance(value, bool) else None
BASELINE_SCHEMA_VERSION = 1
C14_LEDGER_STATUSES = ("ok", "incomplete", "error")
def _valid_utc(value):  # true only for a timezone-aware UTC ISO-8601 timestamp
    if not isinstance(value, str) or not value: return False
    ts = value[:-1] + "+00:00" if value.endswith("Z") else value
    try: dt = datetime.datetime.fromisoformat(ts)
    except ValueError: return False
    return dt.tzinfo is not None and dt.utcoffset() == datetime.timedelta(0)
def _nonempty_source(value): return value.strip() if isinstance(value, str) and value.strip() else None
def load_baseline(state):  # strict task0_baseline.json reader; nothing defaulted
    """Validate `$STATE/task0_baseline.json` before any byte is displayed.

    Returns {"status": missing|malformed|ok, "captured_at", "source", "classes"}.
    A bad header fails the whole file to `malformed`; a bad class row fails only
    that class to `malformed`. Valid rows keep status complete|incomplete.
    """
    try: data = json.loads((state / "task0_baseline.json").read_text())
    except OSError: return {"status": "missing", "captured_at": None, "source": None, "classes": {}}
    except ValueError: return {"status": "malformed", "captured_at": None, "source": None, "classes": {}}
    if not isinstance(data, dict): return {"status": "malformed", "captured_at": None, "source": None, "classes": {}}
    captured = data.get("captured_at") if _valid_utc(data.get("captured_at")) else None
    source = _nonempty_source(data.get("source"))
    classes = data.get("classes")
    if (type(data.get("schema_version")) is not int or data.get("schema_version") != BASELINE_SCHEMA_VERSION
            or not _valid_utc(data.get("captured_at")) or source is None or not isinstance(classes, dict)):
        return {"status": "malformed", "captured_at": captured, "source": source, "classes": {}}
    rows = {}
    for name, row in classes.items():
        if not isinstance(name, str) or not name or not isinstance(row, dict): continue
        wdb, row_source, row_status = row.get("would_delete_bytes"), _nonempty_source(row.get("source")), row.get("status")
        if row_source is None or row_status not in ("complete", "incomplete") \
                or not (wdb is None or (type(wdb) is int and wdb >= 0)):
            rows[name] = {"status": "malformed", "bytes": None, "source": None}; continue
        if wdb is None or row_status == "incomplete": rows[name] = {"status": "incomplete", "bytes": None, "source": row_source}
        else: rows[name] = {"status": "complete", "bytes": wdb, "source": row_source}
    return {"status": "ok", "captured_at": data["captured_at"], "source": source, "classes": rows}
def _baseline_fields(base, name):  # baseline_bytes plus explicit quality status
    top = (f" baseline_captured_at={base['captured_at']}" if base.get("captured_at") else "") \
          + (f" baseline_source={json.dumps(base['source'])}" if base.get("source") else "")
    if base["status"] == "missing": return "baseline_bytes=unknown baseline_status=missing"
    if base["status"] == "malformed": return f"baseline_bytes=unknown baseline_status=malformed{top}"
    row = base["classes"].get(name)
    if row is None: return f"baseline_bytes=unknown baseline_status=missing{top}"
    if row["status"] == "malformed": return f"baseline_bytes=unknown baseline_status=malformed{top}"
    suffix = f" baseline_class_source={json.dumps(row['source'])}" if row.get("source") else ""
    if row["status"] == "complete" and row["bytes"] is not None:
        return f"baseline_bytes={row['bytes']} baseline_status=complete{top}{suffix}"
    return f"baseline_bytes=unknown baseline_status=incomplete{top}{suffix}"
def _c14_fields(post):  # explicit invalid/incomplete instead of a silent none/zero
    status = post.get("c14_ledger_status")
    ledger_status = "absent" if status is None else (status if isinstance(status, str) and status in C14_LEDGER_STATUSES else "invalid")
    kept = post.get("c14_kept_bytes")
    if kept is None: kept_str = "absent"
    elif not isinstance(kept, dict): kept_str = "invalid"
    elif any(not (isinstance(k, str) and k and type(v) is int and v >= 0) for k, v in kept.items()): kept_str = "invalid"
    elif ledger_status == "error": kept_str = "unknown"
    elif not kept: kept_str = "none" if ledger_status == "ok" else "unknown"
    else:
        values = ",".join(f"{k}:{kept[k]}" for k in sorted(kept))
        kept_str = f"partial({values})" if ledger_status == "incomplete" else values
    return ledger_status, kept_str
def _receipt_fields(rec):  # receipt metric tail shared by class and wrapper rows
    if not rec:
        return "receipt=missing deleted_bytes=unknown df_delta_bytes=unknown"
    post = rec.get("postcondition") if isinstance(rec.get("postcondition"), dict) else {}
    cand = rec.get("candidates") if isinstance(rec.get("candidates"), dict) else {}
    df, freed, removed = _int_or_none(post.get("df_delta_bytes")), _int_or_none(post.get("freed_bytes")), _int_or_none(cand.get("removed_count"))
    deleted = _int_or_none(post.get("deleted_bytes"))
    ledger_status, kept_str = _c14_fields(post)
    return (f"receipt={rec.get('outcome', 'unknown')}"
            f" removed_count={removed if removed is not None else 'unknown'}"
            f" deleted_bytes={deleted if deleted is not None else 'unknown'}"
            f" df_delta_bytes={df if df is not None else 'unknown'}"
            f" freed_bytes_df_based={freed if freed is not None else 'unknown'}"
            f" ledger_status={ledger_status} c14_kept_bytes={kept_str}")
def accounting(state):  # per-class baseline + receipt metrics; receipt fields stay distinct
    """Report each class's Task 0 baseline and receipt metrics, plus wrapper rows.

    Baseline bytes are logical would-delete values, never df. `df_delta_bytes`
    keeps its signed receipt meaning; `freed_bytes_df_based` is explicitly
    df-derived; `deleted_bytes` is `unknown` because no receipt field holds
    logical deleted bytes (never derived from df or C14 kept). Governed class
    rows (`c14 class=`) are kept separate from wrapper aggregate receipts
    (`wrapper job=`) and from optional class baselines. Reads only existing
    govern_<class>/wrapper receipts and the optional task0_baseline.json.
    """
    base = load_baseline(state)
    classes = set(base["classes"]) if base["status"] == "ok" else set()
    try:
        import resolve_config
        cfg = json.loads(Path(resolve_config.resolve()).read_text())
        classes.update(((cfg.get("budgets") or {}).get("classes") or {}).keys())
    except (OSError, ValueError, TypeError, ImportError): pass
    receipts = state / "receipts"
    if receipts.is_dir():
        classes.update(p.name[len("govern_"):-len(".json")] for p in receipts.glob("govern_*.json"))
    lines = []
    for name in sorted(c for c in classes if c):
        try:
            import job_receipt
            rec = job_receipt.get_last_receipt(f"govern_{name}", str(state))
        except (ImportError, OSError, ValueError, TypeError): rec = None
        lines.append(f"c14 class={name} " + _baseline_fields(base, name) + " " + _receipt_fields(rec))
    # Wrapper receipts carry aggregate data only (no per-class assignment); expose
    # them under their own job/scope, never as a guessed governed class.
    for job in ("main_sweeper", "pressure_sweep"):
        try:
            import job_receipt
            rec = job_receipt.get_last_receipt(job, str(state))
        except (ImportError, OSError, ValueError, TypeError): rec = None
        if rec:
            lines.append(f"wrapper job={job} scope=wrapper " + _receipt_fields(rec))
    return lines
def _budget_and_state(state):
    try: budget = parse((state / "budget.json").read_text())
    except OSError: budget = None
    return budget

def _new_alert_lines(state, budget, now, evs, out):
    """Alert classes added by Task 10 beyond the original floor/stale/burst set."""
    from budget_acceptance import _epoch
    signals = set()
    def signal(value):
        if not isinstance(value, str):
            return
        value = value.removeprefix("kept:").split(":", 1)[0]
        signals.add(value.replace("-", "_"))
    for event in evs:
        signal(event.get("event"))
        signal(event.get("reason"))
    for path in (state / "receipts").glob("*.json"):
        store = parse(_safe_read(path))
        done = store.get("completed", []) if isinstance(store, dict) else []
        for row in done if isinstance(done, list) else []:
            if not isinstance(row, dict):
                continue
            ended = _epoch((row.get("times") or {}).get("ended_at"))
            if ended is None or not 0 <= now - ended <= DAY:
                continue
            signal(row.get("reason"))
            post = row.get("postcondition") if isinstance(row.get("postcondition"), dict) else {}
            if post.get("hard_stop") is True:
                signals.add("hard_stop")
            kept = post.get("c14_kept_bytes")
            for reason in kept if isinstance(kept, dict) else ():
                signal(reason)
    for path in (state / "worktree_leases").glob("*.json"):
        lease = parse(_safe_read(path))
        if isinstance(lease, dict) and isinstance(lease.get("reuse"), dict):
            signal(lease["reuse"].get("state"))
    for path in (state / "quarantine-index").glob("*.json"):
        entry = parse(_safe_read(path))
        if isinstance(entry, dict) and entry.get("phase") == "rollback_conflict":
            signals.add("quarantine_conflict")
    for code in ("activation_blocked", "quarantine_conflict", "quarantine_partial_kept",
                 "exclusive_rename_unavailable", "reuse_incomplete", "hard_stop", "archive_overcap_kept"):
        if code in signals:
            out.append(f"ALERT:{code}")
    classes = budget.get("classes") if isinstance(budget, dict) else None
    if isinstance(classes, dict):
        for name, row in classes.items():
            if isinstance(row, dict) and isinstance(row.get("measured_at"), (int, float)) \
                    and not isinstance(row.get("measured_at"), bool) and now - row["measured_at"] > 10800:
                out.append(f"ALERT:class_stale class={name} age_s={now - row['measured_at']:.0f}")
    stopped = budget.get("colima_stopped_since") if isinstance(budget, dict) else None
    observed = budget.get("colima_observed_at") if isinstance(budget, dict) else None
    if (type(stopped) in (int, float) and now - stopped > 3600
            and budget.get("colima_status") == "stopped" and type(observed) in (int, float)
            and 0 <= now - observed <= 1200):
        out.append(f"ALERT:colima_stopped since_s={now - stopped:.0f}")
    births = budget.get("births") if isinstance(budget, dict) else None
    if isinstance(births, dict) and isinstance(births.get("ratio"), (int, float)) \
            and not isinstance(births.get("ratio"), bool) and births["ratio"] >= 0.10:
        jobs = (births.get("ci_admission") or {}).get("jobs")
        out.append(f"ALERT:bypass_high ratio={births['ratio']:.3f} ci_admission jobs={jobs}")
    sched = parse(_safe_read(state / "govern_sched.json")) if _safe_read(state / "govern_sched.json") else {}
    states = sched.get("classes") if isinstance(sched, dict) else None
    if isinstance(states, dict):
        for name, row in states.items():
            if not isinstance(row, dict): continue
            if isinstance(row.get("no_progress_ticks"), int) and row["no_progress_ticks"] >= 3:
                out.append(f"ALERT:reclaim_starved class={name}")
            if isinstance(row.get("deferred_ticks"), int) and row["deferred_ticks"] >= 3:
                out.append(f"ALERT:actuator_starved class={name}")
    receipts = state / "receipts"
    if receipts.is_dir():
        for path in sorted(receipts.glob("govern_*.json")):
            data = parse(_safe_read(path))
            done = data.get("completed") if isinstance(data, dict) else None
            if not isinstance(done, list) or len(done) < 3: continue
            last3 = done[-3:]
            name = path.stem[len("govern_"):]
            stats = classes.get(name, {}) if isinstance(classes, dict) else {}
            import budget_acceptance
            config = budget_acceptance._config_budget().get("classes", {}).get(name, {})
            if (not all(isinstance(r, dict) for r in last3)
                    or type(stats.get("used_gb")) not in (int, float)
                    or type(config.get("budget_gb")) not in (int, float)
                    or stats["used_gb"] <= config["budget_gb"]):
                continue
            deltas = [(r.get("postcondition") or {}).get("df_delta_bytes") for r in last3]
            removed = [(r.get("candidates") or {}).get("removed_count") for r in last3]
            if all(isinstance(d, int) and not isinstance(d, bool) and d <= 0 for d in deltas) \
                    and all(isinstance(n, int) and not isinstance(n, bool) and n == 0 for n in removed):
                out.append(f"ALERT:actuator_dead class={path.stem[len('govern_'):]}")
    ms = parse(_safe_read(receipts / "main_sweeper.json")) if receipts.is_dir() else None
    done = ms.get("completed") if isinstance(ms, dict) else None
    if isinstance(done, list) and len(done) >= 2 and all(isinstance(r, dict) and r.get("outcome") == "error" for r in done[-2:]):
        out.append("ALERT:main_sweeper_error consecutive=2")
    parked = budget.get("parked_measurement") if isinstance(budget, dict) else None
    if (isinstance(parked, dict) and parked.get("status") == "ok"
            and type(parked.get("bytes")) is int and type(parked.get("measured_at")) in (int, float)
            and 0 <= now - parked["measured_at"] <= DAY and parked["bytes"] > 20 * GIB):
        out.append(f"ALERT:parked_large bytes={parked['bytes']} source=worktree_reap_leases")
    return out

def _safe_read(path):
    try: return path.read_text()
    except OSError: return ""

def alerts(state, now, margin_gb=None):
    s, evs, out = samples(state), events(state, now - DAY, now), []
    try: budget = parse((state / "budget.json").read_text())
    except OSError: budget = None
    if margin_gb is None:
        import budget_controls
        try: config = json.loads(Path(__import__("resolve_config").resolve()).read_text()).get("budgets")
        except (OSError, ValueError, TypeError, AttributeError): config = None
        # Preserve status's documented 10 GiB default when neither source sets
        # a margin, but never conceal a malformed explicit override/config.
        explicit = (isinstance(budget, dict) and "margin_gb" in budget) or \
                   (isinstance(config, dict) and "concurrency_margin_gb" in config)
        try: margin_gb = budget_controls.effective_margin(budget, config, strict=explicit)
        except ValueError: out.append("ALERT:margin_invalid effective admission margin unavailable")
    if any(e.get("event") == "floor_breach" for e in evs) or (s and now - s[-1][0] <= 900 and s[-1][2] < 15 * GIB):
        out += ["ALERT:floor_breach free under 15 GiB (df)", *RUNBOOK]
    if (state / "budget.json").exists():
        age = now - budget["zone_at"] if isinstance(budget, dict) and type(budget.get("zone_at")) in (int, float) else float("inf")
        if age > 1800: out.append(f"ALERT:govern_stale last_tick_age={age:.0f}s")
    if any(e.get("degraded") for e in evs): out.append("ALERT:admission_degraded within 24 h")
    if any(str(e.get("event", "")).split(":", 1)[0] == "kickstart_blocked" for e in evs): out.append("ALERT:kickstart_blocked within 24 h")
    burst = window_max([(e["at"], e.get("est_bytes") or 0) for e in evs if e.get("event") == "admit" and type(e.get("decision")) is int and e["decision"] in (0, 10)])
    if margin_gb is not None and burst > margin_gb * GIB: out.append(f"ALERT:burst_over_margin admit_burst_bytes={burst}B margin={margin_gb}GiB")
    week, month = daily_mins(budget, now, 7), daily_mins(budget, now, 30)  # C12: 7-day trough (max of daily minimums) > 15 GiB above the 30-day low
    if len(week) < 0.9 * 7 or len(month) < 0.9 * 30: out.append(f"trough_rise:insufficient_history days_7d={len(week)}/7 days_30d={len(month)}/30")
    elif max(week) - min(month) > 15 * GIB: out.append(f"ALERT:trough_rise trough_7d={max(week)}B trough_30d={min(month)}B")
    return _new_alert_lines(state, budget, now, evs, out)
def main(argv=None):
    argv = list(sys.argv[1:]) if argv is None else list(argv)
    if not argv:
        return print("usage: diskm budget {status|set-stage|set-margin|promote-estimates}", file=sys.stderr) or 2
    command, rest = argv[0], argv[1:]
    if command in ("set-stage", "set-margin", "promote-estimates"):
        import budget_controls
        return budget_controls.main([command, *rest])
    if command != "status":
        return print("usage: diskm budget {status|set-stage|set-margin|promote-estimates}", file=sys.stderr) or 2
    known = {"--weekly-check", "--pilot-check", "--at"}
    at, i = None, 0
    while i < len(rest):
        if rest[i] == "--at" and i + 1 < len(rest):
            try: at = float(rest[i + 1])
            except ValueError: return print("usage: --at <epoch>", file=sys.stderr) or 2
            i += 2; continue
        if rest[i] not in known:
            return print("usage: diskm budget status [--weekly-check|--pilot-check] [--at <epoch>]", file=sys.stderr) or 2
        i += 1
    state = Path(os.environ.get("DISK_MAGICIAN_STATE_DIR", Path.home() / ".disk_magician_state"))
    now = at if at is not None else time.time()
    if "--weekly-check" in rest or "--pilot-check" in rest:
        import budget_acceptance
        lines, rc = budget_acceptance.weekly_check(state, now) if "--weekly-check" in rest else budget_acceptance.pilot_check(state, now)
        print("\n".join(lines))
        return rc
    lines = alerts(state, now)
    acct = accounting(state)
    out = "\n".join(lines or ["no_alerts"])
    if acct: out += "\n" + "\n".join(acct)
    print(out)
    return 1 if raised(lines) else 0
if __name__ == "__main__":
    sys.exit(main())
