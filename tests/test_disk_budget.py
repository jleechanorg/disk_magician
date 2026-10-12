#!/usr/bin/env python3
"""tests/test_disk_budget.py — admission zones and the policy table (plan Task 3, spec §7.1)."""
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scripts"))
import disk_budget  # noqa: E402

STAGES = ("observe", "warn", "refuse_red", "refuse_orange")


@pytest.mark.parametrize("free,expected", [
    (250, "GREEN"), (100, "GREEN"), (99.9, "ORANGE"), (60, "ORANGE"), (59.9, "RED"),
    (30, "RED"), (29.9, "BLACK"), (15, "BLACK"), (14.9, "FLOOR"), (-5, "FLOOR")])
def test_zone_boundaries(free, expected):
    assert disk_budget.zone(free) == expected


# (admission zone, class over budget, {stage: rc}) straight from the plan's policy table.
TABLE = [
    ("GREEN", False, dict(observe=0, warn=0, refuse_red=0, refuse_orange=0)),
    ("GREEN", True, dict(observe=0, warn=0, refuse_red=0, refuse_orange=0)),
    ("ORANGE", False, dict(observe=0, warn=10, refuse_red=10, refuse_orange=10)),
    ("ORANGE", True, dict(observe=0, warn=10, refuse_red=10, refuse_orange=75)),
    ("RED", False, dict(observe=0, warn=10, refuse_red=75, refuse_orange=75)),
    ("RED", True, dict(observe=0, warn=10, refuse_red=75, refuse_orange=75)),
]
FREE_FOR = {"GREEN": 150, "ORANGE": 80, "RED": 45, "BLACK": 25, "FLOOR": 10}


@pytest.mark.parametrize("d2", [False, True])
@pytest.mark.parametrize("stage", STAGES)
@pytest.mark.parametrize("zone_name,over,expected", TABLE)
def test_policy_table_non_emergency_rows(zone_name, over, expected, stage, d2):
    # est 0, margin 0: admission zone == df zone; non-emergency rows ignore D2.
    assert disk_budget.decide(stage, FREE_FOR[zone_name], 0, 0, over, d2) == (zone_name, expected[stage])


@pytest.mark.parametrize("stage", STAGES)
@pytest.mark.parametrize("over", [False, True])
def test_emergency_rows_need_d2(stage, over):
    assert disk_budget.decide(stage, FREE_FOR["BLACK"], 0, 0, over, True) == ("BLACK", 76)
    assert disk_budget.decide(stage, FREE_FOR["FLOOR"], 0, 0, over, True) == ("FLOOR", 75)
    # Without D2 the emergency rows return 10 (warn and proceed), never 0.
    assert disk_budget.decide(stage, FREE_FOR["BLACK"], 0, 0, over, False) == ("BLACK", 10)
    assert disk_budget.decide(stage, FREE_FOR["FLOOR"], 0, 0, over, False) == ("FLOOR", 10)


def test_margin_moves_the_admission_zone():
    # 105 free, est 70, margin 10 -> zone(25) BLACK -> 76; margin 0 -> zone(35) RED.
    assert disk_budget.decide("observe", 105, 70, 10, False, True) == ("BLACK", 76)
    assert disk_budget.decide("refuse_red", 105, 70, 0, False, True) == ("RED", 75)
    assert disk_budget.decide("observe", 105, 70, 0, False, True) == ("RED", 0)


@pytest.mark.parametrize("text", ["nan", "inf", "-inf", "-1", "-0.01", "x"])
def test_est_gb_rejects_non_finite_and_negative(text):
    with pytest.raises(ValueError):
        disk_budget.est_gb(text)


@pytest.mark.parametrize("text,value", [("0", 0.0), ("1.5", 1.5), ("1e3", 1000.0)])
def test_est_gb_accepts_finite_non_negative(text, value):
    assert disk_budget.est_gb(text) == value


def test_hard_floor_on_projected_free():
    # projected = 105 - 95 = 10 < 15 -> FLOOR whatever the margin; oversized est likewise.
    assert disk_budget.decide("observe", 105, 95, 0, False, True) == ("FLOOR", 75)
    assert disk_budget.decide("observe", 105, 200, 10, False, True) == ("FLOOR", 75)
