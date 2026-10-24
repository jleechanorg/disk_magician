#!/usr/bin/env python3
"""Print the winning state-repo directory (the grandfathering knob): design
roadmap/2026-07-21-generic-split-state-repo-design.md §Grandfathering.

Precedence: DISK_MAGICIAN_STATE_REPO env (explicit override, same contract
scripts/state_repo.sh already honors) -> `state_repo_path` key in whichever
config file scripts/resolve_config.py picks as the chain winner -> XDG state
default. Reusing resolve_config.resolve() (rather than re-implementing the
env->XDG->state-repo->packaged chain) means a single config file is the one
source of truth for both the app's general settings and this one key.
"""
import os, pathlib, sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import resolve_config  # noqa: E402


def resolve() -> str:
    explicit = os.environ.get("DISK_MAGICIAN_STATE_REPO")
    if explicit:
        return explicit
    home = pathlib.Path(os.environ.get("HOME", "/"))
    cfg_path = resolve_config.resolve()
    if cfg_path:
        try:
            configured = resolve_config.configured_state_repo(pathlib.Path(cfg_path), home)
            if configured is not None:
                expanded = configured
                # A relative state_repo_path would resolve against the caller's
                # CWD — repo root in dev, but `/` under launchd (cursor-agent
                # adversarial finding 2026-07-21). Anchor it to $HOME so the
                # location is deterministic regardless of who invokes the tool.
                if not expanded.is_absolute():
                    expanded = home / expanded
                return str(expanded)
        except (OSError, ValueError, TypeError):
            pass
    # A snapshot-only XDG overlay is intentionally not the general config
    # winner when no state config exists, but it still owns this grandfathering
    # knob.  Do this only after the effective config path so an explicit
    # DISK_MAGICIAN_CONFIG remains authoritative.
    if not os.environ.get("DISK_MAGICIAN_CONFIG"):
        xdg_cfg = pathlib.Path(os.environ.get("XDG_CONFIG_HOME", home / ".config"))
        xdg_path = xdg_cfg / "disk-magician" / "config.json"
        if xdg_path.is_file():
            configured = resolve_config.configured_state_repo(xdg_path, home)
            if configured is not None:
                return str(configured)
    state_home = pathlib.Path(os.environ.get("XDG_STATE_HOME", home / ".local/state"))
    return str(state_home / "disk-magician")


if __name__ == "__main__":
    print(resolve())
