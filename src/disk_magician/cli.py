#!/usr/bin/env python3
import os
import sys
import subprocess
from pathlib import Path

def _build_orchestrator_env(source_env=None, platform=None):
    env = dict(os.environ if source_env is None else source_env)
    if (platform or sys.platform) == "darwin":
        env["BASH_COMPAT"] = "5.0"
    return env

def get_orchestrator_path() -> Path:
    # Locate disk_magician.sh
    pkg_dir = Path(__file__).parent
    
    # 1. Check in the package directory
    orchestrator = pkg_dir / "disk_magician.sh"
    if orchestrator.exists():
        return orchestrator
        
    # 2. Check in the repository root (for editable installs/dev)
    root_dir = pkg_dir.parent.parent
    orchestrator = root_dir / "disk_magician.sh"
    if orchestrator.exists():
        return orchestrator
        
    raise FileNotFoundError("Could not locate disk_magician.sh orchestrator script.")

def main():
    try:
        orchestrator = get_orchestrator_path()
    except FileNotFoundError as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)

    args = sys.argv[1:]
    # Dispatches all diskm subcommands (including cleanup-task-scratch) via disk_magician.sh.
    
    # Handle environment variables
    # DISK_MAGICIAN_AUTO_CLEAN or DISK_MAGICIAN_SAFE_AUTO
    auto_clean_env = os.environ.get("DISK_MAGICIAN_AUTO_CLEAN") or os.environ.get("DISK_MAGICIAN_SAFE_AUTO")
    
    # If the user ran 'clean' command:
    # - If DISK_MAGICIAN_AUTO_CLEAN=1, safe cleanups can proceed without interactive confirmation.
    # - If the variable is NOT set, safe cleanups must default to dry-run/preview mode unless the user explicitly passes the clean command.
    # Note: running "disk-magician clean" is explicitly passing the clean command.
    # But if they run it automatically or we want to double check:
    # If they run "clean" and we want to allow it:
    
    # Ensure environment variables are passed along
    env = _build_orchestrator_env()
    if args and args[0] in ("scratch-new", "scratch_new"):
        helper = orchestrator.parent / "scripts" / "scratch_producer_pids.py"
        try:
            producer_pids = subprocess.run(
                [sys.executable, str(helper), str(os.getppid())],
                check=True, capture_output=True, text=True, timeout=3,
            ).stdout.strip()
            if not producer_pids:
                raise ValueError("empty producer identity")
            env["DISK_MAGICIAN_SCRATCH_PRODUCER_PIDS"] = producer_pids
        except (OSError, ValueError, subprocess.SubprocessError) as exc:
            print(f"Error: scratch producer identity unavailable: {exc}", file=sys.stderr)
            sys.exit(75)
    if auto_clean_env:
        env["DISK_MAGICIAN_AUTO_CLEAN"] = auto_clean_env

    # Run the shell orchestrator
    try:
        result = subprocess.run(
            ["bash", str(orchestrator)] + args,
            env=env,
            check=False
        )
        sys.exit(result.returncode)
    except KeyboardInterrupt:
        print("\nOperation aborted by user.", file=sys.stderr)
        sys.exit(130)

if __name__ == "__main__":
    main()
