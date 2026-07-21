#!/usr/bin/env python3
"""history_diff.py — compare two committed ledger/topdown-5g.json snapshots
in the per-machine state repo; print bucket-level growth deltas.

Design: roadmap/2026-07-21-generic-split-state-repo-design.md ("Diff UX").
Ledger contract: roadmap/plans/2026-07-21-state-repo-pr3-plan.md
("Ledger contract this PR assumes").

No shell pipelines: all comparison/sort logic is Python (the grep-shim
pipeline-corruption class documented in this repo's operator memory).
"""
import argparse
import json
import os
import pathlib
import subprocess
import sys

GIB_KB = 1024 * 1024
LEDGER_REL_PATH = "ledger/topdown-5g.json"


class LedgerError(ValueError):
    """Ledger fails schema, the <=5 GiB ceiling, or reconciliation."""


def validate_ledger(ledger: dict, *, label: str) -> None:
    for key in ("disk_used_kb", "residual_kb", "buckets"):
        if key not in ledger:
            raise LedgerError(f"{label}: missing required key {key!r}")
    buckets = ledger["buckets"]
    if not isinstance(buckets, list):
        raise LedgerError(f"{label}: 'buckets' must be a list")
    total = 0
    for item in buckets:
        path = item.get("path")
        size = item.get("measured_kb")
        kind = item.get("kind", "dir")
        if not path or not isinstance(size, int):
            raise LedgerError(f"{label}: bucket missing path/measured_kb: {item!r}")
        if kind not in ("dir", "file"):
            raise LedgerError(f"{label}: bucket {path!r} has unknown kind {kind!r}")
        if kind == "dir" and size >= 5 * GIB_KB:
            # A directory aggregate at/above the ceiling should have been
            # broken into child buckets — refuse rather than diff a partial
            # picture. A single indivisible FILE (kind="file") is exempt: it
            # is already a leaf and cannot be decomposed further, mirroring
            # disk_frontier_scan.py's oversize_indivisible_files category.
            raise LedgerError(
                f"{label}: bucket {path!r} is {size / GIB_KB:.2f} GiB — "
                "unexplained >=5 GiB aggregate without child breakdown"
            )
        total += size
    residual = ledger["residual_kb"]
    used = ledger["disk_used_kb"]
    if total + residual != used:
        raise LedgerError(
            f"{label}: buckets ({total} KiB) + residual ({residual} KiB) "
            f"!= disk_used_kb ({used} KiB) — reconciliation failed"
        )


if __name__ == "__main__":
    pass
