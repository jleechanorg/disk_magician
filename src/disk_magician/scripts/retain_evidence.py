#!/usr/bin/env python3
"""Copy the current frontier report into evidence/ as a timestamped file, then
prune to the newest N (design: roadmap/2026-07-21-generic-split-state-repo-design.md,
"Snapshot/commit flow" — evidence retention so the state repo cannot itself
become a leak). shutil.copy2 (not copyfile) so the copy preserves the source
mtime, keeping the prune's newest-N-by-mtime ordering meaningful. Python, not a
shell pipeline, per the grep-shim pipeline-corruption precedent (memory
feedback_2026-07-20_grep_shim_truncates_pipelines_use_python_parsing.md).
"""
import argparse, datetime, glob, os, shutil, sys


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--frontier", required=True)
    p.add_argument("--evidence-dir", required=True)
    p.add_argument("--keep", type=int, required=True)
    args = p.parse_args()

    os.makedirs(args.evidence_dir, exist_ok=True)

    if os.path.isfile(args.frontier):
        mtime = os.path.getmtime(args.frontier)
        stamp = datetime.datetime.utcfromtimestamp(mtime).strftime("%Y%m%dT%H%M%SZ")
        dest = os.path.join(args.evidence_dir, f"frontier-{stamp}.json")
        if not os.path.exists(dest):
            shutil.copy2(args.frontier, dest)

    files = sorted(
        glob.glob(os.path.join(args.evidence_dir, "frontier-*.json")),
        key=os.path.getmtime,
        reverse=True,
    )
    for stale in files[args.keep:]:
        os.remove(stale)
    return 0


if __name__ == "__main__":
    sys.exit(main())
