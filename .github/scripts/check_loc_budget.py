#!/usr/bin/env python3
"""Enforce repository-wide production source line budgets."""
from __future__ import annotations

import argparse
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import PurePosixPath

SOURCE_SUFFIXES = {
    ".bash", ".c", ".cc", ".cpp", ".cs", ".go", ".h", ".hpp", ".java",
    ".js", ".jsx", ".kt", ".m", ".mm", ".php", ".pl", ".py", ".rb",
    ".rs", ".sh", ".swift", ".ts", ".tsx", ".vue",
}
EXCLUDED_PARTS = {
    ".git", ".venv", "__pycache__", "build", "dist", "docs", "evidence",
    "findings_wiki", "node_modules", "roadmap", "target", "test", "tests",
    "testing", "vendor",
}
TEST_NAME = re.compile(r"(?:^test_|_test\.|\.test\.|\.spec\.)")
GENERATED_PREFIXES = ("src/disk_magician/",)


@dataclass(frozen=True)
class Blob:
    path: str
    object_id: str
    mode: str


def git(repo: str, *args: str, data: bytes | None = None) -> bytes:
    result = subprocess.run(
        ["git", "-C", repo, *args], input=data, stdout=subprocess.PIPE,
        stderr=subprocess.PIPE, check=False,
    )
    if result.returncode:
        message = result.stderr.decode("utf-8", "replace").strip()
        raise RuntimeError(f"git {' '.join(args)} failed: {message}")
    return result.stdout


def is_production_source(path: str) -> bool:
    candidate = PurePosixPath(path)
    if candidate.suffix.casefold() not in SOURCE_SUFFIXES:
        return False
    parts = candidate.parts
    if parts and parts[0] == ".github":
        return False
    if any(part.casefold() in EXCLUDED_PARTS for part in parts[:-1]):
        return False
    if any(path.startswith(prefix) for prefix in GENERATED_PREFIXES):
        return False
    if TEST_NAME.search(candidate.name.casefold()):
        return False
    return True


def tree_blobs(repo: str, revision: str) -> list[Blob]:
    records = git(repo, "ls-tree", "-r", "-z", "--full-tree", revision).split(b"\0")
    blobs: list[Blob] = []
    for record in records:
        if not record:
            continue
        metadata, raw_path = record.split(b"\t", 1)
        mode, object_type, object_id = metadata.decode("ascii").split()[:3]
        if object_type != "blob" or mode not in {"100644", "100755"}:
            continue
        path = raw_path.decode("utf-8", "surrogateescape")
        if is_production_source(path):
            blobs.append(Blob(path, object_id, mode))
    return blobs


def blob_data(repo: str, blobs: list[Blob]) -> dict[str, bytes]:
    if not blobs:
        return {}
    requests = b"".join(blob.object_id.encode("ascii") + b"\n" for blob in blobs)
    output = git(repo, "cat-file", "--batch", data=requests)
    cursor = 0
    contents: dict[str, bytes] = {}
    for blob in blobs:
        end_header = output.find(b"\n", cursor)
        if end_header < 0:
            raise RuntimeError(f"truncated git cat-file header for {blob.path}")
        header_end = end_header
        header = output[cursor:header_end].decode("ascii").split()
        cursor = header_end + 1
        if len(header) != 3 or header[1] != "blob":
            raise RuntimeError(f"git object is not a blob: {blob.path}")
        size = int(header[2])
        contents[blob.path] = output[cursor:cursor + size]
        cursor += size
        if cursor >= len(output) or output[cursor] != 10:
            raise RuntimeError(f"truncated git cat-file body for {blob.path}")
        cursor += 1
    return contents


def physical_lines(source: bytes, _path: str) -> int:
    if b"\0" in source:
        return 0
    return source.count(b"\n") + bool(source and not source.endswith(b"\n"))


def production_loc(repo: str, revision: str) -> tuple[int, int]:
    blobs = tree_blobs(repo, revision)
    contents = blob_data(repo, blobs)
    legacy = sum(
        physical_lines(contents[blob.path], blob.path)
        for blob in blobs
        if not (blob.path.startswith("rust/") and blob.path.endswith(".rs"))
    )
    rust = sum(
        physical_lines(contents[blob.path], blob.path)
        for blob in blobs
        if blob.path.startswith("rust/") and blob.path.endswith(".rs")
    )
    return legacy, rust


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", required=True)
    parser.add_argument("--base", required=True)
    parser.add_argument("--head", required=True)
    parser.add_argument("--rust-limit", type=int, default=10_500)
    parser.add_argument("--legacy-net-limit", type=int, default=250)
    args = parser.parse_args()
    if args.rust_limit < 0 or args.legacy_net_limit < 0:
        parser.error("line budgets must be non-negative")
    try:
        merge_base = git(args.repo, "merge-base", args.base, args.head).decode().strip()
        base_legacy, _ = production_loc(args.repo, merge_base)
        head_legacy, head_rust = production_loc(args.repo, args.head)
    except (OSError, RuntimeError, ValueError) as error:
        print(f"LOC budget: unable to measure: {error}", file=sys.stderr)
        return 2
    delta = head_legacy - base_legacy
    print(f"Rust production LOC: {head_rust} / {args.rust_limit} (tracked rust/**/*.rs; test paths excluded)")
    print(f"Legacy production net delta from merge-base {merge_base[:12]}: {delta:+} / +{args.legacy_net_limit} (generated mirrors, tests, docs, and CI tooling excluded)")
    failures = []
    if head_rust > args.rust_limit:
        failures.append("Rust production line ceiling exceeded")
    if delta > args.legacy_net_limit:
        failures.append("legacy production net-growth budget exceeded")
    for failure in failures:
        print(f"FAIL: {failure}", file=sys.stderr)
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
