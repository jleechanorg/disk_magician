#!/usr/bin/env python3
"""diskm budget status: governor alerts from budget.json, the admission event log and observer df samples (plan Task 10)."""
import json, os, sys, time
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
    pts = sorted(points)
    return max((sum(b for u, b in pts[i:] if u < t + width) for i, (t, _) in enumerate(pts)), default=0)
def daily_mins(budget, now, n):  # C12: govern's per-day minimum used bytes (budget.json daily_min_used); observer files rotate out after ~7-11 days
    m = budget.get("daily_min_used") if isinstance(budget, dict) else None
    return [v for d in range(n) if isinstance(m, dict) and type(v := m.get(time.strftime("%Y-%m-%d", time.localtime(now - d * DAY)))) is int]
def raised(lines): return any(line.startswith("ALERT:") for line in lines)
def _int_or_none(value): return value if isinstance(value, int) and not isinstance(value, bool) else None
def accounting(state):  # per-class C14 kept bytes and receipt metrics from govern_<class> receipts
    """Report each class's kept/reclaim metrics without fabricating a baseline.

    The Task 0 reclaim baseline has no canonical machine-readable representation
    in this tree yet, so `baseline_bytes` is reported as explicit `unknown` rather
    than invented. `freed_bytes`/`df_reclaimed_bytes` come from the receipt and
    stay separate from the logical `c14_kept_bytes`; `ledger_status` is the fold
    quality signal. Reads only existing govern_<class> receipts.
    """
    classes = set()
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
        line = f"c14 class={name} baseline_bytes=unknown"
        try:
            import job_receipt
            rec = job_receipt.get_last_receipt(f"govern_{name}", str(state))
        except (ImportError, OSError, ValueError, TypeError): rec = None
        if not rec:
            lines.append(line + " receipt=missing"); continue
        post = rec.get("postcondition") if isinstance(rec.get("postcondition"), dict) else {}
        cand = rec.get("candidates") if isinstance(rec.get("candidates"), dict) else {}
        df, freed, removed = _int_or_none(post.get("df_delta_bytes")), _int_or_none(post.get("freed_bytes")), _int_or_none(cand.get("removed_count"))
        status = post.get("c14_ledger_status") if isinstance(post.get("c14_ledger_status"), str) else "absent"
        kept = post.get("c14_kept_bytes") if isinstance(post.get("c14_kept_bytes"), dict) else {}
        kept_str = ",".join(f"{k}:{_int_or_none(v)}" for k, v in sorted(kept.items()) if _int_or_none(v) is not None) or "none"
        lines.append(line + f" receipt={rec.get('outcome', 'unknown')}"
                     f" removed_count={removed if removed is not None else 'unknown'}"
                     f" freed_bytes={freed if freed is not None else 'unknown'}"
                     f" df_reclaimed_bytes={df if df is not None else 'unknown'}"
                     f" ledger_status={status} c14_kept_bytes={kept_str}")
    return lines
def alerts(state, now, margin_gb=None):
    if margin_gb is None:
        try: margin_gb = json.loads(Path(__import__("resolve_config").resolve()).read_text())["budgets"]["concurrency_margin_gb"]
        except (OSError, ValueError, KeyError, TypeError): margin_gb = 10
    s, evs, out = samples(state), events(state, now - DAY, now), []
    try: budget = parse((state / "budget.json").read_text())
    except OSError: budget = None
    if any(e.get("event") == "floor_breach" for e in evs) or (s and now - s[-1][0] <= 900 and s[-1][2] < 15 * GIB):
        out += ["ALERT:floor_breach free under 15 GiB (df)", *RUNBOOK]
    if (state / "budget.json").exists():
        age = now - budget["zone_at"] if isinstance(budget, dict) and type(budget.get("zone_at")) in (int, float) else float("inf")
        if age > 1800: out.append(f"ALERT:govern_stale last_tick_age={age:.0f}s")
    if any(e.get("degraded") for e in evs): out.append("ALERT:admission_degraded within 24 h")
    if any(str(e.get("event", "")).startswith("kickstart_blocked") for e in evs): out.append("ALERT:kickstart_blocked within 24 h")
    burst = window_max([(e["at"], e.get("est_bytes") or 0) for e in evs if e.get("event") == "admit" and type(e.get("decision")) is int and e["decision"] in (0, 10)])
    if burst > margin_gb * GIB: out.append(f"ALERT:burst_over_margin admit_burst_bytes={burst}B margin={margin_gb}GiB")
    week, month = daily_mins(budget, now, 7), daily_mins(budget, now, 30)  # C12: 7-day trough (max of daily minimums) > 15 GiB above the 30-day low
    if len(week) < 0.9 * 7 or len(month) < 0.9 * 30: out.append(f"trough_rise:insufficient_history days_7d={len(week)}/7 days_30d={len(month)}/30")
    elif max(week) - min(month) > 15 * GIB: out.append(f"ALERT:trough_rise trough_7d={max(week)}B trough_30d={min(month)}B")
    return out
def main(argv=None):
    if (argv if argv is not None else sys.argv[1:]) != ["status"]:
        return print("usage: diskm budget status", file=sys.stderr) or 2
    state = Path(os.environ.get("DISK_MAGICIAN_STATE_DIR", Path.home() / ".disk_magician_state"))
    lines = alerts(state, time.time())
    acct = accounting(state)
    out = "\n".join(lines or ["no_alerts"])
    if acct: out += "\n" + "\n".join(acct)
    print(out)
    return 1 if raised(lines) else 0
if __name__ == "__main__":
    sys.exit(main())
