#!/usr/bin/env python3
"""Strictly read-only single-pass every-file 48-hour scanner.

Walks every file and directory under the requested roots (never following symlinks,
never opening file contents, staying on each root's st_dev via --xdev), applying
ONLY the 48-hour mtime rule (mtime < cutoff_epoch => >48h; mtime >= cutoff_epoch => <=48h).

For EVERY directory visited, computes exact bottom-up rollups:
  - alloc_bytes (st_blocks * 512, hardlink-deduped within shard + sidecar for global dedup)
  - apparent_bytes (st_size, hardlink-deduped)
  - raw_alloc_bytes (without hardlink dedup, for local directory navigation)
  - files_count, dirs_count, symlinks_count
  - gt48h_alloc_bytes, gt48h_apparent_bytes, gt48h_files
  - le48h_alloc_bytes, le48h_apparent_bytes, le48h_files
  - latest_mtime (float epoch of newest file/symlink anywhere inside the directory subtree)
  - latest_file (exact path of the newest file/symlink inside the directory subtree)
  - oldest_mtime (float epoch of oldest file/symlink inside the directory subtree)
  - wholly_gt48h (True iff files_count > 0 and le48h_files == 0 and tainted_by_error == False)
"""
from __future__ import annotations

import argparse
import heapq
import json
import os
import stat
import struct
import time
from pathlib import Path

MIB = 1024 * 1024
DIR_EMIT_THRESHOLD = 100 * MIB          # Emit every directory >= 100 MiB (alloc or apparent)
MAXIMAL_OLD_EMIT_THRESHOLD = 25 * MIB   # Emit every maximal wholly->48h subtree >= 25 MiB


def display_path(p: str) -> str:
    for prefix, repl in (
        ("/System/Volumes/Data/Users/", "/Users/"),
        ("/System/Volumes/Data/Users", "/Users"),
        ("/System/Volumes/Data/private/", "/private/"),
        ("/System/Volumes/Data/private", "/private"),
        ("/System/Volumes/Data/Library/", "/Library/"),
        ("/System/Volumes/Data/Library", "/Library"),
        ("/System/Volumes/Data/Applications/", "/Applications/"),
        ("/System/Volumes/Data/Applications", "/Applications"),
        ("/System/Volumes/Data/opt/", "/opt/"),
        ("/System/Volumes/Data/opt", "/opt"),
    ):
        if p == prefix:
            return repl
        if prefix.endswith("/") and p.startswith(prefix):
            return repl + p[len(prefix):]
    return p


def scan_shards(
    specs: list[tuple[str, set[str]]],
    cutoff_epoch: float,
    xdev: bool,
    hardlink_bin_path: Path | None,
) -> dict:
    t_start = time.time()
    seen_hardlinks: set[tuple[int, int]] = set()
    hl_fh = open(hardlink_bin_path, "wb") if hardlink_bin_path else None

    total_alloc = 0
    total_app = 0
    total_raw_alloc = 0
    total_files = 0
    total_symlinks = 0
    total_dirs = 0
    total_special = 0

    gt48_alloc = 0
    gt48_app = 0
    gt48_files = 0

    le48_alloc = 0
    le48_app = 0
    le48_files = 0

    errors: list[dict] = []
    skipped_mountpoints: list[str] = []
    dirs_ge_threshold: list[dict] = []
    maximal_wholly_gt48h_ge25m: list[dict] = []
    small_maximal_wholly_gt48h_count = 0
    small_maximal_wholly_gt48h_alloc = 0
    small_maximal_wholly_gt48h_app = 0

    # Direct >48h files sitting inside mixed (not wholly >48h) directories
    mixed_dir_direct_gt48h_files = 0
    mixed_dir_direct_gt48h_alloc = 0
    mixed_dir_direct_gt48h_app = 0

    top_gt48h_files_heap: list[tuple[int, int, float, str]] = []  # (alloc, app, mtime, path)
    top_le48h_files_heap: list[tuple[int, int, float, str]] = []

    for root_path, exclude_names in specs:
        root_path = os.path.abspath(root_path)
        try:
            root_st = os.lstat(root_path)
        except OSError as exc:
            errors.append({"path": display_path(root_path), "raw_path": root_path, "errno": exc.errno, "error": exc.strerror or str(exc)})
            continue

        if not stat.S_ISDIR(root_st.st_mode):
            continue

        root_dev = root_st.st_dev

        # Iterative postorder stack frames:
        # [dir_path, is_root, child_dirs_to_visit, stats_list, child_wholly_old_records, lt100m_children_alloc, lt100m_children_app, lt100m_children_gt48_alloc]
        # stats_list = [alloc, app, raw_alloc, files, symlinks, dirs, gt48_alloc, gt48_app, gt48_files, le48_alloc, le48_app, le48_files, latest_mtime, latest_file, tainted, direct_gt48_files, direct_gt48_alloc, direct_gt48_app]
        stack: list[list] = [[root_path, True, None, None, [], 0, 0, 0]]

        while stack:
            frame = stack[-1]
            dpath, is_root, pending_children, st_acc, child_old_recs, lt100_alloc, lt100_app, lt100_gt48_alloc = frame

            if pending_children is None:
                # First visit to dpath: scandir once
                total_dirs += 1
                d_alloc = 0
                d_app = 0
                d_raw_alloc = 0
                d_files = 0
                d_syms = 0
                d_gt48_alloc = 0
                d_gt48_app = 0
                d_gt48_files = 0
                d_le48_alloc = 0
                d_le48_app = 0
                d_le48_files = 0
                d_latest_mtime = -1.0
                d_latest_file = ""
                d_tainted = False
                subdirs: list[str] = []

                try:
                    with os.scandir(dpath) as it:
                        for entry in it:
                            name = entry.name
                            if is_root and name in exclude_names:
                                continue
                            epath = entry.path
                            try:
                                est = entry.stat(follow_symlinks=False)
                            except OSError as exc:
                                d_tainted = True
                                errors.append({
                                    "path": display_path(epath),
                                    "raw_path": epath,
                                    "errno": exc.errno,
                                    "error": exc.strerror or str(exc),
                                })
                                continue

                            mode = est.st_mode
                            if stat.S_ISDIR(mode):
                                if xdev and est.st_dev != root_dev:
                                    skipped_mountpoints.append(epath)
                                    continue
                                subdirs.append(epath)
                            elif stat.S_ISREG(mode) or stat.S_ISLNK(mode):
                                is_sym = stat.S_ISLNK(mode)
                                raw_al = est.st_blocks * 512
                                raw_ap = est.st_size
                                mtime = est.st_mtime

                                dedup_al = raw_al
                                dedup_ap = raw_ap
                                if est.st_nlink > 1:
                                    key = (est.st_dev, est.st_ino)
                                    if seen_inodes_set(seen_hardlinks, key):
                                        dedup_al = 0
                                        dedup_ap = 0
                                    elif hl_fh is not None:
                                        # Record unique multi-link inode for cross-shard coordinator dedup
                                        hl_fh.write(struct.pack("<QQQQd", est.st_dev, est.st_ino, raw_al, raw_ap, float(mtime)))

                                d_raw_alloc += raw_al
                                d_alloc += dedup_al
                                d_app += dedup_ap
                                if is_sym:
                                    d_syms += 1
                                else:
                                    d_files += 1

                                if mtime > d_latest_mtime:
                                    d_latest_mtime = mtime
                                    d_latest_file = epath

                                if mtime < cutoff_epoch:
                                    d_gt48_alloc += dedup_al
                                    d_gt48_app += dedup_ap
                                    d_gt48_files += 1
                                    if not is_sym and raw_ap >= 10 * MIB:
                                        item = (raw_al, raw_ap, mtime, display_path(epath))
                                        if len(top_gt48h_files_heap) < 60:
                                            heapq.heappush(top_gt48h_files_heap, item)
                                        elif item > top_gt48h_files_heap[0]:
                                            heapq.heapreplace(top_gt48h_files_heap, item)
                                else:
                                    d_le48_alloc += dedup_al
                                    d_le48_app += dedup_ap
                                    d_le48_files += 1
                                    if not is_sym and raw_ap >= 25 * MIB:
                                        item = (raw_al, raw_ap, mtime, display_path(epath))
                                        if len(top_le48h_files_heap) < 40:
                                            heapq.heappush(top_le48h_files_heap, item)
                                        elif item > top_le48h_files_heap[0]:
                                            heapq.heapreplace(top_le48h_files_heap, item)
                            else:
                                total_special += 1
                except OSError as exc:
                    d_tainted = True
                    errors.append({
                        "path": display_path(dpath),
                        "raw_path": dpath,
                        "errno": exc.errno,
                        "error": exc.strerror or str(exc),
                    })

                total_alloc += d_alloc
                total_app += d_app
                total_raw_alloc += d_raw_alloc
                total_files += d_files
                total_symlinks += d_syms
                gt48_alloc += d_gt48_alloc
                gt48_app += d_gt48_app
                gt48_files += d_gt48_files
                le48_alloc += d_le48_alloc
                le48_app += d_le48_app
                le48_files += d_le48_files

                # Keep direct-file stats in slots 15..19 so parent rollup knows direct files too
                frame[2] = subdirs
                frame[3] = [
                    d_alloc, d_app, d_raw_alloc, d_files, d_syms, 1,
                    d_gt48_alloc, d_gt48_app, d_gt48_files,
                    d_le48_alloc, d_le48_app, d_le48_files,
                    d_latest_mtime, d_latest_file, d_tainted,
                    d_gt48_files, d_gt48_alloc, d_gt48_app,
                    d_alloc, d_app,  # direct_files_alloc, direct_files_app
                ]

            if frame[2]:
                next_child = frame[2].pop()
                stack.append([next_child, False, None, None, [], 0, 0, 0])
                continue

            # All children of dpath have finished! Finalize dpath.
            stack.pop()
            s = frame[3]
            c_alloc, c_app, c_raw_alloc, c_files, c_syms, c_dirs = s[0], s[1], s[2], s[3], s[4], s[5]
            c_gt48_alloc, c_gt48_app, c_gt48_files = s[6], s[7], s[8]
            c_le48_alloc, c_le48_app, c_le48_files = s[9], s[10], s[11]
            c_latest_mtime, c_latest_file, c_tainted = s[12], s[13], s[14]
            direct_gt48_f, direct_gt48_al, direct_gt48_ap = s[15], s[16], s[17]
            direct_al, direct_ap = s[18], s[19]

            total_entries = c_files + c_syms
            wholly_old = (total_entries > 0 and c_le48_files == 0 and not c_tainted)

            if not wholly_old:
                # dpath is mixed or fresh (or empty/tainted): any child that WAS wholly_old is MAXIMAL!
                for rec in frame[4]:
                    if rec["alloc_bytes"] >= MAXIMAL_OLD_EMIT_THRESHOLD or rec["apparent_bytes"] >= MAXIMAL_OLD_EMIT_THRESHOLD:
                        maximal_wholly_gt48h_ge25m.append(rec)
                    else:
                        small_maximal_wholly_gt48h_count += 1
                        small_maximal_wholly_gt48h_alloc += rec["alloc_bytes"]
                        small_maximal_wholly_gt48h_app += rec["apparent_bytes"]
                if direct_gt48_f > 0:
                    mixed_dir_direct_gt48h_files += direct_gt48_f
                    mixed_dir_direct_gt48h_alloc += direct_gt48_al
                    mixed_dir_direct_gt48h_app += direct_gt48_ap

            if c_alloc >= DIR_EMIT_THRESHOLD or c_app >= DIR_EMIT_THRESHOLD or is_root:
                dirs_ge_threshold.append({
                    "path": display_path(dpath),
                    "raw_path": dpath,
                    "is_shard_root": is_root,
                    "excluded_children": sorted(exclude_names) if is_root and exclude_names else [],
                    "alloc_bytes": c_alloc,
                    "apparent_bytes": c_app,
                    "raw_alloc_bytes": c_raw_alloc,
                    "files": c_files,
                    "symlinks": c_syms,
                    "dirs": c_dirs,
                    "gt48h_alloc_bytes": c_gt48_alloc,
                    "gt48h_apparent_bytes": c_gt48_app,
                    "gt48h_files": c_gt48_files,
                    "le48h_alloc_bytes": c_le48_alloc,
                    "le48h_apparent_bytes": c_le48_app,
                    "le48h_files": c_le48_files,
                    "wholly_gt48h": wholly_old,
                    "tainted_by_error": c_tainted,
                    "latest_mtime": round(c_latest_mtime, 3) if c_latest_mtime >= 0 else None,
                    "latest_file": display_path(c_latest_file) if c_latest_file else None,
                    "direct_files_alloc_bytes": direct_al,
                    "direct_files_apparent_bytes": direct_ap,
                    "lt100m_subdirs_alloc_bytes": frame[5],
                    "lt100m_subdirs_apparent_bytes": frame[6],
                    "lt100m_subdirs_gt48h_alloc_bytes": frame[7],
                })

            if stack:
                parent = stack[-1]
                ps = parent[3]
                ps[0] += c_alloc
                ps[1] += c_app
                ps[2] += c_raw_alloc
                ps[3] += c_files
                ps[4] += c_syms
                ps[5] += c_dirs
                ps[6] += c_gt48_alloc
                ps[7] += c_gt48_app
                ps[8] += c_gt48_files
                ps[9] += c_le48_alloc
                ps[10] += c_le48_app
                ps[11] += c_le48_files
                if c_latest_mtime > ps[12]:
                    ps[12] = c_latest_mtime
                    ps[13] = c_latest_file
                if c_tainted:
                    ps[14] = True
                if wholly_old:
                    parent[4].append({
                        "path": display_path(dpath),
                        "alloc_bytes": c_alloc,
                        "apparent_bytes": c_app,
                        "raw_alloc_bytes": c_raw_alloc,
                        "files": c_files + c_syms,
                        "latest_mtime": round(c_latest_mtime, 3) if c_latest_mtime >= 0 else None,
                        "latest_file": display_path(c_latest_file) if c_latest_file else None,
                    })
                if c_alloc < DIR_EMIT_THRESHOLD and c_app < DIR_EMIT_THRESHOLD:
                    parent[5] += c_alloc
                    parent[6] += c_app
                    parent[7] += c_gt48_alloc
            else:
                # Top-level root itself was wholly >48h!
                if wholly_old:
                    rec = {
                        "path": display_path(dpath),
                        "alloc_bytes": c_alloc,
                        "apparent_bytes": c_app,
                        "raw_alloc_bytes": c_raw_alloc,
                        "files": c_files + c_syms,
                        "latest_mtime": round(c_latest_mtime, 3) if c_latest_mtime >= 0 else None,
                        "latest_file": display_path(c_latest_file) if c_latest_file else None,
                    }
                    if c_alloc >= MAXIMAL_OLD_EMIT_THRESHOLD or c_app >= MAXIMAL_OLD_EMIT_THRESHOLD:
                        maximal_wholly_gt48h_ge25m.append(rec)
                    else:
                        small_maximal_wholly_gt48h_count += 1
                        small_maximal_wholly_gt48h_alloc += c_alloc
                        small_maximal_wholly_gt48h_app += c_app

    if hl_fh is not None:
        hl_fh.close()

    elapsed = round(time.time() - t_start, 3)
    dirs_ge_threshold.sort(key=lambda r: (r["alloc_bytes"], r["apparent_bytes"]), reverse=True)
    maximal_wholly_gt48h_ge25m.sort(key=lambda r: (r["alloc_bytes"], r["apparent_bytes"]), reverse=True)
    top_gt48 = sorted(top_gt48h_files_heap, reverse=True)
    top_le48 = sorted(top_le48h_files_heap, reverse=True)

    return {
        "cutoff_epoch": cutoff_epoch,
        "elapsed_seconds": elapsed,
        "summary": {
            "alloc_bytes": total_alloc,
            "apparent_bytes": total_app,
            "raw_alloc_bytes": total_raw_alloc,
            "files": total_files,
            "symlinks": total_symlinks,
            "dirs": total_dirs,
            "special_entries": total_special,
            "unique_multilink_inodes_in_shard": len(seen_hardlinks),
            "gt48h_alloc_bytes": gt48_alloc,
            "gt48h_apparent_bytes": gt48_app,
            "gt48h_files": gt48_files,
            "le48h_alloc_bytes": le48_alloc,
            "le48h_apparent_bytes": le48_app,
            "le48h_files": le48_files,
            "maximal_wholly_gt48h_ge25m_count": len(maximal_wholly_gt48h_ge25m),
            "maximal_wholly_gt48h_ge25m_alloc_bytes": sum(r["alloc_bytes"] for r in maximal_wholly_gt48h_ge25m),
            "maximal_wholly_gt48h_ge25m_apparent_bytes": sum(r["apparent_bytes"] for r in maximal_wholly_gt48h_ge25m),
            "small_maximal_wholly_gt48h_lt25m_count": small_maximal_wholly_gt48h_count,
            "small_maximal_wholly_gt48h_lt25m_alloc_bytes": small_maximal_wholly_gt48h_alloc,
            "small_maximal_wholly_gt48h_lt25m_apparent_bytes": small_maximal_wholly_gt48h_app,
            "mixed_dir_direct_gt48h_files": mixed_dir_direct_gt48h_files,
            "mixed_dir_direct_gt48h_alloc_bytes": mixed_dir_direct_gt48h_alloc,
            "mixed_dir_direct_gt48h_apparent_bytes": mixed_dir_direct_gt48h_app,
            "errors_count": len(errors),
            "skipped_mountpoints": skipped_mountpoints,
        },
        "top_gt48h_files": [
            {"alloc_bytes": al, "apparent_bytes": ap, "mtime": round(mt, 3), "path": p}
            for al, ap, mt, p in top_gt48
        ],
        "top_le48h_files": [
            {"alloc_bytes": al, "apparent_bytes": ap, "mtime": round(mt, 3), "path": p}
            for al, ap, mt, p in top_le48
        ],
        "maximal_wholly_gt48h_dirs_ge25m": maximal_wholly_gt48h_ge25m,
        "dirs_ge_100m": dirs_ge_threshold,
        "errors": errors,
    }


def seen_inodes_set(s: set[tuple[int, int]], key: tuple[int, int]) -> bool:
    if key in s:
        return True
    s.add(key)
    return False


def main() -> int:
    ap = argparse.ArgumentParser(
        description="Strictly read-only single-pass every-file 48-hour scanner with per-directory latest_file rollup."
    )
    cutoff_group = ap.add_mutually_exclusive_group()
    cutoff_group.add_argument(
        "--cutoff-epoch",
        type=float,
        default=None,
        help="Explicit cutoff epoch seconds (files with mtime < cutoff are >48h).",
    )
    cutoff_group.add_argument(
        "--cutoff-hours",
        type=float,
        default=48.0,
        help="Age threshold in hours from now (default: 48.0).",
    )
    ap.add_argument("--spec", action="append", required=True,
                    help="PATH or PATH::excl1,excl2 (top-level child names to skip under PATH)")
    ap.add_argument("--out-json", type=Path, required=True)
    ap.add_argument("--out-hardlinks", type=Path, default=None)
    ap.add_argument("--no-xdev", action="store_true")
    args = ap.parse_args()

    cutoff_epoch = (
        args.cutoff_epoch
        if args.cutoff_epoch is not None
        else time.time() - (args.cutoff_hours * 3600.0)
    )

    specs: list[tuple[str, set[str]]] = []
    for raw in args.spec:
        if "::" in raw:
            p, ex = raw.split("::", 1)
            excl = {x for x in ex.split(",") if x}
        else:
            p, excl = raw, set()
        specs.append((p, excl))

    args.out_json.parent.mkdir(parents=True, exist_ok=True)
    if args.out_hardlinks:
        args.out_hardlinks.parent.mkdir(parents=True, exist_ok=True)

    res = scan_shards(specs, cutoff_epoch, not args.no_xdev, args.out_hardlinks)
    args.out_json.write_text(json.dumps(res, indent=2) + "\n")
    s = res["summary"]
    print(
        f"DONE elapsed={res['elapsed_seconds']}s files={s['files']} dirs={s['dirs']} "
        f"alloc_gib={s['alloc_bytes']/1024**3:.3f} gt48h_alloc_gib={s['gt48h_alloc_bytes']/1024**3:.3f} "
        f"le48h_alloc_gib={s['le48h_alloc_bytes']/1024**3:.3f} errors={s['errors_count']}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
