#!/usr/bin/env python3
"""Print the winning config path: env -> XDG config -> state repo -> packaged template.

Design: roadmap/2026-07-21-generic-split-state-repo-design.md (env-first is a repo-wide
contract; see LARGE_TMP_* precedent in scripts/cleanup_tmp.sh).
"""
import os, pathlib, sys

def resolve() -> str:
    explicit = os.environ.get("DISK_MAGICIAN_CONFIG")
    if explicit and os.path.isfile(explicit):
        return explicit
    home = pathlib.Path(os.environ.get("HOME", "/"))
    xdg_cfg = pathlib.Path(os.environ.get("XDG_CONFIG_HOME", home / ".config"))
    p = xdg_cfg / "disk-magician" / "config.json"
    if p.is_file():
        return str(p)
    state = pathlib.Path(os.environ.get("DISK_MAGICIAN_STATE_REPO",
             pathlib.Path(os.environ.get("XDG_STATE_HOME", home / ".local/state")) / "disk-magician"))
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
