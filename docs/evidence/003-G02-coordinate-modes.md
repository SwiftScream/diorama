# 003-G02 — Regional and global coordinate modes

- Date: 2026-10-17
- Status: Complete; the owner approves the contract and requests a single-commit
  PR on 2026-10-17. No production implementation or dependency is added.
- Authority: [DD16's accepted amendment](../design-decisions/16-location-system.md#regional-and-global-coordinate-formats--owner-approved-2026-10-17)
  and [Plan 003 Q4](../plans/003-clean-slate-implementation.md#q4--stable-geographic-mapping-and-bounded-native-error-data).
- Background: [earlier Vincenty, polar, and radius evidence](003-G02-location-coordinate-codec.md).

## Owner-selected direction

The owner prioritizes readable editing, origin-only overrides, accurate
recording/replay, and preserving repeated positions and closed loops. Each
point remains relative to one shared origin, not the preceding point. The
owner accepts two explicit formats:

| Format | Stored horizontal values | Supported geographic extent |
| --- | --- | --- |
| Regional | East/north meters from the attachment origin | 2,500 km shortest WGS84 surface distance from that origin |
| Global | Latitude/longitude degree offsets from the attachment origin | All valid WGS84 coordinates; no geographic radius cutoff |

The numerical target is 1 cm. Neither format promises to preserve all distances,
angles, speeds inferred from coordinates, or route shape after relocation.
Origin overrides survive re-recording; individual point edits do not. Both
formats retain separate vertical components and measurement/delivery timing.

## Origin editing and privacy

Persist only the effective attachment origin, coordinate format, and point
offsets, alongside the ordinary recording metadata. The observed origin is
transient capture input for calculating offsets; it can itself be the effective
origin when no override or setup default replaces it. Neither replay nor subsequent
origin editing requires that original origin: do not retain it in a shadow
field, origin history, displacement-from-original value, or unused observed
value beside an authored origin override. The origin may retain its authored
marker without retaining its replaced value. When relocation is selected,
existing DD16 rules also exclude raw origins from candidate files, diagnostics,
and transformation failures.

Changing a recording's origin replaces that one value and retains its stored
offsets. Do not decode and re-encode the points during this edit. A recording
can therefore be relocated before sharing without including its original
absolute location. This applies to both formats and to edits after recording,
as well as the existing record-time origin override. Only origin overrides
survive re-recording; retaining offsets during an origin edit does not preserve
individual point overrides across a new capture.

The numerical replay functions take only an effective origin and one offset.
Regional relocation fixtures and the angular relocation checks exercise that
independence. G03 must prove the corresponding persistence property: a relocated
artifact contains only the replacement origin and retained offsets, and can be
loaded and replayed without the original origin or original recording.

## Regional interpretation

Use the WGS84 ellipsoid with semimajor axis `a = 6_378_137` meters, flattening
`f = 1 / 298.257223563`, and semiminor axis `b = a * (1 - f)`, as published by
[NGA](https://earth-info.nga.mil/index.php?action=wgs84&dir=wgs84).
Let `s` be the shortest geodesic distance from the attachment origin and
`azimuth` its initial direction clockwise from true north. Store
`east = s * sin(azimuth)` and `north = s * cos(azimuth)`. Decode with
`s = hypot(east, north)` and `azimuth = atan2(east, north)`, solving the direct
geodesic from the effective origin. These are surface-geodesic coordinates;
altitude, geoid corrections, datum epochs, and sensor error are independent.

The isolated [solver](../../Spikes/LocationCoordinates/Mapping.swift) evaluates
[Vincenty's equations (3)–(21)](https://geodesy.noaa.gov/PUBS_LIB/inverse.pdf),
including the full nested series, with binary64 `Double` arithmetic and radians
internally. Each solve stops when the angular iterate changes by at most
`1e-12` radians, evaluates the converged iterate, and has a 64-iteration cap.
Handle equatorial zero denominators and coincidence explicitly.

Origins and points accept finite latitude in `[-90, 90]` and longitude in
`[-180, 180]`. Canonical longitude is `[-180, 180)`; use the shortest wrapped
longitude difference and normalize negative zero. At a pole origin, preserve
its longitude as the east/north frame's reference meridian, interpreted as the
limit approaching that pole along the meridian. This follows the
[GeographicLib pole convention](https://geographiclib.sourceforge.io/html/java/net/sf/geographiclib/Geodesic.html).
Zero offset returns the canonical origin exactly. Coincident points, including
longitude aliases of the same pole, encode as positive zero components.
Position accuracy at a pole does not require a geographically unique longitude.

The radius is inclusive `2_500_000` meters. Bound the computed geodesic length
when encoding and `hypot(east, north)` when decoding. Radius bounds each point
from the common origin, not accumulated route length. Reject nonfinite values,
overflowing or excessive radius, and nonconvergence. Never fall back to another
model or switch formats when a regional input fails.

The 1 cm budget applies to forward offset-vector error, reconstructed-position
error, and both round trips. Radius admission uses the computed binary64 value
without tolerance or clamping; leave at least 1 cm inside the mathematical
boundary when authoring a fixture intended to survive conversion in either
direction. The final [probe](../../Spikes/LocationCoordinates/Probe.swift)
exercises this contract without adding a runtime or persistence API.

## Angular interpretation

The [angular experiment](../../Spikes/LocationCoordinates/AngularMapping.swift)
uses arithmetic and normalization, without calling the geodesic solver.

1. Origins and recorded coordinates must have finite latitude in `[-90, 90]`
   and longitude in `[-180, 180]`. Canonical longitude is `[-180, 180)`, and
   negative zero normalizes to positive zero.
2. Record the point's latitude minus the origin latitude. Store longitude
   difference reduced to `[-180, 180)`. A recorded point at either exact pole
   uses longitude offset zero, so longitude aliases of that physical point
   relocate together. A pole origin retains its longitude as a reference
   meridian, consistent with regional coordinates.
3. Offset admission requires finite latitude and longitude differences within
   `[-180, 180]`; the `+180` longitude alias canonicalizes to `-180` when
   recording. These natural difference bounds represent every valid geographic
   input pair. They are not a geographic radius limit or a count of completed
   revolutions around Earth.
4. Replay adds the retained offsets to the effective origin. Latitude is then
   in `[-270, 270]`, so one pole reflection is sufficient. Normalize longitude
   after the reflection. Origins themselves remain valid geographic inputs;
   reflection applies to the sum, not to malformed origins.
5. At zero offset, return the canonical origin, including its reference
   longitude at a pole. Longitude at an exact-pole output has no independent
   positional meaning. Positional comparisons account for that degeneracy.

The 1 cm budget applies to original-position round trips and agreement with
the angular relocation rule, measured as WGS84 surface-position error. It is
not an error bound against geodesic meter-offset relocation. The experiment
uses ECEF chord error, which is indistinguishable from surface separation at
this scale. Finite binary64 values remain unquantized.

### Pole reflection

For the raw sum `(latitude, longitude)`:

- Above `+90°`, replace latitude with `180° - latitude` and add `180°` to longitude.
- Below `-90°`, replace latitude with `-180° - latitude` and add `180°` to longitude.
- At either pole exactly, keep the computed longitude as its reference value.
- Reduce the final longitude to `[-180°, 180°)`.

| Raw latitude | Raw longitude | Normalized latitude | Normalized longitude |
| ---: | ---: | ---: | ---: |
| `+100°` | `20°` | `+80°` | `-160°` |
| `-100°` | `20°` | `-80°` | `-160°` |
| `+190°` | `20°` | `-10°` | `-160°` |
| `+270°` | `20°` | `-90°` | `-160°` |

Latitude reflects at the pole; it does not wrap from `+90°` to `-90°`.
Moving north through the North Pole remains in the northern hemisphere until
crossing the equator on the opposite meridian. The owner's illustrative
`+100° → -80°` would jump to the southern hemisphere. `+100° → +80°`, together
with the longitude adjustment, represents the intended crossing.

### What reflection does and does not preserve

Identical stored offsets always reconstruct identically, so repeated positions
and closed loops remain coincident. Supplying a previous origin value again
restores its route **provided the stored offsets are retained**. That value
would have to come from the caller; the recording does not retain it. Do not re-encode
materialized coordinates after an origin edit: reflection can give multiple
offset pairs the same resulting position, and re-encoding can lose the original
interpretation.

This is not a rigid or one-to-one movement of the globe. Two different points
can collapse onto a pole. For example, at origin `(80°, 20°)`, latitude offset
`10°` reaches the North Pole regardless of longitude offset. Nearby points
around an original pole can also separate drastically after relocation:
`(89.999999°, 0°)` and `(89.999999°, 180°)` start less than 0.25 m apart, but a
`-10°` latitude shift puts them over 2,000 km apart. An originally continuous
polar track can therefore acquire a large gap. This limitation exists in angular
addition itself; valid output normalization cannot remove it.

The experiment asserts these limitations as well as loop closure. Accepting
this global mode means accepting coordinate-shift semantics, including those
geometry changes. Preserving arbitrary global route continuity or shape would
require a different relocation definition and a further owner decision.

## Format selection

Use one explicit coordinate format per attachment, shared by all its sessions
and optional cached location. Regional is the default and global is an
explicit setup choice. Persistence must identify the format deliberately;
G03 owns the actual discriminator and schema spelling. Never infer the format
from numeric magnitudes or switch it automatically at a boundary.

An origin override retains the format and stored offsets. Changing format is
an explicit conversion or new recording, not an origin override or a
reinterpretation of the same numbers. Empty/access-only tracks retain the
existing absence of coordinate origins. G03 implements this accepted contract;
G02 does not introduce a configuration API.

## Evidence and reproduction

The regional corpus comprises 15,777 existing reference, relocation, and polar
pairs plus 2,702 new independent GeographicLib reference pairs. The new
[generator](../../Spikes/LocationCoordinates/generate-regional-reference.py)
uses 702 grid cases at 1,000, 1,500, and just inside 2,500 km, plus 2,000 random
interior cases with seed `302006`. Direct reference offsets come from their
independent input bearing and distance, not the Swift inverse under test.

The [angular probe](../../Spikes/LocationCoordinates/AngularProbe.swift) tests
35 origins against 91 destinations, including both exact poles, near poles,
longitude aliases, and antimeridian cases. It checks each original-position
round trip and relocation to `(80°, 179.9°)` against an independent
trigonometric direction calculation. Seven named reflection cases bring the
position-check count to 6,377. Additional assertions cover physical continuity
while crossing the destination pole, longitude aliases at a pole, closed loops,
retained offsets when restoring an origin, non-unique reflected offsets, and
the relocation collapse/gap limitations above.

The normal gate is offline and uses the committed fixtures:

```sh
Spikes/LocationCoordinates/run macos
Spikes/LocationCoordinates/run ios
python3 Spikes/LocationCoordinates/compare.py
scripts/lint
git diff --check master
```

Both platforms compile with Swift 6,
complete strict concurrency, warnings as errors, and both `-Onone` and `-O`.
Compilation targets macOS 15 and iOS Simulator 18. The iOS executable runs
through `simctl spawn`; `DIORAMA_SIMULATOR=<UDID>` selects a booted simulator.
Results are under `.build/<platform>`. Comparison covers both regional
and angular outputs across all four configurations, using the 1 cm budget.

Optional regeneration uses the isolated `geographiclib==2.1` Python reference
dependency disclosed in the [earlier evidence](003-G02-location-coordinate-codec.md#independent-references-and-dependency-disclosure):

```sh
python3 -m pip install --target /tmp/diorama-g02-reference geographiclib==2.1
PYTHONPATH=/tmp/diorama-g02-reference python3 Spikes/LocationCoordinates/generate-reference.py
PYTHONPATH=/tmp/diorama-g02-reference python3 Spikes/LocationCoordinates/generate-regional-reference.py
shasum -a 256 Spikes/LocationCoordinates/{reference,relocation,polar,regional}.csv
```

Fixture SHA-256 values:

```text
8fd894ecc8164c4b9492b572ab271b2170a03ab22326e9a90bf38d37661d357c  reference.csv
e0a4475f38daba9d870b92fe3385af7d31d50c4323f539d2f0b37441385b7c36  relocation.csv
dc2261519f739d614205a0b789c39f9d00b29cfd0048a9284dd11b93e2405b40  polar.csv
4cc394a82815b3253bcb7da174a5cd4f55054cb0ecec11642631a482f7a179a2  regional.csv
```

Observed on 2026-10-17 with Xcode 27.0 (`27A266a`), Apple Swift 6.4
(`swiftlang-6.4.0.34.1`), macOS 27.0.1 (`26A434`), and an iPhone 17 simulator
running iOS 27.0 (`24A434`), all arm64:

| Check | Result |
| --- | --- |
| Regional acceptance, each configuration | 18,479 pairs and 30 rejection checks pass. |
| Largest regional offset-vector error | Below `0.000017852` m; about 18 micrometers. |
| Largest regional reconstructed-position error | Below `0.000017829` m. |
| Regional round trips | Position below `2.55e-8` m; offset below `2.55e-8` m. |
| Maximum solver iterations | Five in either direction. |
| Angular acceptance, each configuration | 6,377 positions and 18 rejection checks pass, plus semantic assertions. |
| Largest angular positional error | `6.324326646180198e-9` m. |
| Canonical `scripts/lint` | SwiftFormat and strict SwiftLint pass. |

macOS and iOS results match exactly at the same optimization level. Changing
optimization produces at most `1.04451e-9` m of regional offset difference and
`5.02747e-9` m of regional position difference. All angular outputs match
exactly across the four configurations. Shell syntax, whitespace checks, and
379 local documentation file links also pass.

These are sampled numerical maxima, not proofs for every binary64 input. The
centimeter contract leaves margin without pursuing additional arithmetic
complexity. Deployment-target compilation does not claim execution on the
oldest supported OS. Linux has no Location product; the isolated gate
does not establish production coverage or Linux behavior. The PR also runs the
repository's required quality, macOS, iOS, and Linux checks.

## Earlier library exploration

Before the owner selected the two-format direction, temporary source inspection
considered [SwiftGeographicLib 1.0.4](https://github.com/sindreoyen/SwiftGeographicLib/tree/1.0.4),
[CGeodesic 2.1.0](https://github.com/sbooth/CGeodesic/tree/2.1.0), and the native
[geographiclib-swift 0.1.0](https://github.com/mjroncone/geographiclib-swift/tree/0.1.0).
The first two package GeographicLib-C 2.1.0, carry MIT licenses, and have no
external package dependencies. Their inspected releases compile for macOS and
iOS Simulator with the selected toolchain; the Swift wrapper's 26 existing
tests pass on macOS. The native port was inspected only; its inspected archive
contains no license notice. Read-only metadata inspection also considered
[Scott Hoyt's wrapper](https://github.com/scottrhoyt/geographiclib-swift) and
[dastrobu/geodesic](https://github.com/dastrobu/geodesic).

All candidate downloads and builds remain outside the repository in temporary
directories. None is proposed or approved for adoption. The owner-selected
direction uses the existing bounded solver for regional coordinates and simple
arithmetic for angular coordinates.

## Completion boundary

The owner approves the two-format contract, pole reflection, retained offsets,
and effective-origin-only privacy rule on 2026-10-17. Q4's geographic choice is
resolved. G03 implements and tests the versioned persistence schema separately.
No production source, manifest, dependency, or public API changes in G02.
The final runner retains the useful regional/angular checks; superseded
wide-radius calibration code and fixtures are removed after documenting their
outcomes in the historical evidence.
