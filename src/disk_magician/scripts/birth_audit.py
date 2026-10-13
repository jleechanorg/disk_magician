#!/usr/bin/env python3
"""Birth audit (spec C7), detection only; a govern tick phase serialized by govern.lock.

A *birth* is one destination generation the audit sights: canonical parent + name,
plus dev + inode. It is admitted only when an ``admit_confirm`` for a non-degraded
0/10 attempt records that generation's dev + inode; every other birth is bypass
(a degraded attempt is bypass even with a matching confirm, C7/§7.5). Sizes are
measured with ``du -sk`` inside the tick's audit budget by the shared bounded-process
owner (``c14_probe._run_bounded``), which kills the whole process group on timeout so
a stubbed du cannot leave a descendant holding the pipe past the deadline. An
unmeasured birth is ``bytes_unknown`` and charged ``max(class budget_gb, largest
measured birth in the class)`` as an explicit estimate, retried on the next three
audits and replaced on success; a birth that only ran out of budget is charged the
same estimate but does **not** consume a failed retry. Calibration is written only to
``admission/estimates.pending.json``; the effective estimates file is never touched
here. A structurally malformed existing registry fails closed (nonzero, original
preserved); a missing registry is an allowed bootstrap. Nothing is deleted.
"""
import fcntl, json, math, os, sys, time
from pathlib import Path
from disk_budget import state_update
from c14_probe import _run_bounded
import budget_controls

GIB = 1 << 30
RATIO_WINDOW_S = 86400  # §7.5 births SLO and the `bypass_high` alert are 24h
DEFAULT_BUDGET_S = 120.0  # C7: at most 120 s of du per tick
MAX_BUDGET_S = 120.0  # hard ceiling for --budget-seconds / the env override
MAX_DU_TIMEOUT_S = 30.0
MIN_DU_TIMEOUT_S = 0.2
UNKNOWN_RETRY_LIMIT = 3  # retried on the next three audits after the first sighting
PRUNE_AFTER_S = 14 * 86400
CALIBRATION_MIN_BIRTHS = 20
SIZE_FIELDS = ("bytes", "charge", "estimate_bytes", "unknown_retries", "measured_at")
BIRTH_CLASSES = ("tmp_containers", "tmpdir_scratch", "codex_documents", "worktrees")
# Authoritative C7 birth status schema. budget_acceptance imports these so the
# producer and consumer cannot disagree: every status is a structurally valid
# record, but only SLO_BIRTH_STATUSES count toward the 24h bypass ratio.
BIRTH_STATUSES = ("preexisting", "foreign", "admitted", "bypass")
SLO_BIRTH_STATUSES = ("admitted", "bypass")
IDENTITY_SEP = "\x1f"
QUALITY_RC = 3  # nonzero quality error; the original registry is never overwritten


class QualityError(Exception):
    """An existing birth registry is structurally unusable; never reset it."""


def canon(p):
    return os.path.join(os.path.realpath(os.path.dirname(p)), os.path.basename(p))


def birth_key(path, dev, ino):
    """The canonical C7 birth identity: canonical path + dev + inode."""
    return f"{path}{IDENTITY_SEP}{dev}:{ino}"


def ls(d, dirs_only=False):  # never follows symlinks; sorted for reproducible budgets/tests
    try:
        out = [e for e in os.scandir(d) if not e.is_symlink() and (e.is_dir() or not dirs_only)] if d else []
    except OSError:
        return []
    return sorted(out, key=lambda e: e.name)


def entries(ptmp, tmpdir, codex, wt):  # (path, class, foreign); /private/tmp/<repo>/evidence is a container
    for e in (e for repo in ls(ptmp, True) for e in ls(repo.path)):
        yield from ((c.path, "tmp_containers", False) for c in ls(e.path)) if e.name == "evidence" and e.is_dir() else [(e.path, "tmp_containers", False)]
    for e in ls(tmpdir):  # fixed producer-prefix table: advice-*, tmp* clones with a .git; anything else is foreign
        yield e.path, "tmpdir_scratch", not (e.name.startswith("advice-") or e.name.startswith("tmp") and os.path.lexists(os.path.join(e.path, ".git")))
    for root, cls in ((codex, "codex_documents"), (wt, "worktrees")):
        yield from ((e.path, cls, False) for d in ls(root, True) for e in ls(d.path))


def _as_int(value):
    return value if isinstance(value, int) and not isinstance(value, bool) else None


def _as_float(value):
    return float(value) if isinstance(value, (int, float)) and not isinstance(value, bool) else None


def _parse_legacy_key(key):
    if not isinstance(key, str) or ":" not in key:
        return None, None
    dev, _, ino = key.rpartition(":")
    try:
        return int(dev), int(ino)
    except (TypeError, ValueError):
        return None, None


def _identity(g, key):
    """dev+ino from the row, else the legacy ``dev:ino`` registry key; else fail closed."""
    dev, ino = _as_int(g.get("dev")), _as_int(g.get("ino"))
    if dev is None or ino is None:
        dev, ino = _parse_legacy_key(key)
    if dev is None or ino is None or dev < 0 or ino < 0:
        raise QualityError(f"gens entry {key!r} has no physical identity (path+dev+inode)")
    return dev, ino


def migrate_gens(data):
    """Rebuild the gens map keyed by path+dev+inode, preserving legacy history.

    Legacy rows were keyed by ``dev:ino`` with no dev/ino fields; their history is
    preserved under the stored path (no zero reset). A structurally bad row is a
    quality error, never silently dropped and never republished as a clean SLO.
    """
    raw = data.get("gens")
    if raw is None:
        return {}
    if not isinstance(raw, dict):
        raise QualityError("gens is not a JSON object")
    out = {}
    for key, g in raw.items():
        if not isinstance(g, dict) or not isinstance(g.get("path"), str) or not g["path"]:
            raise QualityError(f"gens entry {key!r} is not a valid birth row")
        dev, ino = _identity(g, key)
        row = dict(g)
        row["path"] = canon(row["path"])
        row["dev"], row["ino"] = dev, ino
        out[birth_key(row["path"], dev, ino)] = row
    return out


def read_registry(state):
    """Parsed registry, or None when missing (allowed bootstrap). Malformed -> QualityError."""
    path = state / "admission" / "births.json"
    if not path.exists():
        return None
    try:
        data = json.loads(path.read_text())
    except (OSError, ValueError) as exc:
        raise QualityError(f"unreadable registry {path}: {exc}")
    if not isinstance(data, dict):
        raise QualityError(f"registry {path} is not a JSON object")
    return data


def load_budgets():
    try:
        import resolve_config
        path = resolve_config.resolve()
        if path:
            return json.loads(Path(path).read_text()).get("budgets") or {}
    except Exception:
        pass
    try:
        return json.loads((Path(__file__).resolve().parents[1] / "config.json.template").read_text())["budgets"]
    except Exception:
        return {}


def _class_budget_bytes(budgets, cls):
    raw = (budgets.get("classes") or {}).get(cls, {}).get("budget_gb") if isinstance(budgets, dict) else None
    gb = _as_float(raw)
    return max(0, int(gb * GIB)) if gb else 0


def _du_bytes(path, timeout):
    """du -sk through the shared bounded-process owner; a timeout kills the group."""
    result = _run_bounded([os.environ.get("DISK_MAGICIAN_DU_BIN", "du"), "-sk", path],
                          cap=max(MIN_DU_TIMEOUT_S, timeout), step="birth-du")
    if result is None:
        return None
    rc, out = result
    if rc != 0:
        return None
    try:
        return int(out.split()[0]) * 1024
    except (ValueError, IndexError):
        return None


def _charge_estimate(g, budgets, largest):
    """bytes_unknown: charged max(class budget, largest measured birth in the class)."""
    g["charge"] = "estimate"
    g["estimate_bytes"] = max(_class_budget_bytes(budgets, g["cls"]), largest.get(g["cls"], 0))


def measure_births(gens, budgets, now, budget_s, deadline_at):
    """Measure births with du, outside state.lock, inside the tick's audit budget.

    Returns per-class largest measured birth bytes. A birth that only ran out of
    budget is charged the same estimate but never counts as a failed retry; a birth
    whose du attempt failed is retried on the next UNKNOWN_RETRY_LIMIT audits.
    """
    largest = {}
    for g in gens.values():
        if g.get("charge") == "measured" and _as_int(g.get("bytes")) is not None:
            largest[g["cls"]] = max(largest.get(g["cls"], 0), g["bytes"])
    deadline = time.monotonic() + max(0.0, budget_s)
    if deadline_at is not None:
        deadline = min(deadline, time.monotonic() + max(0.0, deadline_at - now))
    exhausted = False
    for g in gens.values():
        if g.get("status") not in SLO_BIRTH_STATUSES:
            continue
        if g.get("charge") == "measured" and _as_int(g.get("bytes")) is not None:
            continue
        if not os.path.lexists(g["path"]):
            continue
        retries = _as_int(g.get("unknown_retries")) or 0
        if g.get("charge") == "estimate" and retries >= UNKNOWN_RETRY_LIMIT + 1:
            continue  # frozen estimate: retries exhausted
        if exhausted:
            _charge_estimate(g, budgets, largest)
            continue
        remaining = deadline - time.monotonic()
        if remaining < MIN_DU_TIMEOUT_S:
            exhausted = True  # budget spent: charge estimates, leave attempts for the next tick
            _charge_estimate(g, budgets, largest)
            continue
        size = _du_bytes(g["path"], min(MAX_DU_TIMEOUT_S, remaining))
        g["measured_at"] = now
        if size is None:
            g["bytes"] = None
            _charge_estimate(g, budgets, largest)
            g["unknown_retries"] = retries + 1
        else:
            g["bytes"] = size
            g["charge"] = "measured"
            g["estimate_bytes"] = None
            g["unknown_retries"] = 0
            largest[g["cls"]] = max(largest.get(g["cls"], 0), size)
    return largest


def _default_estimate(producer):
    """The documented C2 default, owned by budget_controls (never duplicated here)."""
    return budget_controls.default_estimate(producer)


def _p95(values):
    ordered = sorted(values)
    return ordered[max(0, math.ceil(0.95 * len(ordered)) - 1)]


def calibration(gens, now):
    """Per-producer pending calibration: max(default, 1.25 x p95 of the last 20
    measured admitted births); fewer than 20 uses the documented default."""
    samples = {}
    for g in gens.values():
        if g.get("status") != "admitted" or g.get("charge") != "measured":
            continue
        producer, size = g.get("producer"), _as_int(g.get("bytes"))
        if not isinstance(producer, str) or not producer or size is None or size < 0:
            continue
        stamp = _as_float(g.get("measured_at")) or _as_float(g.get("first_seen")) or now
        samples.setdefault(producer, []).append((stamp, size))
    producers = {}
    for producer, rows in samples.items():
        rows.sort(key=lambda row: row[0])
        default = _default_estimate(producer)
        if len(rows) >= CALIBRATION_MIN_BIRTHS:
            value = 1.25 * _p95([b for _, b in rows[-CALIBRATION_MIN_BIRTHS:]]) / GIB
            if default is not None:
                value = max(default, value)
        elif default is not None:
            value = default
        else:
            continue
        producers[producer] = round(value, 6)
    return producers


def _atomic_json(path, data):
    tmp = path.parent / f".{path.name}.{os.getpid()}.tmp"
    tmp.write_text(json.dumps(data))
    os.replace(tmp, path)


def merge_and_write(state, since, gens, measured, now, producers):
    """Under state.lock: reread and merge births.json, then write it and the pending
    calibration atomically. Measurement never runs here. A registry that turned
    malformed between the audit read and this merge raises, so nothing is published."""
    path = state / "admission" / "births.json"
    with open(state / "state.lock", "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            existing = read_registry(state)
            merged = migrate_gens(existing) if existing is not None else {}
            for key, g in gens.items():
                if key in merged:
                    base = merged[key]
                    for field in SIZE_FIELDS:
                        if g.get(field) is not None:
                            base[field] = g[field]
                    for field in ("path", "cls", "status", "first_seen", "producer",
                                  "match", "admit_id", "dev", "ino"):
                        if field not in base or base[field] is None:
                            base[field] = g.get(field)
                else:
                    merged[key] = dict(g)
            merged = {k: g for k, g in merged.items()
                      if isinstance(g.get("path"), str)
                      and (os.path.lexists(g["path"]) or now - (_as_float(g.get("first_seen")) or now) < PRUNE_AFTER_S)}
            largest = {}
            for g in merged.values():
                if g.get("charge") == "measured" and _as_int(g.get("bytes")) is not None:
                    largest[g["cls"]] = max(largest.get(g["cls"], 0), g["bytes"])
            for cls, value in measured.items():
                largest[cls] = max(largest.get(cls, 0), value)
            _atomic_json(path, dict(since=since, gens=merged, largest_bytes=largest))
            _atomic_json(state / "admission" / "estimates.pending.json", {"producers": producers})
        finally:
            fcntl.flock(lock, fcntl.LOCK_UN)


def _charged_bytes(g):
    if g.get("charge") == "measured":
        return _as_int(g.get("bytes"))
    if g.get("charge") == "estimate":
        return _as_int(g.get("estimate_bytes"))
    return None


def audit(state, roots, now, budget_s=DEFAULT_BUDGET_S, deadline_at=None):
    budgets = load_budgets()
    registry = read_registry(state)
    if registry is None:
        since, gens = now - 600, {}
    else:
        since = _as_float(registry.get("since")) or (now - 600)
        gens = migrate_gens(registry)
    attempts, confirms = {}, {}
    try:
        lines = (state / "admission" / "events.jsonl").read_text().splitlines()
    except OSError:
        lines = []
    for line in lines:  # attempts are 0/10 admits; a confirm counts only for such an attempt
        try:
            e = json.loads(line)
            kind = e["event"]
        except (ValueError, TypeError, KeyError):
            continue
        if kind == "admit" and e.get("decision") in (0, 10):
            attempts[e.get("admit_id")] = e
        elif kind == "admit_confirm" and e.get("admit_id") in attempts:
            confirms[(e.get("dev"), e.get("inode"))] = e
    by_dest = {canon(a["dest"]) for a in attempts.values() if isinstance(a.get("dest"), str)}
    adoptees = []
    for path, cls, foreign in entries(*roots):
        try:
            st = os.lstat(path)
        except OSError:
            continue
        cp = canon(path)
        key = birth_key(cp, st.st_dev, st.st_ino)
        if key in gens:
            continue
        c = confirms.get((st.st_dev, st.st_ino))
        a = attempts.get(c.get("admit_id")) if c else None
        # A degraded 0/10 attempt is bypass even with a matching confirm (C7/§7.5).
        admitted = bool(c) and a is not None and not a.get("degraded") and canon(str(a.get("dest"))) == cp
        status = "preexisting" if getattr(st, "st_birthtime", st.st_ctime) < since else "foreign" if foreign \
            else "admitted" if admitted else "bypass"
        gens[key] = dict(path=cp, cls=cls, status=status, first_seen=now,
                         producer=a.get("producer") if a else None,
                         admit_id=a.get("admit_id") if a else None,
                         dev=st.st_dev, ino=st.st_ino,
                         match="confirmed" if admitted else "match_unconfirmed" if cp in by_dest else "none",
                         bytes=None, charge=None, estimate_bytes=None, unknown_retries=0)
        if status == "bypass" and cp not in by_dest:
            adoptees.append(path)
    for path in adoptees:  # adopt each unattempted bypass entry with an ownerless lease
        sys.stdout.write(path + "\0")

    measured = measure_births(gens, budgets, now, budget_s, deadline_at)
    producers = calibration(gens, now)
    merge_and_write(state, since, gens, measured, now, producers)

    def first_seen(g):
        return _as_float(g.get("first_seen")) if _as_float(g.get("first_seen")) is not None else now

    born_all = [g for g in gens.values() if g.get("status") in SLO_BIRTH_STATUSES]
    born_24h = [g for g in born_all if now - first_seen(g) <= RATIO_WINDOW_S]

    def class_counts(items):
        counts = {cls: {"births": 0} for cls in BIRTH_CLASSES}
        for g in items:
            if g.get("status") == "bypass" and g.get("cls") in counts:
                counts[g["cls"]]["births"] += 1
        return counts

    bypass_all, bypass_24h = class_counts(born_all), class_counts(born_24h)
    bypass_n = sum(v["births"] for v in bypass_24h.values())
    ratio = bypass_n / len(born_24h) if born_24h else 0.0
    measured_bytes = sum(_as_int(g.get("bytes")) or 0 for g in born_24h if g.get("charge") == "measured")
    estimated_bytes = sum(_as_int(g.get("estimate_bytes")) or 0 for g in born_24h if g.get("charge") == "estimate")
    unknown_n = sum(g.get("charge") == "estimate" for g in born_24h)
    # §7.5 bypass bytes ratio: bypass bytes / (bypass + admitted est_bytes), an estimate.
    bypass_bytes = sum(_charged_bytes(g) or 0 for g in born_24h if g.get("status") == "bypass")
    admitted_est = 0
    for g in born_24h:
        if g.get("status") != "admitted":
            continue
        aid = g.get("admit_id")
        a = attempts.get(aid) if aid else None
        if a is None:
            c = confirms.get((_as_int(g.get("dev")), _as_int(g.get("ino"))))
            a = attempts.get(c.get("admit_id")) if c else None
        est = _as_int(a.get("est_bytes")) if a else None
        if est is not None and est >= 0:
            admitted_est += est
    bytes_denom = bypass_bytes + admitted_est
    bytes_ratio = bypass_bytes / bytes_denom if bytes_denom else 0.0
    estimate_unbounded = bool(born_24h) and unknown_n > 0.05 * len(born_24h)
    seen = {g["path"] for g in gens.values()}
    state_update(state, dict(births=dict(
        at=now, coverage="births that persist >= one tick",
        admitted=sum(g.get("status") == "admitted" for g in born_all),
        admitted_24h=sum(g.get("status") == "admitted" for g in born_24h),
        bypass=bypass_all, bypass_24h=bypass_24h,
        foreign=sum(g.get("status") == "foreign" for g in gens.values()),
        ratio=ratio, ratio_window_s=RATIO_WINDOW_S, slo_ok=not born_24h or ratio < 0.10,
        bytes=dict(measured=measured_bytes, estimated=estimated_bytes, unknown=unknown_n,
                   total=measured_bytes + estimated_bytes, estimate=True, window_s=RATIO_WINDOW_S),
        admitted_est_bytes=admitted_est,
        bypass_bytes_estimate=bypass_bytes,
        bytes_ratio=bytes_ratio,
        estimate_unbounded=estimate_unbounded,
        attempt_unconfirmed=sum(
            not a.get("ci_job") and isinstance(a.get("dest"), str) and canon(a["dest"]) not in seen
            for a in attempts.values()),
        ci_admission=dict(jobs=len({a["ci_job"] for a in attempts.values() if a.get("ci_job")})))))


def _number(text):
    try:
        return float(text)
    except (TypeError, ValueError):
        return None


def _budget_seconds(value, default=DEFAULT_BUDGET_S):
    """Finite, >= 0, hard-capped at 120 s. 0 stays 0 (never falls back to 120)."""
    if not isinstance(value, (int, float)) or isinstance(value, bool) \
            or not math.isfinite(value) or value < 0:
        return default
    return min(float(value), MAX_BUDGET_S)


def _deadline(value):
    if not isinstance(value, (int, float)) or isinstance(value, bool) or not math.isfinite(value):
        return None
    return float(value)


def main():
    state = Path(os.environ.get("DISK_MAGICIAN_STATE_DIR", Path.home() / ".disk_magician_state"))
    (state / "admission").mkdir(parents=True, exist_ok=True)
    budget_s = _budget_seconds(_number(os.environ.get("DISK_MAGICIAN_BIRTH_BUDGET_S")))
    deadline_at = _deadline(_number(os.environ.get("DISK_MAGICIAN_BIRTH_DEADLINE_AT")))
    args, roots, i = sys.argv[1:], [], 0
    while i < len(args):
        if args[i] == "--budget-seconds" and i + 1 < len(args):
            budget_s = _budget_seconds(_number(args[i + 1]), budget_s)
            i += 2
        elif args[i] == "--deadline-at" and i + 1 < len(args):
            deadline_at = _deadline(_number(args[i + 1]))
            i += 2
        else:
            roots.append(args[i])
            i += 1
    try:
        return audit(state, (roots + [""] * 4)[:4], time.time(), budget_s, deadline_at) or 0
    except QualityError as exc:
        print(f"birth_audit_quality_error:{exc}", file=sys.stderr)
        return QUALITY_RC


if __name__ == "__main__":
    sys.exit(main())
