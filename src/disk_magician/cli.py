#!/usr/bin/env python3
import os
import sys
import subprocess
from pathlib import Path

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
    env = os.environ.copy()
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
