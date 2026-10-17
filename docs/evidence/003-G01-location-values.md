# 003-G01 — Apple Location measurement, access, and failure values

## Scope

G01 establishes the internal validated measurements used to prepare Location
recordings, an internal native-enum access snapshot, and shared bounded error
information. A preparatory Core commit supplies `NSErrorSnapshot` for Location,
URLSession, and future first-party integrations. The `DioramaLocation` product
is Apple-only; the Core helper is available on Apple platforms and Linux.
No bespoke location, floor, or error type is exposed to consumers.

Under [DD16's native consumer amendment](../design-decisions/16-location-system.md#native-consumer-locations-with-opt-in-replay-fidelity--owner-approved-2026-10-17),
later async/delegate delivery uses `CLLocation`. Recording and passthrough
forward original native objects. Replay uses ordinary native objects unless
an attachment opts into ellipsoidal-altitude fidelity or a recorded non-nil
floor. Both replay options default off. The recorded measurement model always
retains both fields when valid, independently of those options.

G01 does not implement a native manager, east/north mapping, a Location codec,
replay configuration, a replay subclass, or delivery. Those remain later Phase G
work. The [native framework spike](003-G01-cllocation-native-framework-spike.md)
records the subclass feasibility and secure-archive evidence; its runtime
techniques are not production dependencies.

## Internal measurements

`LocationMeasurement` is an internal `Equatable`, `Sendable` value. It retains
`CLLocationCoordinate2D`, finite nonnegative horizontal accuracy, a timestamp
within the shared representable wall-date range, and independent optional
vertical, speed, course, floor-level, and source-information measurements.
Latitude must be in `[-90, 90]` and longitude in `[-180, 180]`; longitude `180`
normalizes to `-180`.

A vertical group requires positive finite accuracy and two finite heights:
orthometric and WGS84 ellipsoidal. Neither height is derived from the other.
Speed and course groups require finite nonnegative values and accuracies;
course must be in `[0, 360]`, with `360` normalized to `0`. Floor is an optional
signed integer and remains available even when vertical measurements are
absent. Source information consists of two Boolean flags; absence differs
from both flags being false. No native reference object is retained.

A scalar initializer interprets native nonpositive vertical accuracy and
negative speed/course or accuracy sentinels as absent groups. Malformed
required fields or present measurements reject the complete value. These
normalization rules apply to internal recording preparation; original live
`CLLocation` objects remain the consumer values. The internal type has no
CLLocation-style convenience getters, distance methods, copying, or archiving.

The internal `LocationAccessState` holds service availability, native
`CLAuthorizationStatus`, and native `CLAccuracyAuthorization` as one
observation without rejecting plausible cross-field combinations. The later
facade exposes native authorization types directly. Unknown future raw values
are not preserved by a Diorama wrapper; G03 defines handling at the stable
record boundary.

## Bounded error information

Core's package-visible `NSErrorSnapshot` retains domain, integer code, and a
possibly empty user-info tree. `NSErrorSnapshotValue` models the supported tree;
`NSErrorSnapshotCapture` returns the optional validated snapshot and
`NSErrorSnapshotOmission` facts. These types are available to other modules in
the package without becoming public dependency API. No Location-specific
failure wrapper or alias remains. Both async and delegate consumers will
receive native `Error` values, per
[DD16's error amendment](../design-decisions/16-location-system.md#shared-error-snapshots-and-native-delivery--owner-approved-2026-10-17).

The current structural allowlist is string, signed 64-bit integer, finite
`Double`, Boolean, `Data`, `Date`, array, and string-keyed dictionary. Dates
must fit the shared wall-date range. Any nonempty string key up to 256 UTF-8
bytes is eligible; no Core Location-specific key is required. Preparation and
redaction remain responsible for consumer-selected confidentiality policy.

The limits are:

| Limit | Maximum |
| --- | ---: |
| Collection nesting below a user-info value | 4 levels |
| Values in one user-info tree | 128 |
| Entries in any one array or dictionary | 32 |
| Domain or key | 256 UTF-8 bytes |
| One string | 4,096 UTF-8 bytes |
| One data value | 16,384 bytes |
| Combined keys, strings, and data | 65,536 bytes |

Native capture visits top-level keys in sorted order. An unsupported type,
nonfinite number, excessive size/depth, or collection with an unsupported
descendant omits that complete top-level entry while retaining independent
siblings. Each omission reports the key and reflected runtime type, never the
value or its description. A missing or oversized domain makes the entire
failure unrepresentable; later native capture must treat that as unhealthy
preparation rather than a dependency failure it can publish. The G03 codec
must encode these typed values deliberately; no `NSError` archive is used.

`makeError()` reconstructs a fresh `NSError` from the validated domain, code,
and recursively materialized supported values. Native object identity, custom
subclasses, and arbitrary Swift error identity are not restored. Capture
detaches mutable Foundation input. The helper returns omission facts without
emitting diagnostics or deciding publication health. Each system supplies that
context and its preparation policy. H09 reuses these mechanics while retaining
URLSession's narrower metadata rules and typed supplements. The shared type
does not conform to `Codable` or dictate a cross-system persistence schema.

## Verification before the shared-helper extraction

The preceding native-delivery revision (`da401a8`) passed these checks. These
results describe that revision, not a rerun of the full gates after extraction:

- `swift test --filter DioramaLocationTests -Xswiftc -warnings-as-errors`
  passed all 11 Location tests. They cover field fidelity, canonicalization,
  rejection, floor independent of vertical validity, source absence, native
  access values, recursive failure bounds, and value-free omission warnings.
- `scripts/check` passed on macOS: formatting, strict lint, the complete host
  test suite, compiler probes, Release builds, and examples.
- `scripts/coverage ios` passed the Release build, Simulator tests, compiler
  probes, and LCOV export. All 11 Location tests pass on iOS, and
  `LocationMeasurement.swift` appears in the generated coverage data.
- The pinned `swift@sha256:64bab762bc73a3fda6d9ebc559258bd6d7660c10a705bb25ecacad2f99d066f9`
  Apple Container run of `scripts/coverage swiftpm linux` passed applicable
  tests, Release builds, examples, compiler probes, and LCOV export. Location
  remains excluded from the Linux target graph.
- `swift-symbolgraph-extract` on the built macOS module exported only
  `LocationFailure` and `LocationFailureValue` roots. The measurement groups,
  access snapshot, and capture helpers remain internal; no public bespoke
  location or floor type remains.

Generated binaries, symbol graphs, and coverage data remain build artifacts.
Native replay subclass behavior is still separate spike evidence; these gates
verify G01's internal values and package boundary, not later replay delivery.

## Shared-helper review verification

The owner requests minimal verification during review, with full gates deferred
until final PR readiness. Focused verification covers the extracted helper and
the remaining Location values; the earlier four failure tests move to Core.
New tests cover native reconstruction and fresh identity, mutable Foundation
input detachment, and invalid-domain capture. Tests import Core without
`@testable`, exercising package access across module boundaries.

- `swift test --filter 'NSErrorSnapshotTests|DioramaLocationTests' -Xswiftc
  -warnings-as-errors` passes seven Core snapshot tests and seven Location tests
  on macOS.
- Focused SwiftFormat and strict SwiftLint checks pass for the two extracted
  Core files.
- The pinned x86_64 Linux container passes
  `swift test --filter NSErrorSnapshotTests -Xswiftc -warnings-as-errors`:
  all seven snapshot tests pass using swift-corelibs Foundation. The Location
  target remains excluded from that package graph.

The full host suite, iOS Simulator, coverage, and compiler-probe gates are not
rerun for this review extraction.
