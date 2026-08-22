#!/usr/bin/env python3
"""check_version_monotonic.py — Verify pyproject.toml version monotonicity against git history.

Bead: disk_magician-fo6 ("Verify pyproject version regressions are caught in CI")

Inspects:
  1. Current `pyproject.toml` project.version.
  2. Historical git versions from `git tag -l`.
  3. Historical git versions from `git log -p pyproject.toml` (and origin/main, main, HEAD).

Exits with:
  - 0: Current version is >= all historical versions (or no historical versions exist).
  - 1: Current version is lower than any previously committed / released version (regression).
"""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Iterable, Set, Tuple

try:
    import tomllib
except ImportError:
    try:
        import tomli as tomllib  # type: ignore
    except ImportError:
        tomllib = None  # type: ignore


class FallbackVersion:
    """PEP 440 / SemVer compliant version parser and comparator for environments
    without `packaging.version`.
    """

    def __init__(self, v_str: str) -> None:
        self.raw = str(v_str).strip()
        cleaned = re.sub(r"^[vV]", "", self.raw)
        m = re.match(
            r"^(?:(?P<epoch>\d+)!)?(?P<release>\d+(?:\.\d+)*)"
            r"(?:(?P<pre_type>a|b|rc|alpha|beta|c|pre|preview)(?P<pre_num>\d+)?)?"
            r"(?:\.?(?P<post_type>post|r|rev)(?P<post_num>\d+)?)?"
            r"(?:\.?(?P<dev_type>dev)(?P<dev_num>\d+)?)?$",
            cleaned,
            re.IGNORECASE,
        )
        if not m:
            parts = [int(x) for x in re.findall(r"\d+", cleaned)]
            if not parts:
                raise ValueError(f"Invalid version string: {v_str!r}")
            self.epoch = 0
            self.release = tuple(parts)
            self.pre: tuple[int, ...] = (1,)
            self.post: tuple[int, ...] = (0,)
            self.dev: tuple[int, ...] = (1,)
        else:
            self.epoch = int(m.group("epoch") or 0)
            self.release = tuple(int(x) for x in m.group("release").split("."))
            pre_type = m.group("pre_type")
            if pre_type:
                pre_type = pre_type.lower()
                if pre_type in ("a", "alpha"):
                    p_rank = 0
                elif pre_type in ("b", "beta"):
                    p_rank = 1
                elif pre_type in ("rc", "c", "pre", "preview"):
                    p_rank = 2
                else:
                    p_rank = 0
                p_num = int(m.group("pre_num") or 0)
                self.pre = (0, p_rank, p_num)
            else:
                self.pre = (1,)

            post_type = m.group("post_type")
            if post_type:
                self.post = (1, int(m.group("post_num") or 0))
            else:
                self.post = (0,)

            dev_type = m.group("dev_type")
            if dev_type:
                self.dev = (0, int(m.group("dev_num") or 0))
            else:
                self.dev = (1,)

    @property
    def _key(self) -> tuple:
        rel = self.release
        while len(rel) < 3:
            rel = rel + (0,)
        return (self.epoch, rel, self.pre, self.post, self.dev)

    def __eq__(self, other: object) -> bool:
        if not isinstance(other, FallbackVersion):
            try:
                other = FallbackVersion(str(other))
            except Exception:
                return False
        return self._key == other._key

    def __lt__(self, other: object) -> bool:
        if not isinstance(other, FallbackVersion):
            other = FallbackVersion(str(other))
        return self._key < other._key

    def __le__(self, other: object) -> bool:
        return self == other or self < other

    def __gt__(self, other: object) -> bool:
        return not self <= other

    def __ge__(self, other: object) -> bool:
        return not self < other

    def __repr__(self) -> str:
        return f"FallbackVersion({self.raw!r})"

    def __str__(self) -> str:
        return self.raw


try:
    from packaging.version import Version as PackagingVersion  # type: ignore

    def parse_version(v_str: str):
        cleaned = re.sub(r"^[vV]", "", str(v_str).strip())
        try:
            return PackagingVersion(cleaned)
        except Exception:
            return FallbackVersion(v_str)

except ImportError:

    def parse_version(v_str: str):
        return FallbackVersion(v_str)


def extract_pyproject_version(pyproject_path: Path) -> str:
    """Extract project.version from a pyproject.toml file."""
    if not pyproject_path.exists():
        raise FileNotFoundError(f"pyproject.toml not found at {pyproject_path}")

    content = pyproject_path.read_text(encoding="utf-8")
    if tomllib is not None:
        try:
            data = tomllib.loads(content)
            version = data.get("project", {}).get("version")
            if version:
                return str(version).strip()
        except Exception:
            pass

    match = re.search(r'^\s*version\s*=\s*["\']([^"\']+)["\']', content, re.MULTILINE)
    if match:
        return match.group(1).strip()

    raise ValueError(f"Could not extract project.version from {pyproject_path}")


def get_git_tags(repo_dir: Path) -> Set[str]:
    """Retrieve version strings from git tags in the repo."""
    versions: Set[str] = set()
    try:
        r = subprocess.run(
            ["git", "-C", str(repo_dir), "tag", "-l"],
            capture_output=True,
            text=True,
            check=False,
        )
        if r.returncode == 0:
            for line in r.stdout.splitlines():
                line = line.strip()
                if not line:
                    continue
                m = re.search(r"(?:^|v)?(\d+(?:\.\d+)*(?:[a-zA-Z0-9\.\-\+]+)?)", line)
                if m:
                    candidate = m.group(1)
                    try:
                        parse_version(candidate)
                        versions.add(candidate)
                    except Exception:
                        pass
    except Exception:
        pass
    return versions


def get_git_branch_versions(repo_dir: Path, refs: Iterable[str] = ("origin/main", "main", "origin/master", "master", "HEAD")) -> Set[str]:
    """Retrieve pyproject.toml versions from specified git branch heads."""
    versions: Set[str] = set()
    for ref in refs:
        try:
            r = subprocess.run(
                ["git", "-C", str(repo_dir), "show", f"{ref}:pyproject.toml"],
                capture_output=True,
                text=True,
                check=False,
            )
            if r.returncode == 0:
                m = re.search(r'^\s*version\s*=\s*["\']([^"\']+)["\']', r.stdout, re.MULTILINE)
                if m:
                    candidate = m.group(1).strip()
                    try:
                        parse_version(candidate)
                        versions.add(candidate)
                    except Exception:
                        pass
        except Exception:
            pass
    return versions


def get_git_log_versions(repo_dir: Path, target_refs: list[str] | None = None) -> Set[str]:
    """Retrieve all pyproject.toml versions recorded in git diff history."""
    versions: Set[str] = set()
    cmds: list[list[str]] = []

    if target_refs:
        for ref in target_refs:
            cmds.append(["git", "-C", str(repo_dir), "log", ref, "-p", "--", "pyproject.toml"])
    else:
        cmds.append(["git", "-C", str(repo_dir), "log", "--all", "-p", "--", "pyproject.toml"])
        cmds.append(["git", "-C", str(repo_dir), "log", "-p", "--", "pyproject.toml"])

    for cmd in cmds:
        try:
            r = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                check=False,
            )
            if r.returncode == 0:
                for m in re.finditer(r'^[+-]?\s*version\s*=\s*["\']([^"\']+)["\']', r.stdout, re.MULTILINE):
                    candidate = m.group(1).strip()
                    if candidate and not candidate.startswith("$"):
                        try:
                            parse_version(candidate)
                            versions.add(candidate)
                        except Exception:
                            pass
        except Exception:
            pass

    return versions


def find_historical_versions(repo_dir: Path, target_refs: list[str] | None = None) -> Set[str]:
    """Find all historical version strings from git tags, branch heads, and log diffs."""
    versions: Set[str] = set()
    versions.update(get_git_tags(repo_dir))
    versions.update(get_git_branch_versions(repo_dir))
    versions.update(get_git_log_versions(repo_dir, target_refs=target_refs))
    return versions


def verify_version_monotonic(
    current_version_str: str,
    historical_versions: Iterable[str],
) -> Tuple[bool, str, str | None]:
    """Verify that current_version_str is >= all historical versions.

    Returns:
      (is_valid, current_version_str, max_historical_version_str_or_None)
    """
    curr_v = parse_version(current_version_str)
    valid_historical: list[str] = []
    for h in historical_versions:
        try:
            parse_version(h)
            valid_historical.append(h)
        except Exception:
            pass

    if not valid_historical:
        return (True, current_version_str, None)

    highest_hist_str = max(valid_historical, key=parse_version)
    highest_hist_v = parse_version(highest_hist_str)

    if curr_v < highest_hist_v:
        return (False, current_version_str, highest_hist_str)

    return (True, current_version_str, highest_hist_str)


def run_check(
    repo_dir: Path | None = None,
    pyproject_path: Path | None = None,
    target_refs: list[str] | None = None,
    verbose: bool = False,
) -> Tuple[bool, str]:
    """Execute monotonic version verification for a repository."""
    if repo_dir is None:
        # Default: repo root relative to this script
        repo_dir = Path(__file__).resolve().parents[1]

    if pyproject_path is None:
        pyproject_path = repo_dir / "pyproject.toml"

    try:
        current_version = extract_pyproject_version(pyproject_path)
    except Exception as e:
        return (False, f"Failed to extract current version from {pyproject_path}: {e}")

    # Check if inside git work tree
    try:
        r = subprocess.run(
            ["git", "-C", str(repo_dir), "rev-parse", "--is-inside-work-tree"],
            capture_output=True,
            text=True,
            check=False,
        )
        is_git = (r.returncode == 0 and r.stdout.strip() == "true")
    except Exception:
        is_git = False

    if not is_git:
        msg = f"[PASS] Not inside a git repository. Current pyproject.toml version: '{current_version}'."
        return (True, msg)

    historical = find_historical_versions(repo_dir, target_refs=target_refs)
    is_valid, curr, highest_hist = verify_version_monotonic(current_version, historical)

    if verbose:
        print(f"Discovered {len(historical)} historical version(s) in git repository at {repo_dir}:")
        for v in sorted(historical, key=parse_version):
            print(f"  - {v}")

    if not is_valid:
        error_msg = (
            f"[FAIL] Version regression detected!\n"
            f"  Current version in pyproject.toml: '{curr}'\n"
            f"  Highest historical version in git: '{highest_hist}'\n"
            f"  Error: current version '{curr}' is lower than historical version '{highest_hist}'.\n"
            f"  Action required: bump version in {pyproject_path} to >= '{highest_hist}'."
        )
        return (False, error_msg)

    if highest_hist is None:
        msg = f"[PASS] No historical versions found in git. Initial version: '{curr}'."
    else:
        msg = (
            f"[PASS] Version monotonic check passed: current version '{curr}' is >= "
            f"highest historical version '{highest_hist}' "
            f"({len(historical)} historical version(s) verified)."
        )
    return (True, msg)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Verify pyproject.toml version monotonicity against git history (prevents version regressions)."
    )
    parser.add_argument(
        "--repo",
        type=Path,
        default=None,
        help="Path to git repository root (defaults to parent of scripts/ directory)",
    )
    parser.add_argument(
        "--pyproject",
        type=Path,
        default=None,
        help="Path to pyproject.toml (defaults to <repo>/pyproject.toml)",
    )
    parser.add_argument(
        "--target-ref",
        action="append",
        dest="target_refs",
        help="Specific git ref(s) to check (e.g. origin/main, main). Can be repeated.",
    )
    parser.add_argument(
        "-v",
        "--verbose",
        action="store_true",
        help="Print verbose listing of all discovered versions",
    )
    args = parser.parse_args(argv)

    passed, message = run_check(
        repo_dir=args.repo,
        pyproject_path=args.pyproject,
        target_refs=args.target_refs,
        verbose=args.verbose,
    )

    if passed:
        print(message)
        return 0
    else:
        print(message, file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
