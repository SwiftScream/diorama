#!/usr/bin/env python3
"""Compare complete Swift outputs across platforms/configurations; stdlib only."""

import csv
import math
from pathlib import Path

ROOT = Path(__file__).resolve().parent / ".build"
BUDGET = 0.01
PATHS = [ROOT / platform / f"{optimization}.csv"
         for platform in ["macos", "ios"] for optimization in ["Onone", "O"]]


def read(path):
    with Path(path).open() as source:
        return list(csv.DictReader(source))


def cartesian(row):
    latitude, longitude = math.radians(float(row["latitude"])), math.radians(float(row["longitude"]))
    flattening = 1 / 298.257223563
    eccentricity_squared = flattening * (2 - flattening)
    radius = 6_378_137 / math.sqrt(1 - eccentricity_squared * math.sin(latitude) ** 2)
    return (radius * math.cos(latitude) * math.cos(longitude),
            radius * math.cos(latitude) * math.sin(longitude),
            radius * (1 - eccentricity_squared) * math.sin(latitude))


baseline = read(PATHS[0])
assert baseline
for path in PATHS[1:]:
    rows = read(path)
    assert len(rows) == len(baseline)
    maximum_offset, maximum_position = 0.0, 0.0
    for expected, actual in zip(baseline, rows):
        assert expected["id"] == actual["id"]
        offset = math.hypot(float(expected["east"]) - float(actual["east"]),
                            float(expected["north"]) - float(actual["north"]))
        position = math.dist(cartesian(expected), cartesian(actual))
        assert math.isfinite(offset) and offset <= BUDGET, (path, expected["id"], offset)
        assert math.isfinite(position) and position <= BUDGET, (path, expected["id"], position)
        maximum_offset, maximum_position = max(maximum_offset, offset), max(maximum_position, position)
    print(f"PASS {path.relative_to(ROOT)}: {len(rows)} pairs; max offset difference {maximum_offset:g} m; "
          f"max position difference {maximum_position:g} m")

baseline = read(str(PATHS[0]) + ".angular")
assert baseline
for path in PATHS[1:]:
    rows = read(str(path) + ".angular")
    assert len(rows) == len(baseline)
    maximum = 0.0
    for expected, actual in zip(baseline, rows):
        assert expected["id"] == actual["id"]
        difference = math.dist(cartesian(expected), cartesian(actual))
        assert math.isfinite(difference) and difference <= BUDGET, (path, expected["id"], difference)
        maximum = max(maximum, difference)
    print(f"PASS {path.relative_to(ROOT)}.angular: {len(rows)} positions; max difference {maximum:g} m")
