#!/usr/bin/env python3
"""diskm budget controls — transactional stage/margin/estimate changes (plan Task 3).

Every writer of `budget.json` takes the one `state.lock` (`fcntl.flock`),
re-reads the file inside the lock, merges only its own keys and atomically
replaces it, so a concurrent govern/measure tick never has a field clobbered.

The effective admission stage, margin and producer estimates live in
`budget.json` (written here) and fall back to the configured `budgets` block
until a control writes them. `disk_budget.py`'s `admit` path is owned by
another lane; the minimal integration diff is emitted to the parent lane as
`../proposed-disk_budget-adapter.diff` (never shipped as a runtime constant).
"""
import fcntl
import hashlib
import json
import os
import sys
import tempfile
import time
from pathlib import Path

STAGES = ("observe", "warn", "refuse_red", "refuse_orange")
PENDING_FILE = "estimates.pending.json"
EFFECTIVE_FILE = "estimates.json"
ADMISSION_SUBDIR = "admission"

# Producer prefixes the fixed table (plan Assumptions) may calibrate. Keys are
# either exact producers (`advice`) or prefixes ending at a `:` boundary
# (`hook:git-clone`, `worktree-new`). Longest match wins.
DEFAULT_PRODUCER_ESTIMATES_GB = {
    "worktree-new": 1.0, "scratch-new": 1.0, "evidence": 1.0,
    "advice": 2.0, "ci": 20.0, "hook:git-clone": 2.0, "hook:git-worktree-add": 1.0,
    "hook:cp-R": 1.0,
}


class MalformedState(Exception):
    """`budget.json` exists but is not a JSON object; never overwrite it."""


def finite_nonneg(value):
    """True for a real, finite, >= 0 number (bools rejected)."""
    return (isinstance(value, (int, float)) and not isinstance(value, bool)
            and value >= 0 and value < float("inf"))


def read_json(path):
    try:
        return json.loads(Path(path).read_text())
    except (OSError, ValueError):
        return None


def atomic_write(path, data):
    """Write JSON atomically; a crash leaves the previous file intact."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(data, handle, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def validate_estimates(data):
    """Return {producer: float} for a valid estimates document, else None.

    Accepts a flat `{producer: gb}` map or `{"producers": {...}}`. Any empty
    key, non-string key, bool, negative or non-finite value invalidates the
    whole document: a malformed calibration never silently becomes zeros.
    """
    if not isinstance(data, dict):
        return None
    raw = data.get("producers", data)
    if not isinstance(raw, dict):
        return None
    out = {}
    for key, value in raw.items():
        if key == "schema_version":
            continue
        if not isinstance(key, str) or not key.strip() or not finite_nonneg(value):
            return None
        out[key] = float(value)
    return out


def locked_mutate(state, mutate):
    """Run `mutate(budget)` under `state.lock`, rereading and atomic-replacing.

    `mutate` may only assign its own keys; concurrent govern/measure fields
    already present in the reread document survive untouched. A malformed
    existing `budget.json` raises `MalformedState` instead of being replaced
    with `{}` (fail closed: never erase concurrent state).
    """
    state = Path(state)
    state.mkdir(parents=True, exist_ok=True)
    with open(state / "state.lock", "a+") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            path = state / "budget.json"
            if path.exists():
                data = read_json(path)
                if not isinstance(data, dict):
                    raise MalformedState(str(path))
            else:
                data = {}
            mutate(data)
            atomic_write(path, data)
            return data
        finally:
            fcntl.flock(lock, fcntl.LOCK_UN)


def effective_stage(budget, config_budget=None):
    """Stage from budget.json, else the configured enforcement, else observe."""
    value = budget.get("stage") if isinstance(budget, dict) else None
    if value in STAGES:
        return value
    configured = config_budget.get("enforcement") if isinstance(config_budget, dict) else None
    return configured if configured in STAGES else "observe"


def effective_margin(budget, config_budget=None):
    """Margin (GiB) from budget.json, else the configured value, else 10."""
    value = budget.get("margin_gb") if isinstance(budget, dict) else None
    if finite_nonneg(value):
        return float(value)
    configured = config_budget.get("concurrency_margin_gb") if isinstance(config_budget, dict) else None
    return float(configured) if finite_nonneg(configured) else 10.0


def effective_estimates(state):
    estimates = validate_estimates(read_json(Path(state) / ADMISSION_SUBDIR / EFFECTIVE_FILE))
    return estimates or {}


def _longest_prefix_estimate(estimates, producer):
    best = None
    for key, value in estimates.items():
        if producer == key or producer.startswith(key + ":"):
            if best is None or len(key) > len(best[0]):
                best = (key, value)
    return best[1] if best else None


def default_estimate(producer):
    """Documented default for a known producer prefix; None for unknown ones."""
    return _longest_prefix_estimate(DEFAULT_PRODUCER_ESTIMATES_GB, producer or "")


def effective_estimate(state, producer):
    """Calibrated estimate for `producer`, else the documented default, else None."""
    if not isinstance(producer, str) or not producer:
        return None
    path = Path(state) / ADMISSION_SUBDIR / EFFECTIVE_FILE
    if path.exists() and validate_estimates(read_json(path)) is None:
        return None
    value = _longest_prefix_estimate(effective_estimates(state), producer)
    return value if value is not None else default_estimate(producer)


def _bump_pilot_epoch(data):
    if data.get("pilot_start") is None:
        return
    epoch = data.get("pilot_epoch")
    data["pilot_epoch"] = (epoch if isinstance(epoch, int) and not isinstance(epoch, bool) and epoch >= 0 else 0) + 1


def _check_stage_promotion(state, stage, now):
    import budget_acceptance
    missing = []
    if not _d2_approved():
        missing.append("d2_approval")
    lines, rc = budget_acceptance.pilot_check(state, now, record=False)
    if rc:
        missing.append("valid_pilot")
    if stage in ("refuse_red", "refuse_orange"):
        try:
            import policy_provenance
            approved = policy_provenance.main("approved", "budgets") == 0
        except Exception:
            approved = False
        if not approved:
            missing.append("d3_approval")
        if not any(line.startswith("pilot_floor_ok=true") for line in lines):
            missing.append("pilot_floor_ok")
        births = budget_acceptance._births(state, now - 86400, now)
        if births is None or births[2] >= 0.10:
            missing.append("births_slo")
    if stage == "refuse_orange":
        data = read_json(Path(state) / "budget.json") or {}
        since = data.get("stage_changed_at")
        if data.get("stage") != "refuse_red" or not finite_nonneg(since) or now - since < 7 * 86400:
            missing.append("seven_days_refuse_red")
    if missing:
        raise PrerequisitesMissing(missing)


def set_stage(state, stage, config_budget=None, now=None):
    """Record the new stage plus the prior stage for rollback; rc 2 on bad stage."""
    if stage not in STAGES:
        return None
    stamp = time.time() if now is None else now
    result = {}

    def mutate(data):
        prior = effective_stage(data, config_budget)
        result["previous"] = prior
        if STAGES.index(stage) > STAGES.index(prior):
            _check_stage_promotion(state, stage, stamp)
        data["stage"] = stage
        data["stage_previous"] = prior
        if stage != prior:
            data["stage_changed_at"] = stamp
            _bump_pilot_epoch(data)

    locked_mutate(state, mutate)
    return result["previous"]


def set_margin(state, gb, config_budget=None, now=None):
    """Record the new margin plus the prior value; increments pilot_epoch."""
    if not finite_nonneg(gb):
        return None
    stamp = time.time() if now is None else now
    result = {}

    def mutate(data):
        prior = effective_margin(data, config_budget)
        result["previous"] = prior
        data["margin_gb"] = float(gb)
        data["margin_previous"] = prior
        data["margin_changed_at"] = stamp
        _bump_pilot_epoch(data)

    locked_mutate(state, mutate)
    return result["previous"]


def promote_estimates(state, now=None, config_budget=None):
    """Copy a valid pending calibration over the effective file; returns count.

    The pending bytes are read, validated, written and hashed under the same
    `state.lock` as promotion, so an audit that replaces the pending file
    between a pre-lock read and the digest read can no longer attribute
    different bytes. A missing or malformed pending file changes nothing.
    """
    state = Path(state)
    stamp = time.time() if now is None else now
    with open(state / "state.lock", "a+") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            pending_path = state / ADMISSION_SUBDIR / PENDING_FILE
            try:
                pending_bytes = pending_path.read_bytes()
            except OSError:
                return None
            pending = validate_estimates(_parse_bytes(pending_bytes))
            if pending is None:
                return None
            budget_path = state / "budget.json"
            if budget_path.exists():
                data = read_json(budget_path)
                if not isinstance(data, dict):
                    raise MalformedState(str(budget_path))
            else:
                data = {}
            effective_path = state / ADMISSION_SUBDIR / EFFECTIVE_FILE
            atomic_write(effective_path, pending)
            digest = hashlib.sha256(effective_path.read_bytes()).hexdigest()
            data["estimates_hash"] = digest
            data["estimates_source_sha256"] = hashlib.sha256(pending_bytes).hexdigest()
            data["estimates_promoted_at"] = stamp
            _bump_pilot_epoch(data)
            atomic_write(budget_path, data)
        finally:
            fcntl.flock(lock, fcntl.LOCK_UN)
    return len(pending)


def _parse_bytes(raw):
    try:
        return json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, ValueError):
        return None


class PrerequisitesMissing(Exception):
    """A guarded control was asked to record state without its plan proofs."""

    def __init__(self, missing):
        super().__init__(",".join(missing))
        self.missing = list(missing)


def _d2_approved():
    """D2 (`admission_enforcement`) must be recorded through the policy owner."""
    try:
        import policy_provenance
        return policy_provenance.main("approved", "admission_enforcement") == 0
    except Exception:
        return False


def record_floor_epoch(state, floor_failed, epoch_id, now=None):
    """Count distinct validated pilot epochs; repeated reads cannot advance it."""
    stamp = time.time() if now is None else now
    result = {}

    def mutate(data):
        prior = data.get("pilot_floor_fail_epochs", 0)
        prior = prior if type(prior) is int and prior >= 0 else 0
        if data.get("pilot_floor_checked_epoch") != epoch_id:
            data["pilot_floor_fail_epochs"] = prior + 1 if floor_failed else 0
            data["pilot_floor_checked_epoch"] = epoch_id
            data["pilot_floor_checked_at"] = stamp
        result["count"] = data.get("pilot_floor_fail_epochs", prior)

    locked_mutate(state, mutate)
    return result["count"]


def _estimates_hash(state):
    try:
        return hashlib.sha256((Path(state) / ADMISSION_SUBDIR / EFFECTIVE_FILE).read_bytes()).hexdigest()
    except OSError:
        return None


def main(argv=None):
    argv = list(sys.argv[1:]) if argv is None else list(argv)
    state = Path(os.environ.get("DISK_MAGICIAN_STATE_DIR", Path.home() / ".disk_magician_state"))
    config_budget = {}
    try:
        import resolve_config
        config_budget = (read_json(resolve_config.resolve()) or {}).get("budgets") or {}
    except ImportError:
        pass
    if argv[:1] == ["set-stage"] and len(argv) == 2:
        try:
            previous = set_stage(state, argv[1], config_budget)
        except (PrerequisitesMissing, MalformedState) as exc:
            return print(f"set-stage:refused:{exc}", file=sys.stderr) or 2
        if previous is None:
            return print("usage: diskm budget set-stage observe|warn|refuse_red|refuse_orange", file=sys.stderr) or 2
        return 0
    if argv[:1] == ["set-margin"] and len(argv) == 2:
        try:
            gb = float(argv[1])
        except ValueError:
            gb = float("nan")
        if set_margin(state, gb, config_budget) is None:
            return print("usage: diskm budget set-margin <gb>", file=sys.stderr) or 2
        return 0
    if argv[:1] == ["promote-estimates"] and len(argv) == 1:
        try:
            if promote_estimates(state) is None:
                return print("promote-estimates: no valid admission/estimates.pending.json", file=sys.stderr) or 2
        except MalformedState as exc:
            return print(f"promote-estimates:malformed_state:{exc}", file=sys.stderr) or 2
        return 0
    return print("usage: diskm budget {set-stage|set-margin|promote-estimates}", file=sys.stderr) or 2


if __name__ == "__main__":
    sys.exit(main())
