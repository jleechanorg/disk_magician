#!/usr/bin/env python3
"""diskm budget status: governor alerts from budget.json, the admission event log and observer df samples (plan Task 10)."""
import json, os, sys, time
from pathlib import Path
import disk_observer
GIB, DAY = 1 << 30, 86400
RUNBOOK = ("  runbook: identify the producer (top growing roots: admission/events.jsonl, birth audit, observer)",
           "  runbook: ask the user before pausing CI runners (launchctl bootout gui/$UID/<ezgha label>)",
           "  runbook: colima stop && colima start, then colima ssh -- sudo fstrim -av",
           "  runbook: list parked worktrees; never hand-rm")
def samples(state):  # (epoch, used B, free B) from disk_observer.jsonl{,.1,.2}
    recs = disk_observer.read_records([state / f"disk_observer.jsonl{s}" for s in (".2", ".1", "")])
    return [(r["epoch"], d["used_kb"] * 1024, d["available_kb"] * 1024) for r in recs
            if isinstance(r.get("epoch"), (int, float)) and isinstance(d := r.get("host_disk"), dict)
            and all(isinstance(d.get(k), (int, float)) for k in ("used_kb", "available_kb"))]
def events(state, lo, hi):
    try: lines = (state / "admission" / "events.jsonl").read_text().splitlines()
    except OSError: return []
    out = []
    for line in lines:
        try: e = json.loads(line)
        except ValueError: continue
        if isinstance(e, dict) and isinstance(e.get("at"), (int, float)) and lo <= e["at"] <= hi: out.append(e)
    return out
def window_max(points, width=600):  # max sum of (t, bytes) inside any [t, t + width) window
    pts = sorted(points)
    return max((sum(b for u, b in pts[i:] if u < t + width) for i, (t, _) in enumerate(pts)), default=0)
def trough(s, start):  # 7-day max of daily minimum used, None without samples
    days = [min((u for t, u, _ in s if start + d * DAY <= t < start + (d + 1) * DAY), default=None) for d in range(7)]
    return max((d for d in days if d is not None), default=None)
def alerts(state, now, margin_gb=None):
    if margin_gb is None:
        try: margin_gb = json.loads(Path(__import__("resolve_config").resolve()).read_text())["budgets"]["concurrency_margin_gb"]
        except (OSError, ValueError, KeyError, TypeError): margin_gb = 10
    s, evs, out = samples(state), events(state, now - DAY, now), []
    if any(e.get("event") == "floor_breach" for e in evs) or (s and now - s[-1][0] <= 900 and s[-1][2] < 15 * GIB):
        out += ["ALERT:floor_breach free under 15 GiB (df)", *RUNBOOK]
    if (state / "budget.json").exists():
        try: age = now - float(json.loads((state / "budget.json").read_text())["zone_at"])
        except (OSError, ValueError, KeyError, TypeError): age = float("inf")
        if age > 1800: out.append(f"ALERT:govern_stale last_tick_age={age:.0f}s")
    if any(e.get("degraded") for e in evs): out.append("ALERT:admission_degraded within 24 h")
    if any(str(e.get("event", "")).startswith("kickstart_blocked") for e in evs): out.append("ALERT:kickstart_blocked within 24 h")
    burst = window_max([(e["at"], e.get("est_bytes") or 0) for e in evs if e.get("event") == "admit"])
    if burst > margin_gb * GIB: out.append(f"ALERT:burst_over_margin admit_burst_bytes={burst}B margin={margin_gb}GiB")
    cur, old = trough(s, now - 7 * DAY), trough(s, now - 14 * DAY)
    if cur is not None and old is not None and cur > old: out.append(f"ALERT:trough_rise trough={cur}B previous={old}B")
    return out
def main(argv=None):
    if (argv if argv is not None else sys.argv[1:]) != ["status"]:
        return print("usage: diskm budget status", file=sys.stderr) or 2
    lines = alerts(Path(os.environ.get("DISK_MAGICIAN_STATE_DIR", Path.home() / ".disk_magician_state")), time.time())
    print("\n".join(lines or ["no_alerts"]))
    return 1 if lines else 0
if __name__ == "__main__":
    sys.exit(main())
