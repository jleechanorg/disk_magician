#!/usr/bin/env python3
"""Refresh ledger/topdown-5g.{json,md} from the frontier scanner's report
(design: roadmap/2026-07-21-generic-split-state-repo-design.md, "Snapshot/commit
flow"). Freshness-gated: silently no-ops (exit 0, ledger files untouched) when
the frontier report is missing, unreadable, or older than 36h — the same
staleness threshold scripts/disk_snapshot.sh already applies when embedding
topdown_coverage into the snapshot JSON, so a stale scan never overwrites a
fresher committed ledger with worse data.

The mega-table is also publication-gated: only a fresh report that explicitly
declares a complete coverage envelope may replace the last published table.
Partial reports leave both table files untouched and record their status in a
sidecar (``topdown-5g.status.json``).
"""
import argparse, datetime, json, math, os, sys

STALE_HOURS = 36
GIB_KB = 1024 * 1024
GRANULARITY_CEILING_KB = 5 * GIB_KB
LEDGER_JSON = "topdown-5g.json"
LEDGER_MD = "topdown-5g.md"
STATUS_JSON = "topdown-5g.status.json"
SCHEMA_VERSION = 2
BUCKET_KINDS = {"dir", "file", "direct_allocation_segment"}
INTRINSIC_GATE_KEYS = {"path", "reason", "verification", "reclaimable"}
INTRINSIC_GATE_OPTIONAL_KEYS = {"errno", "root_device", "path_device"}
SIZE_KEYS = {"measured_kb", "size_kb", "size_mb", "allocated_kb", "bytes"}
SYSTEM_BOUNDARY_PROBES = {
    "spotlight": "/System/Volumes/Data/.Spotlight-V100",
    "fseventsd": "/System/Volumes/Data/.fseventsd",
    "document_revisions": "/System/Volumes/Data/.DocumentRevisions-V100",
}
USER_PROBE_RELATIVE_PATHS = {
    "mobile_sync": os.path.join("Library", "Application Support", "MobileSync", "Backup"),
    "mail": os.path.join("Library", "Mail"),
    "messages": os.path.join("Library", "Messages"),
}
USER_PROBE_NAMES = tuple(USER_PROBE_RELATIVE_PATHS.keys())
ATTESTATION_KEYS = {
    "run_id", "path", "status", "errno", "captured_at", "captured_during_run",
    "path_is_symlink", "verifier", "identity_before", "identity_after",
}
GATE_OPTIONAL_KEYS = {"root_device", "path_device"}


def gib(kb):
    return (kb or 0) / 1024.0 / 1024.0


def write_status(out_dir, status, reason, captured_at, age_hours, report=None):
    report = report or {}
    with open(os.path.join(out_dir, STATUS_JSON), "w") as f:
        json.dump(
            {
                "status": status,
                "reason": reason,
                "captured_at": captured_at,
                "age_hours": round(age_hours, 3),
                "mode": report.get("mode"),
                "coverage_envelope": report.get("coverage_envelope"),
            },
            f,
            indent=2,
        )
        f.write("\n")


def is_normalized_absolute_path(path):
    return (
        isinstance(path, str)
        and os.path.isabs(path)
        and os.path.normpath(path) == path
        and not any(component in (".", "..") for component in path.split(os.sep))
    )


def valid_user_probe_catalog(catalog):
    if not isinstance(catalog, dict) or set(catalog) != set(USER_PROBE_RELATIVE_PATHS):
        return False
    mail_path = catalog.get("mail")
    if not is_normalized_absolute_path(mail_path):
        return False
    expected_mail_suffix = "/" + USER_PROBE_RELATIVE_PATHS["mail"]
    if not mail_path.endswith(expected_mail_suffix):
        return False
    user_home = mail_path[:-len(expected_mail_suffix)]
    if not user_home or not os.path.isabs(user_home):
        return False
    if (
        user_home == "/tmp"
        or user_home.startswith(("/tmp/", "/private/tmp/", "/var/tmp/"))
        or user_home in ("/private/tmp", "/var/tmp")
    ):
        return False
    for name, rel_path in USER_PROBE_RELATIVE_PATHS.items():
        expected_path = os.path.join(user_home, rel_path)
        if catalog.get(name) != expected_path:
            return False
    return True


def valid_partial_run_binding(report):
    run_id = report.get("run_id")
    started = report.get("run_started_at")
    finished = report.get("run_finished_at")
    if (
        not isinstance(run_id, str)
        or not run_id
        or type(started) not in (int, float)
        or isinstance(started, bool)
        or type(finished) not in (int, float)
        or isinstance(finished, bool)
        or not math.isfinite(started)
        or not math.isfinite(finished)
        or finished < started
    ):
        return False
    catalog = report.get("fda_probe_paths")
    if not valid_user_probe_catalog(catalog):
        return False
    attestations = report.get("system_boundary_attestations")
    if not isinstance(attestations, list) or len(attestations) != len(SYSTEM_BOUNDARY_PROBES):
        return False
    return all(
        isinstance(item, dict)
        and item.get("run_id") == run_id
        and type(item.get("captured_at")) in (int, float)
        and not isinstance(item.get("captured_at"), bool)
        and math.isfinite(item["captured_at"])
        and started <= item["captured_at"] <= finished
        for item in attestations
    )


def valid_partial_system_boundary_contract(report):
    """Return true only for the scanner's exact partial FDA evidence envelope."""
    envelope = report.get("coverage_envelope")
    if not isinstance(envelope, dict):
        return False
    if envelope.get("fda_user_preflight_status") != "granted":
        return False
    if not valid_partial_run_binding(report):
        return False
    preflight = report.get("fda_preflight")
    if not isinstance(preflight, dict) or preflight.get("status") != "partial":
        return False
    probes = preflight.get("probes")
    expected_probe_names = set(USER_PROBE_NAMES) | set(SYSTEM_BOUNDARY_PROBES)
    if not isinstance(probes, dict) or set(probes) != expected_probe_names:
        return False
    user_probes = {}
    for name in USER_PROBE_NAMES:
        probe = probes.get(name)
        if (
            not isinstance(probe, dict)
            or not isinstance(probe.get("path"), str)
            or not probe["path"]
            or probe["path"] != report["fda_probe_paths"][name]
            or probe.get("status") != "readable"
            or set(probe) != {"path", "status"}
        ):
            return False
        user_probes[name] = probe
    for name, path in SYSTEM_BOUNDARY_PROBES.items():
        probe = probes.get(name)
        if (
            not isinstance(probe, dict)
            or set(probe) - {"path", "status", "errno"}
            or probe.get("path") != path
            or probe.get("status") != "permission_denied_or_tcc"
            or type(probe.get("errno")) is not int
            or probe.get("errno") not in (1, 13)
        ):
            return False

    attestations = report.get("system_boundary_attestations")
    if not isinstance(attestations, list) or len(attestations) != len(SYSTEM_BOUNDARY_PROBES):
        return False
    expected_fda = {"status": "granted", "probes": user_probes}
    attested_paths = set()
    run_ids = set()
    attestation_by_path = {}
    for item in attestations:
        if not isinstance(item, dict) or set(item) != ATTESTATION_KEYS:
            return False
        path = item.get("path")
        if path not in SYSTEM_BOUNDARY_PROBES.values() or path in attested_paths:
            return False
        if (
            item.get("status") != "permission_denied"
            or type(item.get("errno")) is not int
            or item.get("errno") not in (1, 13)
            or item.get("captured_during_run") is not True
            or item.get("path_is_symlink") is not False
            or not isinstance(item.get("run_id"), str)
            or not item["run_id"]
            or type(item.get("captured_at")) not in (int, float)
            or isinstance(item.get("captured_at"), bool)
            or not math.isfinite(item.get("captured_at"))
        ):
            return False
        verifier = item.get("verifier")
        if (
            not isinstance(verifier, dict)
            or set(verifier) != {"effective_uid", "access_context", "fda"}
            or verifier.get("effective_uid") != 0
            or verifier.get("access_context") != "parent_scanner_confirmation"
            or verifier.get("fda") != expected_fda
        ):
            return False
        for identity_name in ("identity_before", "identity_after"):
            identity = item.get(identity_name)
            if (
                not isinstance(identity, dict)
                or set(identity) != {"st_dev", "st_ino"}
                or any(type(identity.get(key)) is not int or identity[key] < 0 for key in ("st_dev", "st_ino"))
            ):
                return False
        if item["identity_before"] != item["identity_after"]:
            return False
        attested_paths.add(path)
        run_ids.add(item["run_id"])
        attestation_by_path[path] = item
    if attested_paths != set(SYSTEM_BOUNDARY_PROBES.values()) or len(run_ids) != 1:
        return False
    if any(
        attestation_by_path[path]["errno"] != probes[name]["errno"]
        for name, path in SYSTEM_BOUNDARY_PROBES.items()
    ):
        return False

    gates = report.get("opaque_intrinsic_gates")
    if not isinstance(gates, list) or len(gates) != len(SYSTEM_BOUNDARY_PROBES):
        return False
    gate_paths = set()
    allowed_gate_keys = INTRINSIC_GATE_KEYS | INTRINSIC_GATE_OPTIONAL_KEYS
    for gate in gates:
        if (
            not isinstance(gate, dict)
            or not INTRINSIC_GATE_KEYS.issubset(gate)
            or not set(gate).issubset(allowed_gate_keys)
            or gate.get("path") not in SYSTEM_BOUNDARY_PROBES.values()
            or gate.get("path") in gate_paths
            or gate.get("reason") != "permission_denied_intrinsic"
            or gate.get("verification") != "parent_scanner_system_boundary_confirmation"
            or gate.get("reclaimable") is not False
            or type(gate.get("errno")) is not int
            or gate.get("errno") not in (1, 13)
            or any(type(gate[key]) is not int or gate[key] < 0 for key in GATE_OPTIONAL_KEYS if key in gate)
            or gate["errno"] != attestation_by_path[gate["path"]]["errno"]
            or (
                "path_device" in gate
                and gate["path_device"] != attestation_by_path[gate["path"]]["identity_before"]["st_dev"]
            )
        ):
            return False
        gate_paths.add(gate["path"])
    return gate_paths == set(SYSTEM_BOUNDARY_PROBES.values())


def complete_coverage_envelope(report):
    """Return true only when the report proves full, balanced attribution."""
    if not isinstance(report, dict):
        return False
    if report.get("schema_version") != SCHEMA_VERSION:
        return False
    envelope = report.get("coverage_envelope")
    accounting = report.get("accounting_equation")
    reachable = envelope.get("reachable_top_level_roots") if isinstance(envelope, dict) else None
    measured = envelope.get("measured_top_level_roots") if isinstance(envelope, dict) else None
    unfinished = envelope.get("unfinished_top_level_roots") if isinstance(envelope, dict) else None
    buckets = report.get("granularity_buckets") or []
    oversize = report.get("oversize_indivisible_files") or []
    intrinsic_gates = report.get("opaque_intrinsic_gates")
    if not isinstance(intrinsic_gates, list):
        return False
    allowed_gate_keys = INTRINSIC_GATE_KEYS | INTRINSIC_GATE_OPTIONAL_KEYS
    if any(
        not isinstance(item, dict)
        or not INTRINSIC_GATE_KEYS.issubset(item)
        or not set(item).issubset(allowed_gate_keys)
        or not all(
            isinstance(item.get(key), str) and item[key]
            for key in ("path", "reason", "verification")
        )
        or type(item.get("reclaimable")) is not bool
        or item["reclaimable"] is not False
        or SIZE_KEYS.intersection(item)
        or any(
            type(item[key]) is not int or item[key] < 0
            for key in INTRINSIC_GATE_OPTIONAL_KEYS
            if key in item
        )
        for item in intrinsic_gates
    ):
        return False
    if any(
        not isinstance(item, dict)
        or not item.get("path")
        or type(item.get("measured_kb")) is not int
        or item["measured_kb"] < 0
        or item["measured_kb"] > GRANULARITY_CEILING_KB
        or item.get("kind", "dir") not in BUCKET_KINDS
        for item in buckets
    ):
        return False
    if any(
        not isinstance(item, dict)
        or not item.get("path")
        or type(item.get("measured_kb")) is not int
        or item["measured_kb"] < 0
        for item in oversize
    ):
        return False
    bucket_total = sum(item["measured_kb"] for item in buckets)
    oversize_total = sum(item["measured_kb"] for item in oversize)
    equation_keys = (
        "data_used_kb", "displayed_buckets_kb", "oversize_indivisible_files_kb",
        "sub_granularity_tail_kb", "purgeable_kb", "residual_kb",
    )
    equation_values = [accounting.get(key) for key in equation_keys] if isinstance(accounting, dict) else []
    clone_adjustment = accounting.get("clone_shared_adjustment_kb") if isinstance(accounting, dict) else None
    accounting_reconciles = (
        len(equation_values) == len(equation_keys)
        and all(type(value) is int and value >= 0 for value in equation_values)
        and type(clone_adjustment) is int
        and clone_adjustment <= 0
        and accounting["displayed_buckets_kb"] == bucket_total
        and accounting["oversize_indivisible_files_kb"] == oversize_total
        and accounting["data_used_kb"] == report.get("disk_used_kb")
        and accounting["data_used_kb"] == sum(equation_values[1:]) + clone_adjustment
    )
    return (
        report.get("mode") == "complete"
        and isinstance(envelope, dict)
        and envelope.get("complete") is True
        and (
            envelope.get("fda_preflight_status") == "granted"
            or (
                envelope.get("fda_preflight_status") == "partial"
                and valid_partial_system_boundary_contract(report)
            )
        )
        and type(reachable) is int
        and type(measured) is int
        and type(unfinished) is int
        and measured == reachable
        and unfinished == 0
        and isinstance(report.get("frontier_unfinished"), list)
        and not report["frontier_unfinished"]
        and isinstance(accounting, dict)
        and accounting.get("displayed_balanced") is True
        and accounting.get("display_ledger_valid") is True
        and accounting_reconciles
    )


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--frontier", required=True)
    p.add_argument("--out-dir", required=True)
    args = p.parse_args()

    try:
        with open(args.frontier) as f:
            report = json.load(f)
    except (OSError, ValueError):
        return 0  # no frontier data yet — leave ledger untouched

    captured_at = report.get("captured_at")
    try:
        ts = datetime.datetime.strptime(captured_at, "%Y-%m-%dT%H:%M:%SZ").replace(
            tzinfo=datetime.timezone.utc
        )
    except (TypeError, ValueError):
        return 0
    age_hours = (datetime.datetime.now(datetime.timezone.utc) - ts).total_seconds() / 3600.0
    if age_hours > STALE_HOURS:
        if os.path.isdir(args.out_dir):
            write_status(args.out_dir, "stale", "frontier_report_stale", captured_at, age_hours, report)
        return 0  # stale — leave prior ledger in place

    os.makedirs(args.out_dir, exist_ok=True)
    if not complete_coverage_envelope(report):
        # A partial scan is useful evidence, but it is not a replacement for
        # the last coherent mega-table. Keep the published rows byte-for-byte
        # stable and expose the current scan state separately.
        write_status(
            args.out_dir,
            "partial",
            "coverage_incomplete",
            captured_at,
            age_hours,
            report,
        )
        return 0

    buckets = report.get("granularity_buckets") or []
    oversize = report.get("oversize_indivisible_files") or []
    equation = report.get("accounting_equation") or {}

    ledger = {
        "schema_version": SCHEMA_VERSION,
        "mode": report.get("mode"),
        "coverage_envelope": report.get("coverage_envelope"),
        "frontier_unfinished": report.get("frontier_unfinished"),
        "opaque_intrinsic_gates": report.get("opaque_intrinsic_gates"),
        "fda_preflight": report.get("fda_preflight"),
        "fda_probe_paths": report.get("fda_probe_paths"),
        "system_boundary_attestations": report.get("system_boundary_attestations"),
        "run_id": report.get("run_id"),
        "run_started_at": report.get("run_started_at"),
        "run_finished_at": report.get("run_finished_at"),
        "captured_at": captured_at,
        "hostname": report.get("hostname"),
        "disk_used_kb": report.get("disk_used_kb"),
        "residual_kb": report.get("residual_kb"),
        "purgeable_kb": report.get("purgeable_kb"),
        "granularity_buckets": buckets,
        "oversize_indivisible_files": oversize,
        "accounting_equation": equation,
    }
    with open(os.path.join(args.out_dir, LEDGER_JSON), "w") as f:
        json.dump(ledger, f, indent=2)
        f.write("\n")

    lines = [
        f"# Top-down 5 GiB ledger — {report.get('hostname', 'unknown')}",
        f"Captured: {captured_at}",
        "",
        "| Size (GiB) | Path |",
        "|---:|---|",
    ]
    for item in sorted(buckets, key=lambda b: -(b.get("measured_kb") or 0)):
        lines.append(f"| {gib(item.get('measured_kb')):.1f} | {item.get('path')} |")
    for item in oversize:
        lines.append(
            f"| {gib(item.get('measured_kb')):.1f} | {item.get('path')} (indivisible file) |"
        )
    lines.append(f"| {gib(report.get('residual_kb')):.1f} | _residual (unattributed)_ |")
    lines.append("")
    lines.append(f"Balanced: {str(bool(equation.get('displayed_balanced'))).lower()}")
    with open(os.path.join(args.out_dir, LEDGER_MD), "w") as f:
        f.write("\n".join(lines) + "\n")
    write_status(
        args.out_dir,
        "published",
        "complete_coverage",
        captured_at,
        age_hours,
        report,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
