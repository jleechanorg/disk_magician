#!/usr/bin/env python3
"""Carry-forward store for last-good snapshot measurements.

Subcommands: from-tsv, merge, update. State file maps key ->
{kb, measured_at, path, source}. Only fresh non-null values are stored; a timed-out
key is carried while its last-good value is young enough, otherwise it is reported
unmeasured. A missing measurement is never turned into zero. Glob keys and the
dynamic lc_* keys are never carried (their key set changes run to run).
"""
import argparse
import datetime
import json
import os
import sys

FMT = "%Y-%m-%dT%H:%M:%SZ"


def parse_ts(s):
    return datetime.datetime.strptime(s, FMT).replace(tzinfo=datetime.timezone.utc)


def is_glob(path):
    return any(c in (path or "") for c in "*?[")


def carryable(key, path):
    return not key.startswith("lc_") and not is_glob(path)


def load_state(path, now):
    try:
        with open(path) as f:
            data = json.load(f)
        if not isinstance(data, dict):
            raise ValueError("state is not an object")
        return data
    except FileNotFoundError:
        return {}
    except (ValueError, OSError):
        try:
            os.replace(path, f"{path}.corrupt.{now.replace(':', '')}")
        except OSError:
            pass
        return {}


def write_state(path, data):
    tmp = f"{path}.tmp.{os.getpid()}"
    with open(tmp, "w") as f:
        json.dump(data, f, indent=1, sort_keys=True)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)


def cmd_from_tsv(args):
    out = {}
    with open(args.tsv) as f:
        for line in f:
            parts = line.rstrip("\n").split("\t")
            if len(parts) != 3:
                continue
            key, val, path = parts
            out[key] = {"kb": None if val in ("null", "") else int(val), "path": path}
    print(json.dumps(out))


def cmd_update(args):
    state = load_state(args.state, args.now)
    with open(args.fresh) as f:
        fresh = json.load(f)
    for key, item in fresh.items():
        if item.get("kb") is None or not carryable(key, item.get("path", "")):
            continue
        state[key] = {"kb": item["kb"], "measured_at": args.now, "path": item["path"], "source": "du"}
    os.makedirs(os.path.dirname(os.path.abspath(args.state)), exist_ok=True)
    write_state(args.state, state)


def cmd_merge(args):
    now = parse_ts(args.now)
    state = load_state(args.state, args.now)
    with open(args.fresh) as f:
        fresh_in = json.load(f)
    with open(args.config) as f:
        config = json.load(f)
    configured = {d["key"]: d["path"] for d in config.get("monitored_dirs", [])}
    for section in ("monitored_file_globs", "monitored_globs"):
        for g in config.get(section, []):
            configured[g["key"]] = g["pattern"]

    fresh, carried, unmeasured, gap = {}, {}, [], {}
    for key, item in fresh_in.items():
        if item.get("kb") is not None:
            fresh[key] = item["kb"]
    for key, path in configured.items():
        if key in fresh:
            continue
        entry = state.get(key)
        usable = isinstance(entry, dict) and entry.get("path") == path and carryable(key, path)
        if usable:
            try:
                age = (now - parse_ts(entry["measured_at"])).total_seconds() / 3600.0
            except (KeyError, ValueError):
                usable = False
        if usable and 0 <= age <= args.max_age_hours:
            carried[key] = {"kb": entry["kb"], "age_hours": round(age, 1)}
            continue
        unmeasured.append(key)
        if usable:
            gap[key] = entry["kb"]
    print(json.dumps({"fresh": fresh, "carried": carried, "unmeasured": unmeasured,
                      "gap_estimate_kb": gap}))


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    sub = ap.add_subparsers(dest="cmd", required=True)
    t = sub.add_parser("from-tsv")
    t.add_argument("--tsv", required=True)
    t.set_defaults(fn=cmd_from_tsv)
    for name, fn in (("merge", cmd_merge), ("update", cmd_update)):
        p = sub.add_parser(name)
        p.add_argument("--state", required=True)
        p.add_argument("--fresh", required=True)
        p.add_argument("--now", required=True)
        if name == "merge":
            p.add_argument("--max-age-hours", type=float, default=72)
            p.add_argument("--config", required=True)
        p.set_defaults(fn=fn)
    args = ap.parse_args()
    args.fn(args)


if __name__ == "__main__":
    sys.exit(main())
