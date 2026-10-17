#!/usr/bin/env python3
"""Optional reference regeneration, never part of the offline Swift spike gate.

Run with GeographicLib 2.1 installed in an isolated temporary directory.
The normal run reads committed numeric fixtures and needs no Python package.
"""

import csv
import math
from pathlib import Path
import random

import geographiclib
from geographiclib.geodesic import Geodesic

assert geographiclib.__version__ == "2.1"
GEODESIC = Geodesic.WGS84
ROOT = Path(__file__).resolve().parent
ROWS = []


def pair(name, latitude, longitude, other_latitude, other_longitude):
    result = GEODESIC.Inverse(latitude, longitude, other_latitude, other_longitude)
    azimuth = math.radians(result["azi1"])
    distance = result["s12"]
    east, north = distance * math.sin(azimuth), distance * math.cos(azimuth)
    ROWS.append((name, latitude, longitude, other_latitude, other_longitude, east, north))


def direct(name, latitude, longitude, bearing, distance):
    result = GEODESIC.Direct(latitude, longitude, bearing, distance)
    if abs(result["lat2"]) <= 85:
        pair(name, latitude, longitude, result["lat2"], result["lon2"])


# Named coordinate pairs do not originate from a direct geodesic calculation.
for name, start, end in [
    ("equatorial-degree", (0, 0), (0, 1)),
    ("meridional-degree", (0, 0), (1, 0)),
    ("sydney-canberra", (-33.8688, 151.2093), (-35.2809, 149.13)),
    ("san-francisco-los-angeles", (37.7749, -122.4194), (34.0522, -118.2437)),
    ("antimeridian-east", (45, 179.9), (45, -179.9)),
    ("antimeridian-west", (-45, -179.9), (-45, 179.9)),
    ("longitude-alias", (30, 180), (30, -180)),
    ("latitude-north-boundary", (84, 0), (85, 0)),
    ("latitude-south-boundary", (-84, 0), (-85, 0)),
]:
    pair(name, *start, *end)

# Retain the initial latitude-limited corpus for comparison with the first G02
# experiment. The polar corpus below extends coverage through both exact poles.
# A Cartesian grid including very short lines, equatorial and cardinal cases,
# high latitudes, nearly cardinal bearings, and antimeridian crossings.
counter = 0
for latitude in [-85, -80, -60, -30, -1e-8, 0, 1e-8, 30, 60, 80, 85]:
    for longitude in [-179.999999, -120, 0, 179.999999]:
        for bearing in [0, 0.001, 30, 45, 89.9999, 90, 135, 180, 225, 270, 315, 359.999]:
            for distance in [0, 1e-6, 0.01, 1, 100, 10_000, 100_000, 500_000, 999_999.99]:
                direct(f"grid-{counter}", latitude, longitude, bearing, distance)
                counter += 1

randomizer = random.Random(302)
for index in range(2048):
    direct(f"random-{index}", randomizer.uniform(-85, 85), randomizer.uniform(-180, 180),
           randomizer.uniform(-180, 180), randomizer.uniform(0, 999_999.99))

with (ROOT / "reference.csv").open("w", newline="") as output:
    writer = csv.writer(output, lineterminator="\n")
    writer.writerow(["id", "originLatitude", "originLongitude", "latitude", "longitude", "east", "north"])
    writer.writerows(ROWS)
print(f"reference pairs: {len(ROWS)}")

# Preserve a single route's offsets while changing its origin. Independently
# reconstruct all points at each destination with GeographicLib's direct solver.
route = [(0, 0), (1, 2), (-300, 400), (30_000, -40_000), (600_000, 700_000)]
with (ROOT / "relocation.csv").open("w", newline="") as output:
    writer = csv.writer(output, lineterminator="\n")
    writer.writerow(["id", "originLatitude", "originLongitude", "latitude", "longitude", "east", "north"])
    for name, latitude, longitude in [("sydney", -33.8688, 151.2093), ("equator", 0, 0),
                                       ("san-francisco", 37.7749, -122.4194),
                                       ("date-line", -60, 179.9), ("high-latitude", 75, 30)]:
        for index, (east, north) in enumerate(route):
            result = GEODESIC.Direct(latitude, longitude, math.degrees(math.atan2(east, north)), math.hypot(east, north))
            writer.writerow([f"{name}-{index}", latitude, longitude, result["lat2"], result["lon2"], east, north])

polar_rows = []
polar_latitudes = [85, 89, 89.9, 89.99, 89.9999, 89.999999, 89.99999999,
                   89.9999999999, math.nextafter(90, 0), 90]
for sign in [-1, 1]:
    for magnitude in polar_latitudes:
        latitude = sign * magnitude
        for longitude in [-179.999999, 0, 45, 179.999999]:
            for bearing in [0, 0.000001, 30, 45, 89.999999, 90, 135, 180, 225, 270, 315, 359.999999]:
                for distance in [0, 1e-9, 1e-6, 0.01, 1, 100, 10_000, 100_000, 999_999.99]:
                    result = GEODESIC.Direct(latitude, longitude, bearing, distance)
                    angle = math.radians(bearing)
                    # Use the input offset directly to independently test the
                    # direct solution even when endpoint latitude rounds to 90.
                    polar_rows.append([f"polar-{len(polar_rows)}", latitude, longitude,
                                       result["lat2"], result["lon2"],
                                       distance * math.sin(angle), distance * math.cos(angle)])
            for other_longitude in [-180, 0, 45, 180]:
                for label, other_latitude in [("pole-target", sign * 90), ("pole-crossing", latitude)]:
                    result = GEODESIC.Inverse(latitude, longitude, other_latitude, other_longitude)
                    if result["s12"] > 999_999.99:
                        continue
                    angle = math.radians(result["azi1"])
                    polar_rows.append([f"{label}-{len(polar_rows)}", latitude, longitude,
                                       other_latitude, other_longitude,
                                       result["s12"] * math.sin(angle), result["s12"] * math.cos(angle)])
with (ROOT / "polar.csv").open("w", newline="") as output:
    writer = csv.writer(output, lineterminator="\n")
    writer.writerow(["id", "originLatitude", "originLongitude", "latitude", "longitude", "east", "north"])
    writer.writerows(polar_rows)
print(f"polar pairs: {len(polar_rows)}")

# Quantify two cheaper alternatives against exactly the same radial semantics.
for distance in [1_000, 100_000, 1_000_000]:
    latitude, longitude, bearing = 45, 0, 45
    target = GEODESIC.Direct(latitude, longitude, bearing, distance)
    phi = math.radians(latitude)
    eccentricity_squared = GEODESIC.f * (2 - GEODESIC.f)
    prime = GEODESIC.a / math.sqrt(1 - eccentricity_squared * math.sin(phi) ** 2)
    meridian = GEODESIC.a * (1 - eccentricity_squared) / (1 - eccentricity_squared * math.sin(phi) ** 2) ** 1.5
    flat_east = math.radians(target["lon2"] - longitude) * prime * math.cos(phi)
    flat_north = math.radians(target["lat2"] - latitude) * meridian
    expected = distance / math.sqrt(2)
    flat_error = math.hypot(flat_east - expected, flat_north - expected)
    print(f"fixed-origin curvature approximation at {distance:g} m: {flat_error:.9f} m vector error")
    phi2, delta_longitude = math.radians(target["lat2"]), math.radians(target["lon2"] - longitude)
    sine_east = math.cos(phi2) * math.sin(delta_longitude)
    sine_north = math.cos(phi) * math.sin(phi2) - math.sin(phi) * math.cos(phi2) * math.cos(delta_longitude)
    sine_arc = math.hypot(sine_east, sine_north)
    cosine_arc = math.sin(phi) * math.sin(phi2) + math.cos(phi) * math.cos(phi2) * math.cos(delta_longitude)
    mean_radius = GEODESIC.a * (3 - GEODESIC.f) / 3
    sphere_distance = mean_radius * math.atan2(sine_arc, cosine_arc)
    sphere_error = math.hypot(sphere_distance * sine_east / sine_arc - expected,
                              sphere_distance * sine_north / sine_arc - expected)
    print(f"mean-radius sphere at {distance:g} m: {sphere_error:.9f} m vector error")

# Projection distortion is separate from calculation error. A diagonal between
# non-origin points changes slightly when the same offsets move across WGS84.
for radius in [1_000, 100_000, 1_000_000]:
    lengths = []
    for latitude in [0, 75]:
        east = GEODESIC.Direct(latitude, 0, 90, radius)
        north = GEODESIC.Direct(latitude, 0, 0, radius)
        lengths.append(GEODESIC.Inverse(east["lat2"], east["lon2"], north["lat2"], north["lon2"])["s12"])
    print(f"relocation non-origin edge change, radius {radius:g} m, 0 to 75 degrees: {abs(lengths[1] - lengths[0]):.9f} m")
