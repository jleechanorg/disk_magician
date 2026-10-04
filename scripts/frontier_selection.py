#!/usr/bin/env python3
"""Select the frontier report shared by snapshot producers.

The explicit JSON override is strict: a missing, corrupt, or future override
never falls through to another source.  Without an override, root and user
state candidates are ranked by fresh+complete, fresh, then newest timestamp.
"""

import argparse
import datetime
import json
import os
import sys


STALE_HOURS = 36.0
TIMESTAMP_FORMAT = "%Y-%m-%dT%H:%M:%SZ"


def _load(path, now):
    if not path or not os.path.isfile(path) or not os.access(path, os.R_OK):
        return None
    try:
        with open(path) as fh:
            data = json.load(fh)
        if not isinstance(data, dict):
            return None
        captured_at = data["captured_at"]
        timestamp = datetime.datetime.strptime(captured_at, TIMESTAMP_FORMAT).replace(
            tzinfo=datetime.timezone.utc
        )
    except (OSError, KeyError, TypeError, ValueError, json.JSONDecodeError):
        return None

    age_hours = (now - timestamp).total_seconds() / 3600.0
    if age_hours < 0:
        return None
    envelope = data.get("coverage_envelope")
    if isinstance(envelope, dict) and "complete" in envelope:
        # Match the renderer's strict contract: only JSON true proves
        # completeness; truthy strings/numbers must not win the ranking.
        complete = envelope["complete"] is True
    else:
        complete = data.get("mode") == "complete"
    return {
        "path": path,
        "timestamp": timestamp,
        "fresh": age_hours <= STALE_HOURS,
        "complete": complete,
    }


def select_frontier(root_path, state_path, *, explicit_json=None, explicit_last=None, now=None):
    """Return the selected path, or ``None`` when no usable report exists."""
    now = now or datetime.datetime.now(datetime.timezone.utc)

    # JSON is the canonical explicit override.  LAST is retained as a strict,
    # lower-priority compatibility alias; neither may fall through on failure.
    if explicit_json:
        selected = _load(explicit_json, now)
        return selected["path"] if selected else None
    if explicit_last:
        selected = _load(explicit_last, now)
        return selected["path"] if selected else None

    candidates = [
        candidate
        for candidate in (_load(root_path, now), _load(state_path, now))
        if candidate is not None
    ]
    if not candidates:
        return None

    def score(candidate):
        return (
            1 if candidate["fresh"] and candidate["complete"] else 0,
            1 if candidate["fresh"] else 0,
            candidate["timestamp"].timestamp(),
        )

    return max(candidates, key=score)["path"]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", required=True)
    parser.add_argument("--state", required=True)
    args = parser.parse_args()
    selected = select_frontier(
        args.root,
        args.state,
        explicit_json=os.environ.get("DISK_MAGICIAN_FRONTIER_JSON") or None,
        explicit_last=os.environ.get("DISK_MAGICIAN_FRONTIER_LAST") or None,
    )
    if selected:
        print(selected)
    return 0


if __name__ == "__main__":
    sys.exit(main())
