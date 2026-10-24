#!/usr/bin/env python3
"""Print the winning config path: env -> XDG config -> state repo -> packaged template.

Design: roadmap/2026-07-21-generic-split-state-repo-design.md (env-first is a repo-wide
contract; see LARGE_TMP_* precedent in scripts/cleanup_tmp.sh).
"""
import json
import os
import pathlib
import sys
from typing import Optional


_SNAPSHOT_OVERLAY_FIELDS = {"snapshot_measure", "state_repo_path"}


def _is_snapshot_overlay(path: pathlib.Path) -> bool:
    """Return whether *path* is only the user-owned snapshot tuning overlay.

    ``snapshot_measure`` was deliberately introduced as an additive user
    setting.  Its presence must not hide the state-repo config that owns the
    monitored directory/glob inventory.  Invalid JSON is left to the normal
    consumer to reject rather than silently falling through.
    """
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError):
        return False
    return (
        isinstance(data, dict)
        and bool(data)
        and set(data).issubset(_SNAPSHOT_OVERLAY_FIELDS)
    )


def configured_state_repo(path: pathlib.Path, home: pathlib.Path) -> Optional[pathlib.Path]:
    """Read the optional state-repo location from a user config file."""
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError):
        return None
    configured = data.get("state_repo_path") if isinstance(data, dict) else None
    if not isinstance(configured, str) or not configured:
        return None
    expanded = pathlib.Path(os.path.expanduser(configured))
    return expanded if expanded.is_absolute() else home / expanded

def resolve() -> str:
    explicit = os.environ.get("DISK_MAGICIAN_CONFIG")
    if explicit:
        # An explicit override is authoritative even when it is unusable.  Do
        # not silently edit an XDG/state/template fallback in its place.
        return explicit if os.path.isfile(explicit) else ""
    home = pathlib.Path(os.environ.get("HOME", "/"))
    xdg_cfg = pathlib.Path(os.environ.get("XDG_CONFIG_HOME", home / ".config"))
    overlay = xdg_cfg / "disk-magician" / "config.json"
    if overlay.is_file() and not _is_snapshot_overlay(overlay):
        return str(overlay)
    configured_state = configured_state_repo(overlay, home) if overlay.is_file() else None
    state = pathlib.Path(os.environ.get(
        "DISK_MAGICIAN_STATE_REPO",
        configured_state or pathlib.Path(os.environ.get("XDG_STATE_HOME", home / ".local/state")) / "disk-magician",
    ))
    p = state / "config" / "config.json"
    if p.is_file():
        return str(p)
    here = pathlib.Path(__file__).resolve().parent.parent
    for cand in (here / "config.json", here / "config.json.template"):
        if cand.is_file():
            return str(cand)
    return ""

if __name__ == "__main__":
    path = resolve()
    if not path:
        sys.exit(1)
    print(path)
