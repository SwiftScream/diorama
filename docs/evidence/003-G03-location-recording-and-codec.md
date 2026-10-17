# 003-G03 — Location recording and version-one codec

- Date: 2026-10-17
- Status: Complete. The owner approves PR creation on 2026-10-17 after schema,
  precision, and normalized-delivery review. Full local macOS and iOS gates pass.
- Scope/model: The owner confirmed G03 and the plan's GPT-6 Sol, `high`
  recommendation on 2026-10-17. No production dependency was added.

## Result

`DioramaLocation` now owns a strict, Apple-only semantic recording and a
version-one payload registered with the existing deterministic JSON envelope.
The attachment has one explicit `meters` or `degrees` format and one effective
`coordinateOrigin`. Initial and session locations share a signed `latency` field.
Session timestamps derive from a session-start `timestampOrigin` plus cumulative
scheduled event delay minus latency. Initial snapshots use their origin minus
latency, with delivery offset zero. Independent altitude origins are grouped
under `altitudeOrigin`, with per-component overrides, and validated with their
`altitudeOffset` values and sibling vertical accuracy before admission. Sessions end
at an explicit open recording horizon; failures remain nonterminal.

Access has an initial observation segment and one ordered Core record per
authorization-request barrier. Each segment owns its notifications, and
request identity remains distinct from observed permission state. Unknown
native authorization or accuracy raw values cannot enter the strict model;
unknown persisted cases and fields fail decoding. The owner-approved
[DD16 macOS amendment](../design-decisions/16-location-system.md#macos-authorization-presentation--owner-approved-2026-10-17)
retains a known `whenInUse` state in the payload on macOS. G05 will present it
as native `authorizedAlways` there while iOS presents
`authorizedWhenInUse`; G03 performs no replay presentation or barrier rewrite.

The deliberate [schema](../location-schema-v1.md) and
[meters](../../Tests/DioramaLocationTests/Fixtures/meters.json),
[degrees](../../Tests/DioramaLocationTests/Fixtures/degrees.json), and
[access-only](../../Tests/DioramaLocationTests/Fixtures/access-only.json)
goldens fix the writer's current bytes. A changed effective origin leaves
point offsets intact and stores no displaced origin. Tests load relocated
artifacts and reconstruct coordinates without the original recording. The
regional solver implements the approved bounded WGS84 mapping; global offsets
use the approved angular and pole-reflection rule. Unit-bearing values remain
finite JSON numbers normalized at admission: three decimals for meter, speed,
and course values; eight for geographic degrees. Halfway cases round away from
zero. Tiny positive vertical accuracy becomes `0.001` m. Invalid raw values and
rounded excessive radii are rejected. Fresh recording and replay share normalized
semantic materialization, including absolute altitudes after origin/offset
addition. Later native delivery units apply this before record callbacks;
passthrough retains original values.

Bounded failures use Core's shared `NSErrorSnapshot` value tree and Persistence's
package-visible `NSErrorSnapshotPayload` wrapper for deliberate tagged JSON values. Integral codes and integer user-info values remain exact;
error user-info dates retain their available submillisecond precision as Unix
seconds. Timestamp origins use the shared ISO millisecond codec. The model
keeps native `CLLocation` and `NSError` objects outside stable records.

## Shared error codec preparation

The owner requests a separate preparatory commit for
[DD06's shared persistence payload](../design-decisions/06-runtime-to-snapshot-conversion.md#shared-nserror-persistence-payload--owner-approved-2026-10-17).
It adds the package-visible `NSErrorSnapshotPayload` wrapper and portable test
in Persistence before the Location codec. The Location codec adopts that wrapper
and removes its private error codec and duplicate test. The recursive tagged
value codec remains private; Core's semantic snapshot stays independent of
Codable. Location keeps its own metadata policy and enclosing schema version.
The three Location golden files remain byte-for-byte unchanged by extraction.

## Normalized fresh delivery foundation

The owner approves [DD09's system-wide delivery rule](../design-decisions/09-normalization-and-redaction.md#normalized-record-delivery-and-baseline-override-isolation--owner-approved-2026-10-17)
and [DD16's Location application](../design-decisions/16-location-system.md#normalized-recording-values-without-baseline-overrides--owner-approved-2026-10-17).
G03's shared semantic materializer reconstructs values from fresh normalized
origins/offsets for recording and persisted origins/offsets for replay. Absolute
altitudes are normalized after addition. Baseline origin overrides remain a
publication concern; they do not alter fresh delivery. G03 establishes the
value contract and tests it without implementing the later native adapter.

The precision helper now exposes both canonical binary values and their decimal
representation. Numeric fields encode Decimal numbers directly, including
independently tagged altitude-origin overrides. Encoding verifies that the
number round-trips to the canonical Double and rejects hidden additional
quantization. Finite whole Doubles beyond Decimal's range retain direct numeric
encoding. Existing golden JSON is unchanged. Shared error metadata is unaffected.

Tests compare a fresh normalized measurement to its persisted/replayed value,
including the bytes of a downstream request. A raw observation produces different
request bytes; an authored relocation affects the published replay while fresh
delivery retains its observed origin. Decimal output tests cover halfway values,
large values, origins, degree precision, and unprepared-value rejection.

## Review amendment and focused verification

The owner approves [DD16's persistence review amendment](../design-decisions/16-location-system.md#location-persistence-review-amendment--owner-approved-2026-10-17)
on 2026-10-17. Version one is updated in place before its PR; the old unmerged
layout is not a supported reader format. JSON uses `floor: { level }`, native
source-flag names, coordinate/altitude origins and offsets, and one location
structure for initial and batched values. The strict altitude group still makes
missing accuracy/value combinations unconstructible.

- `swift test -Xswiftc -warnings-as-errors --filter LocationCodecTests` passes
  all 17 focused macOS Location codec tests. New coverage exercises shared initial/batch
  latency, different ages within one batch, signed/future timestamps, delay
  editing, failure-inclusive elapsed time, cumulative/subtraction/date overflow,
  edited precision normalization, write/read idempotence, minimum vertical
  accuracy, angular aliases, combined rounded coordinate error below 1 cm,
  independent altitude overrides, and radius excess introduced by rounding.
- `swift test -Xswiftc -warnings-as-errors --filter NSErrorSnapshotPayloadTests`
  passes the shared error round-trip test moved to Persistence. It retains exact
  integer/real values, nested values, binary data, and submillisecond error dates,
  and rejects an invalid snapshot. This target is available on Linux without
  Core Location; this focused run is on macOS.
- Pinned Mint SwiftFormat and strict SwiftLint pass for the changed Swift files. The focused build retains warnings-as-errors and package strict
  concurrency settings.

## Final PR verification

- `scripts/verify-apple-toolchain` verifies the pinned Apple toolchain.
- `scripts/lint` passes repository-wide SwiftFormat and strict SwiftLint.
- `scripts/coverage swiftpm macos` passes all 508 host tests, coverage fixture
  checks, public system-authoring and resource-lifecycle compiler probes,
  strict Release builds, and examples. It exports `.build/coverage/macos.lcov`.
- `scripts/coverage ios` passes the Release build, all 507 Simulator tests,
  compiler probes, and LCOV export on iPhone 17 / iOS 27.0. Both Apple runs
  include all 17 codec tests and 24 Location tests overall.
- Required PR checks are Quality, macOS, iOS, and Linux, with Codecov uploads
  from the platform coverage jobs. The Linux gate runs the pinned toolchain,
  applicable tests (including the shared Persistence error payload), compiler
  probes, Release builds, and examples without importing `DioramaLocation`.
  Linux verification for this final revision uses that hosted gate.

G03 establishes the codec and prepared Core tracks. It does not capture
incremental native observations, deliver replay values, implement access
callbacks, or expose a consumer Location API; those are G03A and later units.
The iOS Simulator check does not establish behavior on an iOS 18 device.

## Initial snapshot naming review

The owner refines the attachment snapshot name to `initial`, with
`initial.location` and `initial.timestampOrigin`, and the internal type
`LocationInitialSnapshot`. This replaces `cached` and `LocationCachedFix`
without changing optionality, timing, or location values. The model, Core
track header, codec, schema reference, and meters/degrees goldens use the
new names. The earlier spelling remains unsupported before version one merges.

The 17 focused `LocationCodecTests` pass with warnings as errors. Changed-file
SwiftFormat and strict SwiftLint pass. The full local gates above precede this
naming update; [PR #101's original CI run](https://github.com/SwiftScream/diorama/actions/runs/39031825936)
also passes Quality, macOS, iOS, Linux, and both Codecov checks. The same required
PR gates verify the naming update, with focused local verification as requested.

## Shared timestamp origin review

The owner selects one construction rule for Date and Location: normalize native
dates and parsed ISO text to the nearest millisecond, with halfway cases away
from the Unix epoch, then validate the portable date and UTC offset ranges.
[DD15's shared timestamp origin amendment](../design-decisions/15-clock-system.md#shared-timestamp-origins--owner-approved-2026-10-17)
records the shared contract. Core's package-visible `TimestampOrigin` replaces
Date's `WallOrigin` and Location's `LocationTimeOrigin`, including their shared
signed millisecond advancement. Location now accepts submillisecond native
origins and normalizes them before timestamp reconstruction. Date's behavior
is preserved by the extraction.

Core remains independent of Codable. Location uses Persistence's opt-in
`TimestampOriginPayload` ISO scalar wrapper; Date retains its system-owned
string/override decoding and validates the effective origin through the same
Core type. All Date and Location golden files remain unchanged.

The shared extraction and Date adoption form a separate preparatory commit.
Location adoption is included in the codec commit after owner-approved fixup
squashing. Focused verification:

- `swift test -Xswiftc -warnings-as-errors --filter 'TimestampOrigin|DioramaDateTests'`
  passes 63 tests: all 60 Date tests, two Core origin tests, and one Persistence
  scalar test. New coverage includes rounding, retained offsets, idempotence,
  portable bounds, signed advancement, invalid input, and authored origins.
- `swift test -Xswiftc -warnings-as-errors --filter LocationCodecTests` passes
  all 17 codec tests, including shared normalization before initial/session
  latency reconstruction and unchanged golden JSON.
- Changed-file SwiftFormat and strict SwiftLint pass. Full local platform
  gates above precede this extraction; the same required PR matrix verifies
  updates, with focused local verification as requested.
