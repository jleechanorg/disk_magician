#!/usr/bin/env python3
"""diskm budget status: governor alerts, the §9 weekly check and the §7.4 pilot floor check (df-only, plan Task 10)."""
import argparse, json, os, sys, time
from datetime import datetime, timedelta
from pathlib import Path
import disk_observer
GIB, DAY, WIN, SAMPLE_S = 1 << 30, 86400, 600, 60
RUNBOOK = ("  runbook: identify the producer (top growing roots: admission/events.jsonl, birth audit, observer)",
           "  runbook: ask the user before pausing CI runners (launchctl bootout gui/$UID/<ezgha label>)",
           "  runbook: colima stop && colima start, then colima ssh -- sudo fstrim -av",
           "  runbook: list parked worktrees; never hand-rm")
def samples(state):  # (epoch, used B, free B) from disk_observer.jsonl{,.1,.2}
    recs = disk_observer.read_records([state / f"disk_observer.jsonl{s}" for s in (".2", ".1", "")])
    return [(r["epoch"], d["used_kb"] * 1024, d["available_kb"] * 1024) for r in recs
            if isinstance(r.get("epoch"), (int, float)) and isinstance(d := r.get("host_disk"), dict)
            and all(isinstance(d.get(k), (int, float)) for k in ("used_kb", "available_kb"))]
def events(state):
    out = []
    try: lines = (state / "admission" / "events.jsonl").read_text().splitlines()
    except OSError: return out
    for line in lines:
        try: e = json.loads(line)
        except ValueError: continue
        if isinstance(e, dict) and isinstance(e.get("at"), (int, float)): out.append(e)
    return out
def window_max(points, width=WIN):  # max sum of (t, bytes) inside any [t, t + width) window
    pts = sorted(points)
    return max((sum(b for u, b in pts[i:] if u < t + width) for i, (t, _) in enumerate(pts)), default=0)
def r_peak(s):  # max Δ(df used)/Δt over the first span >= 600 s from each sample; nothing subtracted [B/s]
    best, j = 0.0, 0
    for i, (t, u, _) in enumerate(s):
        j = max(j, i)
        while j < len(s) and s[j][0] - t < WIN: j += 1
        if j < len(s): best = max(best, (s[j][1] - u) / (s[j][0] - t))
    return best
def exposure(r, t_detect, t_reclaim, burst):  # spec §7.6; None = margin_unknown (no positive reclaim receipt)
    return None if t_reclaim is None else r * (t_detect + t_reclaim) + burst
def troughs(s, start, days):  # per-day minimum used, None for a day without samples
    return [min((u for t, u, _ in s if start + d * DAY <= t < start + (d + 1) * DAY), default=None) for d in range(days)]
def burst(evs, lo, hi):
    return window_max([(e["at"], e.get("est_bytes") or 0) for e in evs if e.get("event") == "admit" and lo <= e["at"] < hi])
def weekly_check(s, start, prev=True):
    w = [x for x in s if start <= x[0] < start + 7 * DAY]
    days = [d for d in troughs(s, start, 7) if d is not None]
    rows = dict(coverage_pct=round(100 * len(w) / (7 * DAY / SAMPLE_S), 1), min_free_gib=round(min((f for *_, f in w), default=0) / GIB, 2),
                samples_under_15gib=sum(f < 15 * GIB for *_, f in w), trough_gib=round(max(days, default=0) / GIB, 2))
    before = weekly_check(s, start - 7 * DAY, prev=False) if prev else None
    rising = before is not None and before["rows"]["coverage_pct"] >= 95 and rows["trough_gib"] > before["rows"]["trough_gib"]
    ok = rows["min_free_gib"] >= 30 and not rows["samples_under_15gib"] and rows["trough_gib"] <= 790 and not rising
    verdict = "insufficient_data" if rows["coverage_pct"] < 95 else "pass" if ok else "fail"
    passes = (verdict == "pass") + (verdict == "pass" and before is not None and before["verdict"] == "pass")
    return dict(verdict=verdict, rows={**rows, "trough_rising": rising}, consecutive_passes=passes,
                not_evaluated=["govern_receipt_df_delta", "bypass_births_ratio", "govern_stale_alerts"])
def pilot_check(s, evs, start, t_reclaim=None):
    end, w = start + 7 * DAY, [x for x in s if start <= x[0] < start + 7 * DAY]
    qualifying = sum(sum(start + d * DAY <= x[0] < start + (d + 1) * DAY for x in w) >= 0.95 * DAY / SAMPLE_S for d in range(7))
    r, b = r_peak(w), burst(evs, start, end)
    e = exposure(r, WIN + SAMPLE_S, t_reclaim, b)
    return dict(verdict="pilot_valid" if qualifying >= 6 else "pilot_invalid:qualifying_days", qualifying_days=qualifying,
                pilot_floor_ok=bool(w) and all(f >= 15 * GIB for *_, f in w), r_peak_Bps=r, admit_burst_bytes=b,
                exposure_B=e, floor_margin_ok="margin_unknown" if e is None else e <= 15 * GIB, sample_interval_s=SAMPLE_S,
                largest_sample_delta_B=max((b2[1] - a[1] for a, b2 in zip(w, w[1:])), default=0))
def alerts(state, now, margin_gb=None):
    if margin_gb is None:
        try: margin_gb = json.loads(Path(__import__("resolve_config").resolve()).read_text())["budgets"]["concurrency_margin_gb"]
        except (OSError, ValueError, KeyError, TypeError): margin_gb = 10
    s, evs, out = samples(state), [e for e in events(state) if now - DAY <= e["at"] <= now], []
    if any(e.get("event") == "floor_breach" for e in evs) or (s and now - s[-1][0] <= 900 and s[-1][2] < 15 * GIB):
        out += ["ALERT:floor_breach free under 15 GiB (df)", *RUNBOOK]
    if (state / "budget.json").exists():
        try: at = json.loads((state / "budget.json").read_text())["zone_at"]; age = now - float(at)
        except (OSError, ValueError, KeyError, TypeError): age = float("inf")
        if age > 1800: out.append(f"ALERT:govern_stale last_tick_age_s={age:.0f}")
    if any(e.get("degraded") for e in evs): out.append("ALERT:admission_degraded within 24 h")
    if any(str(e.get("event", "")).startswith("kickstart_blocked") for e in evs): out.append("ALERT:kickstart_blocked within 24 h")
    if (b := burst(evs, now - DAY, now + 1)) > margin_gb * GIB: out.append(f"ALERT:burst_over_margin admit_burst_bytes={b}B margin={margin_gb}GiB")
    cur, old = (max((d for d in troughs(s, now - k * DAY, 7) if d is not None), default=None) for k in (7, 14))
    if cur is not None and old is not None and cur > old: out.append(f"ALERT:trough_rise trough={cur}B previous={old}B")
    return out
def main(argv=None):
    p = argparse.ArgumentParser(prog="diskm budget")
    p.add_argument("cmd", choices=["status"])
    mode = p.add_mutually_exclusive_group()
    for flag in ("--weekly-check", "--pilot-check"): mode.add_argument(flag, action="store_true")
    p.add_argument("--week-start", help="YYYY-MM-DD, local midnight (default: the last completed Monday-start week)")
    a, now = p.parse_args(argv), time.time()
    state = Path(os.environ.get("DISK_MAGICIAN_STATE_DIR", Path.home() / ".disk_magician_state"))
    if a.weekly_check or a.pilot_check:
        if a.weekly_check:
            today = datetime.now().replace(hour=0, minute=0, second=0, microsecond=0)
            start = datetime.strptime(a.week_start, "%Y-%m-%d") if a.week_start else today - timedelta(days=today.weekday() + 7)
            r = weekly_check(samples(state), start.timestamp())
        else:
            try: start = float(json.loads((state / "budget.json").read_text())["pilot_start"])
            except (OSError, ValueError, KeyError, TypeError): return print("pilot_invalid:no_pilot_start") or 1
            r = pilot_check(samples(state), events(state), start)
            r["verdict"] = r["verdict"] if now >= start + 7 * DAY else "pilot_invalid:incomplete"
        print("\n".join(f"{k}={v}" for k, v in r.items()))
        return 0 if r["verdict"] in ("pass", "pilot_valid") else 1
    lines = alerts(state, now)
    print("\n".join(lines or ["no_alerts"]))
    return 1 if lines else 0
if __name__ == "__main__":
    sys.exit(main())
