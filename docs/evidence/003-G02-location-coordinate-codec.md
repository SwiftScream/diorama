# 003-G02 — Historical WGS84 mapping and radius evidence

- Date: 2026-10-17
- Status: Completed exploration; the final contract is
  [regional and global coordinate modes](003-G02-coordinate-modes.md).
- Plan: [003-G02](../plans/003-clean-slate-implementation.md#003-g02--wgs84-mapping-and-numerical-contract-evidence).

## Findings retained after cleanup

The initial bounded Vincenty experiment used a 1,000 km radius and conservative
`±85°` latitude limits. Adding 9,264 independent polar cases established that
both exact poles and pole crossings work without the latitude restriction or
its artificial boundary snap. Worst measured error remained below 7.3
micrometers at that radius. A pole origin's longitude defines its reference
meridian; aliases of the same physical pole encode as zero displacement.

The owner then requested a wider-radius millimeter investigation. The same
solver, `1e-12` radian convergence threshold, and 64-iteration cap supported an
18,000 km sampled envelope with margin under 1 mm. Near-antipodal inverse
nonconvergence prevented a full-globe guarantee even with a centimeter budget.
The owner ultimately selected regional meter offsets within 2,500 km and
unrestricted global angular offsets, with a 1 cm numerical contract.

The superseded radius calibration harness and its fixtures are removed with
owner approval. Their measured outcomes are recorded below; the retained
[runner](../../Spikes/LocationCoordinates/run) verifies only the final contract.
The polar and short-distance reference corpora remain useful regression evidence.
No production implementation or dependency resulted from this investigation.

## Archived radius calibration

The sweep evaluated 112,170 cases in macOS and iOS Simulator executables, each
at `-Onone` and `-O`. Eleven coarse radii from 1,000 to 20,000 km each used
1,020 systematic and 2,000 deterministic random directions. Dense groups at
18,000, 18,500, 18,750, 18,900, 18,925, 18,950, and 19,000 km each used 5,850
systematic and 4,000 random directions. The 18,000 km group also sampled 10,000
random interior distances. Seeds were `302003` and `302004`.

Inputs covered all latitudes, exact and near poles, cardinal and near-cardinal
bearings, antimeridian crossings, and both longitude signs. Only the radius
guard was raised to observe failures; the equations and convergence controls
were unchanged. The table rounds measured maxima upward to six decimal places.
Over-budget counts include any of the four error metrics; nonconvergence is
reported separately.

| Radius | Largest forward offset-vector error | Largest reconstructed-position error | Cases exceeding 1 mm | Nonconvergence |
| --- | ---: | ---: | ---: | ---: |
| 10,000 km, coarse | 0.078721 mm | 0.067329 mm | 0 / 3,020 | 0 |
| 15,000 km, coarse | 0.185017 mm | 0.086389 mm | 0 / 3,020 | 0 |
| 18,000 km, dense plus interior | 0.516041 mm | 0.090141 mm | 0 / 19,850 | 0 |
| 18,500 km, dense | 0.699293 mm | 0.090405 mm | 0 / 9,850 | 0 |
| 18,750 km, dense | 0.847179 mm | 0.090479 mm | 0 / 9,850 | 0 |
| 18,900 km, dense | 0.967034 mm | 0.090501 mm | 0 / 9,850 | 0 |
| 18,925 km, dense | 0.988985 mm | 0.090497 mm | 0 / 9,850 | 0 |
| 18,950 km, dense | 1.013021 mm | 0.090493 mm | 28 / 9,850 | 0 |
| 19,000 km, dense | 1.066509 mm | 0.090494 mm | 136 / 9,850 | 0 |
| 19,950 km, coarse | 20.147262 mm | 0.090109 mm | 1,228 / 2,354 converged | 666 / 3,020 |

The largest sampled radius with every case below 1 mm was 18,925 km, leaving
only about 0.011 mm of margin. This was not a universal cutoff. The intermediate
18,000 km recommendation left about 0.484 mm of margin; the final 2,500 km
contract makes no use of that wider envelope. At 18,000 km the sweep required
at most eight forward and five inverse iterations. Its largest position and
offset round-trip errors were about 0.000177 mm and 0.001575 mm.

All four configurations agreed on counts, over-budget outcomes, nonconvergence,
and maximum iteration counts. macOS and iOS matched at the same optimization
level; maximum-error reports differed by at most `3.613621e-8` mm between
optimization levels. Environment: Xcode 27.0 (`27A266a`), Apple Swift 6.4
(`swiftlang-6.4.0.34.1`), macOS 27.0.1 (`26A434`), and iPhone 17 simulator
with iOS 27.0 (`24A434`), arm64.

Near-antipodal inverse failure is an established limitation of Vincenty's
method; see [GeographicLib's algorithm comparison](https://geographiclib.sourceforge.io/html/python/geodesics.html).
Increasing the iteration cap or relaxing positional precision does not establish
a global inverse. The selected angular format instead defines a different,
explicit relocation rule without requiring a geodesic solver.

## Practical alternatives and relocation

The optional reference generator compares two inexpensive approximations with
the geodesic offsets. The test starts at `(45°, 0°)` with initial
bearing `45°`. The first approximation uses the origin's WGS84 meridional and
prime-vertical curvature radii as fixed latitude/longitude scales. The second
uses a sphere with mean radius `(2a + b) / 3`.

| Distance from origin | Fixed origin scale: vector error | Mean-radius sphere: vector error |
| --- | ---: | ---: |
| 1 km | 0.087687 m | 2.014182 m |
| 100 km | 887.149498 m | 202.987243 m |
| 1,000 km | 98,478.108675 m | 2,216.471478 m |

These measured errors rule out those particular approximations for centimeter
accuracy against radial geodesic semantics over regional tracks. An ECEF tangent
plane is another possible coordinate definition, but would preserve projected
chord components instead of the proposed surface distance and initial bearing.
It is not implemented or presented as a failed numerical experiment here.
A general geodesic library would support a wider problem domain; that capability
does not justify a production dependency for this bounded contract.

The numerical target describes calculation accuracy against the chosen mapping.
It does not promise millimeter preservation of every distance inside a relocated
route. The mapping preserves each point's distance and bearing from the origin;
distances and angles between other points can change on the curved ellipsoid.

For a route with one point due east and another due north at equal radius,
moving the origin from latitude `0°` to `75°` changes the geodesic distance
between those two points by the following independently calculated amounts:

| Radius | Change in the distance between the two non-origin points |
| --- | ---: |
| 1 km | 0.000000037 m |
| 100 km | 0.036395196 m |
| 1,000 km | 37.125382561 m |

These are examples, not upper bounds for all route shapes or destinations.
The last example is about 0.0026% of that edge's length. The contract makes no
global shape-preservation promise. If exact non-origin edge lengths become a
requirement, that is a different relocation contract requiring owner discussion.
The wider numerical envelope does not add a route-shape guarantee to DD16:
an intercontinental route can be represented accurately, but relocating it can
distort its non-origin edges substantially.

## Independent references and dependency disclosure

[GeographicLib Python 2.1](https://github.com/geographiclib/geographiclib-python/tree/v2.1)
generates the committed numeric fixtures. Its Karney geodesic algorithm is
independent of this Swift Vincenty implementation. Its documented WGS84 accuracy
is approximately 15 nm, comfortably below the 1 mm test threshold.
See the [official interface documentation](https://geographiclib.sourceforge.io/html/python/interface.html).

The exact exploration dependency is PyPI `geographiclib==2.1`, from
`https://github.com/geographiclib/geographiclib-python`, tag `v2.1`, MIT/X11
licensed, Python 3.7 or later, with no declared runtime package dependencies.
Only `geographiclib.geodesic.Geodesic` supplies reference direct/inverse
calculations. It was installed under `/tmp/diorama-g02-reference`, outside the
repository. No package code is vendored, imported by Swift, added to Mint or
SwiftPM, or required to execute the committed spike. No production adoption is
proposed. Regeneration remains an optional isolated experiment.

The retained [reference generator](../../Spikes/LocationCoordinates/generate-reference.py)
produces 6,488 original reference pairs, 25 relocations of identical offsets,
and 9,264 polar pairs. Original reference cases include nine named pairs,
4,456 grid pairs, and 2,023 accepted random pairs from seed `302`. That initial
corpus filters destinations beyond `±85°`; the separate polar corpus covers
both poles and increasingly close neighboring latitudes, including the nearest
binary64 latitude below `90°`. Direct polar fixtures retain independent input
offsets rather than deriving them from rounded endpoints with the solver under
test. Distances range from zero and nanometers through just inside 1,000 km.

The generator also reproduces the approximation and relocation examples above.
The final evidence records fixture hashes, regeneration commands, the additional
2,500 km corpus, current execution results, and the accepted numerical rules.
