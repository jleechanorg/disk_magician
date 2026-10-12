#!/usr/bin/env python3
"""diskm admit: decide on zone(df_free - est - margin) under state.lock; one event line per call (spec §7.1)."""
import argparse, fcntl, json, os, subprocess, sys, time, uuid, resolve_config
from pathlib import Path
GIB, ZONES, EMERGENCY = 1 << 30, ((100, "GREEN"), (60, "ORANGE"), (30, "RED"), (15, "BLACK")), {"BLACK": 76, "FLOOR": 75}
D2 = False  # decision_approved admission_enforcement arrives with the policy PR; until then observe-only, rc 0
def zone(free_gb):
    return next((name for floor, name in ZONES if free_gb >= floor), "FLOOR")
def decide(stage, free_gb, est_gb, margin_gb, over_budget, d2):
    z = "FLOOR" if free_gb - est_gb < 15 else zone(free_gb - est_gb - margin_gb)
    if z in EMERGENCY or z == "GREEN" or stage == "observe":
        return z, (EMERGENCY[z] if d2 else 10) if z in EMERGENCY else 0
    return z, 75 if z == "RED" and stage != "warn" or over_budget and stage == "refuse_orange" else 10
def admit(a, budgets, state, now):
    last = json.loads((state / "budget.json").read_text()) if (state / "budget.json").is_file() else {}
    cls, age, degraded = last.get("classes", {}).get(a.cls, {}), now - last.get("zone_at", 0), None
    over = now - cls.get("measured_at", 0) <= 3 * 3600 and cls.get("used_gb", 0) > cls.get("budget_gb", 1e9)
    try:
        out = subprocess.run([os.environ.get("DISK_MAGICIAN_DF_BIN", "df"), "-k", str(Path.home())],
                             capture_output=True, text=True, timeout=5, check=True).stdout
        free = int(out.splitlines()[-1].split()[3]) * 1024
    except (OSError, ValueError, IndexError, subprocess.SubprocessError):
        free = last.get("free_bytes") if age <= 900 else None
        degraded = "stale_df" if free is not None else "blind"
        print(f"admission_degraded:{degraded}", file=sys.stderr)
    if free is not None:
        z, decision = decide(budgets["enforcement"], free / GIB, a.est_gb, budgets["concurrency_margin_gb"], over, D2)
    else:  # blind -> 10, unless the last zone within 60 min was BLACK/FLOOR
        z = last.get("zone") if last.get("zone") in EMERGENCY and age <= 3600 else None
        decision = EMERGENCY[z] if z and D2 else 10
    event = dict(event="admit", admit_id=str(uuid.uuid4()), at=now, est_bytes=int(a.est_gb * GIB), decision=decision,
                 zone=z, df_free_bytes=free, degraded=degraded, **{"class": a.cls}, **{k: getattr(a, k) for k in
                 ("producer", "source", "dest", "ci_job", "tool_use_id")})
    try:
        if not a.dry_run:
            with open(state / "admission" / "events.jsonl", "a") as log:
                log.write(json.dumps(event) + "\n")
    except OSError:
        print("admission_degraded:log", file=sys.stderr)
    print(f"admit_id={event['admit_id']}")
    return decision if D2 else 0
def main():
    p, cfg = argparse.ArgumentParser(prog="diskm admit"), json.loads(Path(resolve_config.resolve()).read_text())
    budgets = cfg.get("budgets") or json.loads((Path(__file__).resolve().parents[1] / "config.json.template").read_text())["budgets"]
    for flag in ("--producer", "--dest", "--source", "--ci-job", "--tool-use-id"):
        p.add_argument(flag)
    p.add_argument("--class", dest="cls", required=True, choices=sorted(budgets["classes"]))
    p.add_argument("--est-gb", type=float, required=True)
    p.add_argument("--dry-run", action="store_true")
    a, state = p.parse_args(), Path(os.environ.get("DISK_MAGICIAN_STATE_DIR", Path.home() / ".disk_magician_state"))
    (state / "admission").mkdir(parents=True, exist_ok=True)
    with open(state / "state.lock", "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        return admit(a, budgets, state, time.time())
if __name__ == "__main__":
    sys.exit(main())
