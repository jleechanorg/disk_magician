#!/usr/bin/env python3
"""Validate disk_magician's deterministic PR evidence fields."""

from __future__ import annotations

import re
import sys


REQUIRED_FIELDS = (
    "Claim class",
    "Verdict",
    "Commands and results",
    "What this proves",
    "What this does not prove",
)
CLAIM_CLASSES = {"tooling", "documentation-only", "production"}
VERDICTS = {"PASS", "PARTIAL", "INSUFFICIENT", "FAIL"}
PLACEHOLDER_VALUES = {"n/a", "na", "none", "tbd", "todo", "trust me"}
GIST_ARTIFACT_URL = re.compile(
    r"https://gist\.github\.com/[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})/[0-9a-fA-F]{16,}"
    r"(?:[/?#].*)?"
)


def evidence_lines(markdown: str) -> list[str]:
    lines = markdown.splitlines()
    start = next(
        (index + 1 for index, line in enumerate(lines) if line.strip().casefold() == "## evidence"),
        None,
    )
    if start is None:
        raise ValueError("missing exact '## Evidence' section")

    section: list[str] = []
    for line in lines[start:]:
        if line.lstrip().startswith("## "):
            break
        section.append(line)
    return section


def parse_fields(lines: list[str]) -> dict[str, str]:
    fields: dict[str, str] = {}
    for line in lines:
        stripped = line.strip()
        for label in (*REQUIRED_FIELDS, "Evidence URL"):
            prefix = f"**{label}:**"
            if not stripped.startswith(prefix):
                continue
            if label in fields:
                raise ValueError(f"duplicate evidence field: {label}")
            value = stripped[len(prefix) :].strip()
            if not value or "<!--" in value or "-->" in value:
                if label == "Evidence URL":
                    break
                raise ValueError(f"placeholder or empty evidence field: {label}")
            fields[label] = value
            break
    return fields


def validate(markdown: str) -> None:
    fields = parse_fields(evidence_lines(markdown))
    missing = [label for label in REQUIRED_FIELDS if label not in fields]
    if missing:
        raise ValueError(f"missing evidence field(s): {', '.join(missing)}")

    for label in ("Commands and results", "What this proves", "What this does not prove"):
        if fields[label].strip().casefold().rstrip(".") in PLACEHOLDER_VALUES:
            raise ValueError(f"placeholder evidence field: {label}")

    claim_class = fields["Claim class"].casefold()
    if claim_class not in CLAIM_CLASSES:
        raise ValueError(f"unsupported Claim class: {fields['Claim class']}")

    verdict = fields["Verdict"].upper()
    if verdict not in VERDICTS:
        raise ValueError(f"unsupported Verdict: {fields['Verdict']}")
    if verdict in {"INSUFFICIENT", "FAIL"}:
        raise ValueError(f"Verdict {verdict} does not pass the Evidence Gate")

    if claim_class == "production":
        if verdict != "PASS":
            raise ValueError("production evidence requires Verdict PASS")
        evidence_url = fields.get("Evidence URL", "")
        if not GIST_ARTIFACT_URL.fullmatch(evidence_url):
            raise ValueError(
                "production evidence requires a gist.github.com owner and artifact ID"
            )


def main() -> int:
    try:
        validate(sys.stdin.read())
    except ValueError as error:
        print(f"Evidence Gate: FAIL: {error}", file=sys.stderr)
        return 1
    print("Evidence Gate: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
