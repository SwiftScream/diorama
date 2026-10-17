#!/usr/bin/env python3
"""Optional GeographicLib 2.1 generator for the 2,500 km regional contract."""

import csv
import math
from pathlib import Path
import random

import geographiclib
from geographiclib.geodesic import Geodesic

assert geographiclib.__version__ == "2.1"
rows = []


def add(latitude, longitude, bearing, distance):
    point = Geodesic.WGS84.Direct(latitude, longitude, bearing, distance)
    angle = math.radians(bearing)
    rows.append([f"regional-{len(rows)}", latitude, longitude, point["lat2"], point["lon2"],
                 distance * math.sin(angle), distance * math.cos(angle)])


for distance in [1_000_000, 1_500_000, 2_499_999.99]:
    for latitude in [-90, -89.999999, -60, -30, 0, 30, 60, 89.999999, 90]:
        for longitude in [-179.999999, 0]:
            for bearing in [0, 0.000001, 30, 45, 60, 89.999999, 90, 135, 180, 225, 270, 315, 359.999999]:
                add(latitude, longitude, bearing, distance)
randomizer = random.Random(302006)
for _ in range(2000):
    add(randomizer.uniform(-90, 90), randomizer.uniform(-180, 180),
        randomizer.uniform(-180, 180), randomizer.uniform(0, 2_499_999.99))
with (Path(__file__).resolve().parent / "regional.csv").open("w", newline="") as output:
    writer = csv.writer(output, lineterminator="\n")
    writer.writerow(["id", "originLatitude", "originLongitude", "latitude", "longitude", "east", "north"])
    writer.writerows(rows)
print(f"regional reference pairs: {len(rows)}")
