#!/usr/bin/env python3
"""Safely add entries to the effective Disk Magician JSON configuration."""

import argparse
import fcntl
import json
import os
import stat
import sys
import tempfile
from pathlib import Path

import resolve_config
import resolve_state_repo_path


DEFAULT_DIR_TIMEOUT = 60
MONITORED_KEY_FIELDS = ("monitored_dirs", "monitored_globs", "monitored_file_globs")


class ConfigError(Exception):
    """A configuration cannot be safely edited."""


def _effective_path() -> Path:
    configured = resolve_config.resolve()
    if not configured:
        raise ConfigError("no effective config file was found")
    configured_path = Path(configured)
    if configured_path.name == "config.json.template":
        overlay = Path(
            os.environ.get(
                "XDG_CONFIG_HOME",
                Path(os.environ.get("HOME", "/")) / ".config",
            )
        ) / "disk-magician" / "config.json"
        if os.environ.get("DISK_MAGICIAN_CONFIG") or not (
            overlay.is_file() and resolve_config._is_snapshot_overlay(overlay)
        ):
            raise ConfigError(f"refusing to write packaged config template: {configured_path}")
        # A snapshot-only XDG overlay is an additive tuning file.  Keep the
        # packaged inventory as the read-only fallback, and materialize the
        # first writable inventory in the state repo when this command runs.
        target = Path(resolve_state_repo_path.resolve()) / "config" / "config.json"
        target.parent.mkdir(parents=True, exist_ok=True)
        return target
    try:
        path = configured_path.resolve(strict=True)
    except OSError as exc:
        raise ConfigError(f"cannot resolve effective config {configured_path}: {exc}") from exc
    if path.name == "config.json.template":
        raise ConfigError(f"refusing to write packaged config template: {path}")
    if not path.is_file():
        raise ConfigError(f"effective config is not a regular file: {path}")
    return path


def _initialize_state_config(path: Path) -> None:
    """Seed a writable state config from the package and optional overlay."""
    template = Path(__file__).resolve().parents[1] / "config.json.template"
    try:
        data = json.loads(template.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ConfigError(f"cannot read packaged config template {template}: {exc}") from exc
    overlay = Path(
        os.environ.get(
            "XDG_CONFIG_HOME",
            Path(os.environ.get("HOME", "/")) / ".config",
        )
    ) / "disk-magician" / "config.json"
    if overlay.is_file():
        try:
            overlay_data = json.loads(overlay.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            raise ConfigError(f"cannot read valid JSON config {overlay}: {exc}") from exc
        if isinstance(overlay_data, dict):
            data.update(overlay_data)
    path.parent.mkdir(parents=True, exist_ok=True)
    _atomic_write(path, data)


def _load(path: Path) -> dict:
    try:
        with path.open(encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, json.JSONDecodeError) as exc:
        raise ConfigError(f"cannot read valid JSON config {path}: {exc}") from exc
    if not isinstance(data, dict):
        raise ConfigError(f"config root must be a JSON object: {path}")
    _validate_schema(data)
    return data


def _validate_schema(data: dict) -> None:
    """Reject shapes that the snapshot and ledger consumers cannot read."""
    seen_keys = {}
    value_field = {
        "monitored_dirs": "path",
        "monitored_globs": "pattern",
        "monitored_file_globs": "pattern",
    }
    for field in MONITORED_KEY_FIELDS:
        if field not in data:
            continue
        rows = data[field]
        if not isinstance(rows, list):
            raise ConfigError(f"config field {field!r} must be a JSON array")
        for index, row in enumerate(rows):
            if not isinstance(row, dict):
                raise ConfigError(
                    f"config field {field!r} entry {index} must be a JSON object"
                )
            key = row.get("key")
            if not isinstance(key, str) or not key.strip():
                raise ConfigError(
                    f"config field {field!r} entry {index} key must be a non-empty string"
                )
            if key in seen_keys:
                raise ConfigError(
                    f"config key {key!r} is duplicated in field {seen_keys[key]!r}"
                )
            seen_keys[key] = field

            name = value_field[field]
            value = row.get(name)
            if not isinstance(value, str) or not value.strip():
                raise ConfigError(
                    f"config field {field!r} entry {index} {name} must be a non-empty string"
                )
            if field == "monitored_dirs":
                for timeout_name, minimum in (("timeout", 1), ("retry_timeout", 0)):
                    if timeout_name not in row:
                        continue
                    timeout = row[timeout_name]
                    if (
                        isinstance(timeout, bool)
                        or not isinstance(timeout, int)
                        or timeout < minimum
                    ):
                        comparator = "positive" if minimum else "non-negative"
                        raise ConfigError(
                            f"config field {field!r} entry {index} {timeout_name} "
                            f"must be a {comparator} integer"
                        )


def _add_entry(data: dict, field: str, entry: dict) -> bool:
    key = entry["key"]
    for other_field in MONITORED_KEY_FIELDS:
        if other_field == field:
            continue
        other_rows = data.get(other_field, [])
        if not isinstance(other_rows, list):
            continue
        for existing in other_rows:
            if isinstance(existing, dict) and existing.get("key") == key:
                raise ConfigError(
                    f"config key {key!r} is already used in field {other_field!r}"
                )

    if field not in data:
        rows = []
        data[field] = rows
    else:
        rows = data[field]
    if not isinstance(rows, list):
        raise ConfigError(f"config field {field!r} must be a JSON array")

    for existing in rows:
        if not isinstance(existing, dict):
            raise ConfigError(f"config field {field!r} contains a non-object entry")
        if existing.get("key") != key:
            continue
        if existing == entry:
            return False
        raise ConfigError(
            f"config field {field!r} already has a different entry for key {key!r}"
        )
    rows.append(entry)
    return True


def _atomic_write(path: Path, data: dict) -> None:
    mode = stat.S_IMODE(path.stat().st_mode) if path.exists() else 0o600
    fd, tmp_name = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp", dir=path.parent)
    tmp = Path(tmp_name)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(data, handle, indent=2)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(tmp, mode)
        os.replace(tmp, path)
        dir_fd = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(dir_fd)
        finally:
            os.close(dir_fd)
    finally:
        try:
            tmp.unlink()
        except FileNotFoundError:
            pass


def _lock(path: Path):
    """Serialize read/modify/replace cycles for one physical config file."""
    return path.with_name(f".{path.name}.lock").open("a+")


def _nonempty(value: str, option: str) -> str:
    value = value.strip()
    if not value:
        raise argparse.ArgumentTypeError(f"{option} must not be empty")
    return value


def _positive_timeout(value: str) -> int:
    try:
        parsed = int(value)
    except ValueError as exc:
        raise argparse.ArgumentTypeError("--timeout must be a positive integer") from exc
    if parsed <= 0:
        raise argparse.ArgumentTypeError("--timeout must be a positive integer")
    return parsed


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    dirs = sub.add_parser("add-monitored-dir", help="add one monitored directory")
    dirs.add_argument("--key", required=True, type=lambda v: _nonempty(v, "--key"))
    dirs.add_argument("--path", required=True, type=lambda v: _nonempty(v, "--path"))
    dirs.add_argument("--timeout", type=_positive_timeout, default=DEFAULT_DIR_TIMEOUT)

    globs = sub.add_parser("add-monitored-file-glob", help="add one monitored file glob")
    globs.add_argument("--key", required=True, type=lambda v: _nonempty(v, "--key"))
    globs.add_argument("--pattern", required=True, type=lambda v: _nonempty(v, "--pattern"))
    return parser


def main(argv=None) -> int:
    args = _parser().parse_args(argv)
    if args.command == "add-monitored-dir":
        field = "monitored_dirs"
        entry = {"key": args.key, "path": args.path, "timeout": args.timeout}
    else:
        field = "monitored_file_globs"
        entry = {"key": args.key, "pattern": args.pattern}

    try:
        path = _effective_path()
        with _lock(path) as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            try:
                if not path.exists():
                    _initialize_state_config(path)
                data = _load(path)
                changed = _add_entry(data, field, entry)
                if changed:
                    _atomic_write(path, data)
                    print(f"added {entry['key']!r} to {field} in {path}")
                else:
                    print(f"{entry['key']!r} already exists in {field}; unchanged {path}")
            finally:
                fcntl.flock(lock, fcntl.LOCK_UN)
        return 0
    except ConfigError as exc:
        print(f"diskm config: {exc}", file=sys.stderr)
        return 1
    except OSError as exc:
        print(f"diskm config: atomic write failed: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
