#!/usr/bin/env python3
"""diskm budget acceptance — weekly success metrics and pilot validity (plan Task 10).

Reads only existing owners: `disk_observer` samples (df-only), `budget.json`
state, `admission/events.jsonl`, `admission/births.json`, govern receipts and
`deployed.json`. Nothing here invents evidence: an absent or malformed source
yields an explicit `insufficient_data`/`unknown` result, never a pass.
"""
import datetime
import bisect
import hashlib
import json
import math
import os
import time
from pathlib import Path

import disk_observer
from birth_audit import BIRTH_STATUSES, SLO_BIRTH_STATUSES

GIB = 1 << 30
DAY = 86400
WEEK = 7 * DAY
SAMPLE_INTERVAL_S = 60
TICK_INTERVAL_S = 600
FLOOR_GIB = 15
TARGET_MIN_FREE_GIB = 30
TARGET_TROUGH_GIB = 790
BYPASS_SLO = 0.10
MIN_OBSERVER_COVERAGE = 0.95
MIN_QUALIFYING_DAYS = 6
FLEET_UNHEALTHY_LIMIT_S = 2 * 3600
# Files whose deployed hash change invalidates a pilot (spec §7.4).
PILOT_HASH_FILES = (
    "scripts/disk_budget.py", "scripts/birth_audit.py", "scripts/budget_status.py",
    "scripts/budget_controls.py", "scripts/budget_acceptance.py", "scripts/budget_history.py",
    "scripts/c14_probe.py", "scripts/lib/artifact_verdict.sh",
    "scripts/lib/admit_caller.sh", "scripts/check_launchd_fleet.sh", "scripts/resolve_config.py",
    "scripts/ci_admit.sh",
)
DEFAULT_SAMPLE_INTERVAL_S = 60


def read_json(path):
    try:
        return json.loads(Path(path).read_text())
    except (OSError, ValueError):
        return None


def samples(state):
    """(epoch, used B, free B) from disk_observer.jsonl{,.1,.2} (owner: disk_observer)."""
    recs = disk_observer.read_records([Path(state) / f"disk_observer.jsonl{s}" for s in (".2", ".1", "")])
    out = []
    for rec in recs:
        data = rec.get("host_disk")
        if isinstance(rec.get("epoch"), (int, float)) and isinstance(data, dict) \
                and all(isinstance(data.get(k), (int, float)) for k in ("used_kb", "available_kb")):
            out.append((rec["epoch"], int(data["used_kb"]) * 1024, int(data["available_kb"]) * 1024))
    return sorted(out)


def read_events(state, lo=None, hi=None):
    try:
        lines = (Path(state) / "admission" / "events.jsonl").read_text().splitlines()
    except OSError:
        return []
    out = []
    for line in lines:
        try:
            event = json.loads(line)
        except ValueError:
            continue
        if not isinstance(event, dict):
            continue
        at = event.get("at")
        if (lo is not None and not (isinstance(at, (int, float)) and at >= lo)) \
                or (hi is not None and not (isinstance(at, (int, float)) and at < hi)):
            continue
        out.append(event)
    return out


def completed_receipts(state, lo, hi, prefix="govern_"):
    """Terminal receipts from every govern_* job whose ended_at is in [lo, hi)."""
    candidates = [event.get("receipt") for event in read_events(state)
                  if event.get("event") == "govern_receipt"]
    for path in sorted((Path(state) / "receipts").glob(f"{prefix}*.json")):
        data = read_json(path)
        if isinstance(data, dict) and isinstance(data.get("completed"), list):
            candidates.extend(data["completed"])
    out, seen = [], set()
    for rec in candidates:
        if not isinstance(rec, dict) or not isinstance(rec.get("times"), dict):
            continue
        if rec.get("job") and not rec["job"].startswith(prefix):
            continue
        epoch = _epoch(rec["times"].get("ended_at"))
        key = (rec.get("job"), rec.get("run_id") or rec.get("id"))
        if not key[1]:
            key = json.dumps(rec, sort_keys=True)
        if epoch is not None and lo <= epoch < hi and key not in seen:
            seen.add(key)
            out.append(rec)
    return out


def _epoch(iso):
    if not isinstance(iso, str) or not iso:
        return None
    try:
        return datetime.datetime.fromisoformat(iso.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


def sample_interval(pts):
    """Observed spacing; kept only for reporting beside the fixed 60 s cadence."""
    times = sorted(t for t, _, _ in pts)
    diffs = [b - a for a, b in zip(times, times[1:]) if b > a]
    if not diffs:
        return DEFAULT_SAMPLE_INTERVAL_S
    diffs.sort()
    value = diffs[len(diffs) // 2]
    return value if 0 < value <= 3600 else DEFAULT_SAMPLE_INTERVAL_S


def coverage(pts, start, end):
    """Fraction of expected 60-second buckets containing an observation."""
    if end <= start:
        return 0.0
    occupied = {int((t - start) // SAMPLE_INTERVAL_S)
                for t, _, _ in pts if start <= t < end}
    expected = max(1, int((end - start) / SAMPLE_INTERVAL_S))
    return min(1.0, len(occupied) / expected)


def window_bounds(now):
    """Most recent completed fixed calendar week (Monday 00:00 local → +7d)."""
    today = datetime.datetime.fromtimestamp(now).date()
    monday = today - datetime.timedelta(days=today.weekday())
    previous = monday - datetime.timedelta(days=7)
    return (time.mktime(previous.timetuple()), time.mktime(monday.timetuple()))


def daily_mins(pts, start, end):
    """Local-day minimum used bytes keyed by YYYY-MM-DD inside [start, end)."""
    out = {}
    for epoch, used, _ in pts:
        if not (start <= epoch < end):
            continue
        day = time.strftime("%Y-%m-%d", time.localtime(epoch))
        out[day] = min(used, out.get(day, used))
    return out


def _births(state, lo, hi):
    """(admitted, bypass, ratio) or None when no birth registry exists.

    Statuses come from the producer's authoritative ``birth_audit`` schema: a
    valid non-SLO status (``preexisting``/``foreign``) is skipped for the SLO,
    while a structurally malformed row or unknown status is ``unknown`` for the
    whole registry, never a zero-ratio pass.
    """
    reg = read_json(Path(state) / "admission" / "births.json")
    gens = reg.get("gens") if isinstance(reg, dict) else None
    if not isinstance(gens, dict):
        return None
    admitted = bypass = 0
    for gen in gens.values():
        if (not isinstance(gen, dict) or type(gen.get("first_seen")) not in (int, float)
                or not math.isfinite(gen["first_seen"]) or gen["first_seen"] < 0
                or gen.get("status") not in BIRTH_STATUSES):
            return None
        if gen["status"] not in SLO_BIRTH_STATUSES:
            continue
        if not lo <= gen["first_seen"] < hi:
            continue
        if gen["status"] == "admitted":
            admitted += 1
        else:
            bypass += 1
    total = admitted + bypass
    return admitted, bypass, (bypass / total if total else 0.0)


def _window_max(points, width=600):
    pts = sorted(points)
    total = peak = left = 0
    for right, (at, value) in enumerate(pts):
        total += value
        while at - pts[left][0] >= width:
            total -= pts[left][1]
            left += 1
        peak = max(peak, total)
    return peak


def r_peak_and_largest_delta(inside):
    """Largest measured 600-second rise; adjacent jumps reported separately."""
    pts = sorted(inside)
    times = [p[0] for p in pts]
    peak = largest = 0
    for i, (at, used, _) in enumerate(pts):
        j = bisect.bisect_right(times, at + 600, i + 1) - 1
        if j > i:
            peak = max(peak, (pts[j][1] - used) / 600)
        if i:
            largest = max(largest, used - pts[i - 1][1])
    return peak, largest


def _reclaim_seconds(receipts, ticks=()):
    """Maximum observed reclaim delay; unknown if any emergency tick is unresolved."""
    positive = []
    for rec in receipts:
        ended = _epoch((rec.get("times") or {}).get("ended_at"))
        delta = (rec.get("postcondition") or {}).get("df_delta_bytes")
        if ended is not None and type(delta) is int and delta > 0:
            positive.append(ended)
    positive.sort()
    observed = []
    for tick in ticks:
        if str(tick.get("zone", "")).upper() not in ("ORANGE", "RED", "BLACK", "FLOOR"):
            continue
        at = tick["at"]
        j = bisect.bisect_left(positive, at)
        if j >= len(positive):
            return None
        observed.append(positive[j] - at)
    return max(observed) if observed else None


def _tick_records(state, lo, hi):
    """Use the actual governor event producer, one latest observation per slot."""
    slots = {}
    for event in read_events(state, lo, hi):
        if event.get("event") != "govern_tick" or event.get("outcome") != "success":
            continue
        slot = int((event["at"] - lo) // TICK_INTERVAL_S)
        if slot not in slots or event["at"] > slots[slot]["at"]:
            slots[slot] = event
    return sorted(slots.values(), key=lambda row: row["at"])


def _freshness_ok(sample, required):
    fresh = sample.get("classes_fresh")
    return (isinstance(fresh, dict) and bool(required)
            and all(fresh.get(name) is True for name in required))


def _expected_tick_buckets(start, end):
    return max(1, int((end - start) // TICK_INTERVAL_S))


def weekly_check(state, now):
    """Check one completed calendar week; persist bounded consecutive results."""
    import budget_controls as controls
    state = Path(state)
    pts = samples(state)
    start, end = window_bounds(now)
    lines, passed = _week_rows(state, start, end, pts)
    cov = coverage(pts, start, end)
    mins = daily_mins(pts, start, end)
    result = dict(start=start, end=end, passed=passed, coverage=cov,
                  trough=max(mins.values()) if mins else None)
    count = 0

    def mutate(data):
        nonlocal count
        history = [r for r in data.get("weekly_results", [])
                   if isinstance(r, dict) and r.get("start") != start]
        count, cursor = int(passed), start
        if passed:
            for previous in sorted(history, key=lambda r: r.get("end", 0), reverse=True):
                if previous.get("end") > cursor:
                    continue
                if previous.get("end") != cursor or previous.get("passed") is not True:
                    break
                count += 1
                cursor = previous["start"]
        result["consecutive_passes"] = count
        data["weekly_results"] = sorted(history + [result], key=lambda r: r["start"])[-8:]

    controls.locked_mutate(state, mutate)
    lines.extend([f"adjacent_passing_weeks={count}", f"result={'pass' if passed else 'fail'}"])
    return lines, 0 if passed else 1


def _week_rows(state, start, end, pts):
    """Spec §9 rows for one fixed calendar week; first line is the header."""
    cov = coverage(pts, start, end)
    lines = [f"start={time.strftime('%Y-%m-%d', time.localtime(start))} "
             f"end={time.strftime('%Y-%m-%d', time.localtime(end))} coverage={cov:.3f}"]
    if cov < MIN_OBSERVER_COVERAGE:
        lines.append(f"insufficient_data:observer_coverage={cov:.3f}")
        return lines, False
    inside = [p for p in pts if start <= p[0] < end]
    free_min = min(p[2] for p in inside)
    under15 = sum(1 for p in inside if p[2] < FLOOR_GIB * GIB)
    mins = daily_mins(pts, start, end)
    trough = max(mins.values()) if mins else 0
    passed = True

    def row(name, ok, detail):
        nonlocal passed
        passed = passed and ok
        lines.append(f"{name}={'pass' if ok else 'fail'} {detail}")

    row("min_free", free_min >= TARGET_MIN_FREE_GIB * GIB, f"bytes={free_min} target={TARGET_MIN_FREE_GIB}GiB")
    row("floor_samples", under15 == 0, f"count={under15}")
    row("trough", bool(mins) and trough <= TARGET_TROUGH_GIB * GIB,
        f"bytes={trough} target={TARGET_TROUGH_GIB}GiB")
    prev_mins = daily_mins(pts, start - WEEK, start)
    prev_cov = coverage(pts, start - WEEK, start)
    prior_summary = next((r for r in (read_json(state / "budget.json") or {}).get("weekly_results", [])
                          if isinstance(r, dict) and r.get("end") == start
                          and r.get("coverage", 0) >= MIN_OBSERVER_COVERAGE
                          and isinstance(r.get("trough"), (int, float))), None)
    if prev_cov >= MIN_OBSERVER_COVERAGE:
        prev_trough = max(prev_mins.values())
    else:
        prev_trough = prior_summary["trough"] if prior_summary else None
    if prev_trough is None:
        lines.append("trough_rise:insufficient_history")
        passed = False
    else:
        row("trough_rising", trough <= prev_trough, f"trough={trough} previous={prev_trough}")
    ticks = _tick_records(state, start, end)
    times = [start] + [s["at"] for s in ticks] + [end]
    stale_ticks = sum(b - a > 1800 for a, b in zip(times, times[1:]))
    receipts = completed_receipts(state, start, end)
    null_delta = sum(1 for r in receipts
                     if not (isinstance((r.get("postcondition") or {}).get("df_delta_bytes"), int)
                             and not isinstance((r.get("postcondition") or {}).get("df_delta_bytes"), bool)))
    if receipts:
        row("receipt_df_delta", null_delta == 0, f"null={null_delta}/{len(receipts)}")
    else:
        lines.append("receipt_df_delta=na receipts=0 (govern observe tick emits no actuator receipt)")
    row("govern_stale_ticks", stale_ticks == 0, f"gaps_over_30min={stale_ticks}")
    births = _births(state, start, end)
    if births is None:
        row("bypass_ratio", False, "unknown (no admission/births.json)")
    else:
        admitted, bypass, ratio = births
        row("bypass_ratio", ratio < BYPASS_SLO, f"bypass={bypass} admitted={admitted} ratio={ratio:.3f}")
    return lines, passed


def _qualifying_days(state, start, end, pts, config_budget=None):
    """Count days with >=95% observer, >=95% tick and >=80% fresh-du coverage."""
    ticks = _tick_records(state, start, end)
    if config_budget is None:
        config_budget = _config_budget()
    required = {name for name, row in config_budget.get("classes", {}).items()
                if isinstance(row, dict) and row.get("measure") == "du"}
    qualifying = 0
    day = start
    while day < end:
        stop = day + DAY
        day_samples = [s for s in ticks if day <= s.get("at", -1) < stop]
        day_buckets = {int((s["at"] - day) // TICK_INTERVAL_S) for s in day_samples}
        expected = _expected_tick_buckets(day, stop)
        observer_ok = coverage(pts, day, stop) >= MIN_OBSERVER_COVERAGE
        tick_ok = len(day_buckets) / expected >= MIN_OBSERVER_COVERAGE
        fresh = sum(1 for s in day_samples if _freshness_ok(s, required))
        du_ok = bool(day_samples) and fresh / len(day_samples) >= 0.80
        if observer_ok and tick_ok and du_ok:
            qualifying += 1
        day = stop
    return qualifying


def hook_hash():
    try:
        return hashlib.sha256((Path.home() / ".claude/hooks/disk-admission.sh").read_bytes()).hexdigest()
    except OSError:
        return None


def _deploy_invalidated(state, budget, pilot_start):
    deployed = read_json(Path(state) / "deployed.json")
    snapshot = budget.get("pilot_package_hashes")
    current = deployed.get("package_hashes") if isinstance(deployed, dict) else None
    if not isinstance(snapshot, dict) or not isinstance(current, dict):
        return "insufficient"
    for name in PILOT_HASH_FILES:
        if not isinstance(snapshot.get(name), str) or not isinstance(current.get(name), str):
            return "insufficient"
        if snapshot[name] != current[name]:
            return True
    return False


def _config_budget():
    import resolve_config
    config = read_json(resolve_config.resolve())
    budgets = config.get("budgets") if isinstance(config, dict) else None
    if not isinstance(budgets, dict) or not budgets:
        template = read_json(Path(__file__).resolve().parents[1] / "config.json.template") or {}
        budgets = template.get("budgets", {})
    return budgets


def config_hash(budgets=None):
    if budgets is None:
        budgets = _config_budget()
    if not budgets:
        return None
    return hashlib.sha256(json.dumps(budgets, sort_keys=True,
                                    separators=(",", ":")).encode()).hexdigest()


def pilot_check(state, now, record=True):
    """Pilot validity, floor gate and §7.6 exposure; rc 0 only for `pilot_valid`."""
    state = Path(state)
    budget = read_json(state / "budget.json")
    if not isinstance(budget, dict):
        return ["insufficient_data:budget"], 1
    start = budget.get("pilot_start")
    if not (isinstance(start, (int, float)) and not isinstance(start, bool)):
        return ["insufficient_data:no_pilot"], 1
    end = start + WEEK
    if now < end:
        return [f"insufficient_data:pilot_week_incomplete elapsed_s={now - start:.0f}"], 1
    pts = samples(state)
    receipts = completed_receipts(state, start, end)

    def invalid(rule):
        return [f"pilot_invalid:{rule}"], 1

    import budget_controls as controls
    if not controls._d2_approved():
        return invalid("d2_not_approved")
    config_budget = _config_budget()
    current_config = config_hash(config_budget)
    if current_config is None or budget.get("pilot_config_hash") is None:
        return ["insufficient_data:pilot_config"], 1
    if budget["pilot_config_hash"] != current_config:
        return invalid("budget_changed")
    if controls.effective_stage(budget, config_budget) != budget.get("pilot_stage"):
        return invalid("stage_changed")
    if controls.effective_margin(budget, config_budget) != budget.get("pilot_margin_gb"):
        return invalid("margin_changed")
    qualifying = _qualifying_days(state, start, end, pts, config_budget)
    if qualifying < MIN_QUALIFYING_DAYS:
        return invalid(f"qualifying_days={qualifying}/7")
    if _births(state, start, end) is None:
        return ["insufficient_data:births"], 1
    deploy = _deploy_invalidated(state, budget, start)
    if deploy == "insufficient":
        return ["insufficient_data:deployed"], 1
    if deploy:
        return invalid("deploy_changed")
    current_hook = hook_hash()
    if current_hook is None or budget.get("pilot_hook_hash") is None:
        return ["insufficient_data:hook"], 1
    if current_hook != budget["pilot_hook_hash"]:
        return invalid("hook_changed")
    if isinstance(budget.get("stage_changed_at"), (int, float)) and budget["stage_changed_at"] > start:
        return invalid("stage_changed")
    if isinstance(budget.get("margin_changed_at"), (int, float)) and budget["margin_changed_at"] > start:
        return invalid("margin_changed")
    current_hash = _estimates_hash(state)
    if current_hash is None:
        return ["insufficient_data:estimates"], 1
    if budget.get("estimates_hash") != current_hash:
        return invalid("estimates_changed")
    ticks = _tick_records(state, start, end)
    unknown = _expected_tick_buckets(start, end) - sum(t.get("fleet_status") in ("healthy", "degraded") for t in ticks)
    unhealthy = TICK_INTERVAL_S * sum(t.get("fleet_status") == "degraded" for t in ticks)
    if unknown * TICK_INTERVAL_S + unhealthy > FLEET_UNHEALTHY_LIMIT_S and unhealthy <= FLEET_UNHEALTHY_LIMIT_S:
        return ["insufficient_data:fleet_health"], 1
    if unhealthy > FLEET_UNHEALTHY_LIMIT_S:
        return invalid(f"fleet_unhealthy_s={unhealthy:.0f}")

    inside = [p for p in pts if start <= p[0] < end]
    pilot_floor_ok = bool(inside) and all(p[2] >= FLOOR_GIB * GIB for p in inside)
    interval = sample_interval(inside) if inside else SAMPLE_INTERVAL_S
    r_peak, largest_delta = r_peak_and_largest_delta(inside)
    events = read_events(state, start, end)
    bursts = [(e.get("at"), e.get("est_bytes") or 0) for e in events
              if e.get("event") == "admit" and e.get("decision") in (0, 10)]
    admit_burst = _window_max(bursts)
    reclaim = _reclaim_seconds(receipts, ticks)
    if reclaim is None:
        floor_margin_ok = False
        margin_note = "margin_unknown"
    else:
        exposure = r_peak * (TICK_INTERVAL_S + interval + reclaim) + admit_burst
        floor_margin_ok = exposure <= FLOOR_GIB * GIB
        margin_note = f"exposure={exposure:.0f}B t_reclaim={reclaim:.0f}s"
    b_est, w_est, bw_note = _bw_estimates(state, pts, start, end)
    lines = ["pilot_valid"]
    lines.append(f"B_est={b_est} label=estimate {bw_note}")
    lines.append(f"W_est={w_est} label=estimate")
    lines.append(f"r_peak={r_peak:.6f}B/s sample_interval_s={interval:.0f} largest_sample_delta={largest_delta}B")
    lines.append(f"admit_burst_bytes={admit_burst}B")
    lines.append(f"floor_margin_ok={'true' if floor_margin_ok else 'false'} {margin_note}")
    lines.append(f"pilot_floor_ok={'true' if pilot_floor_ok else 'false'} min_free={min((p[2] for p in inside), default=0)}B")
    lines.append(f"qualifying_days={qualifying}/7")
    count = budget.get("pilot_floor_fail_epochs", 0)
    if record:
        import budget_controls as controls
        epoch_id = f"{start}:{budget.get('pilot_epoch')}"
        count = controls.record_floor_epoch(state, not pilot_floor_ok, epoch_id, now)
    if count >= 2:
        lines.append("ALERT:v2_trigger")
    return lines, 0


def _bw_estimates(state, pts, start, end):
    """Residual at measured class snapshots; daily snapshots cannot prove W."""
    import budget_controls as controls
    budget = read_json(Path(state) / "budget.json") or {}
    measurements = budget.get("measurements")
    if not isinstance(measurements, list):
        return "unknown", "unknown", "source=unknown"
    estimates = []
    for entry in measurements:
        if not isinstance(entry, dict) or not controls.finite_nonneg(entry.get("at")):
            continue
        if not start <= entry["at"] < end:
            continue
        classes = entry.get("classes")
        if (not isinstance(classes, dict) or not classes or entry.get("carried")
                or entry.get("incomplete") or any(not isinstance(r, dict)
                    or r.get("carried") or not controls.finite_nonneg(r.get("used_gb"))
                    for r in classes.values())):
            return "unknown", "unknown", "source=measurements incomplete"
        used = entry.get("used_bytes")
        source = "measurement_df"
        if not controls.finite_nonneg(used):
            nearest = min(pts, key=lambda p: abs(p[0] - entry["at"]), default=None)
            if nearest is None or abs(nearest[0] - entry["at"]) > SAMPLE_INTERVAL_S:
                return "unknown", "unknown", "source=measurements missing_df"
            used, source = nearest[1], "nearest_observer_non_atomic"
        estimates.append((entry["at"], used / GIB - sum(r["used_gb"] for r in classes.values()), source))
    if not estimates:
        return "unknown", "unknown", "source=measurements missing"
    _, value, source = max(estimates)
    return f"{value:.2f}GiB", "unknown", f"source={source} W_insufficient_intraday_measurements"


def _estimates_hash(state):
    path = Path(state) / "admission" / "estimates.json"
    try:
        return hashlib.sha256(path.read_bytes()).hexdigest()
    except OSError:
        return None
