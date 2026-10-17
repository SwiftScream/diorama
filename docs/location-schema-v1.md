# Location payload schema version 1

The Apple-only `diorama.location` system has a deliberate version-one payload
registered with Diorama's existing versioned JSON envelope. The writer emits
`schemaVersion: 1` in the system header. The payload contains only stable
semantic values; it contains no native `CLLocation`, `NSError`, archive, or
object identity. The canonical [meters](../Tests/DioramaLocationTests/Fixtures/meters.json),
[degrees](../Tests/DioramaLocationTests/Fixtures/degrees.json), and
[access-only](../Tests/DioramaLocationTests/Fixtures/access-only.json) documents
fix the exact spelling and JSON layout. G03 establishes an internal codec and
prepared Core track layout; later Location units supply consumer attachment
configuration and delivery.

## Coordinates, altitude, and location values

`coordinateFormat` is `meters` or `degrees`. It and `coordinateOrigin` occur
together whenever an initial or session location exists; empty and access-only
payloads omit both. All locations use that explicit format. Meter offsets use
the bounded WGS84 mapping formerly called regional; degree offsets use the
angular interpretation formerly called global. The approved [G02 contract](evidence/003-G02-coordinate-modes.md)
retains its algorithms and limits, as amended by the [G03 persistence review](design-decisions/16-location-system.md#location-persistence-review-amendment--owner-approved-2026-10-17).

`coordinateOrigin` is the effective WGS84 coordinate, with `latitudeDegrees`
in `[-90, 90]` and canonical `longitudeDegrees` in `[-180, 180)`. A location's
`coordinateOffset` contains either `eastMeters` and `northMeters` with vector
radius at most 2,500,000 m, or `latitudeDegrees` and `longitudeDegrees` offsets
in `[-180, 180]`. Longitude `+180` writes as `-180`. Coordinates are explicit
scalars, not encoded native objects.

The coordinate origin accepts an ordinary value or `{ "override": ... }`.
The reader also accepts the shared `observed` editing form or both tags,
selecting the override. Only the effective origin is retained. Changing it
retains normalized offsets exactly, without original-origin data. Prepare new
offsets relative to the normalized origin that will be persisted.

`altitudeOrigin` contains required `meters` (mean-sea-level/orthometric height)
and `ellipsoidalMeters` components. Each independently supports the shared
observed/override forms. It occurs only when some location has altitude.
A location's optional `altitudeOffset: { meters, ellipsoidalMeters }` adds to
the corresponding origins. Its sibling `verticalAccuracyMeters` is positive;
the offset and accuracy must both occur or both be omitted. They validate into
one strict runtime measurement. Horizontal accuracy is required and nonnegative.

Optional `floor: { level }` is an absolute integer building level, independent
of altitude validity. Optional speed contains nonnegative `metersPerSecond`
and `accuracyMetersPerSecond`. Optional course contains canonical `degrees`
in `[0, 360)` and nonnegative `accuracyDegrees`. Optional `sourceInformation`
contains `isSimulatedBySoftware` and `isProducedByAccessory`; omission remains
distinct from two false flags.

## Timestamp and delivery time

Every location, initial or batched, contains signed `latency` beside its other
measurements. There is no `point` wrapper or successive measurement delta.
The optional `initial` snapshot contains `timestampOrigin` alongside `location`.
It represents the location available when the attachment starts, before session
updates. It is omitted when no initial location is available. A session has
`timestampOrigin` only when it contains at least one location. Its origin is
the wall-time reference corresponding to session start; the initial origin is
the initial snapshot's capture reference. These origins are ISO 8601 values
using the shared millisecond codec. Session origins support authored overrides.
Date and Location share Core's `TimestampOrigin`: native dates and parsed ISO
origins both normalize to milliseconds at construction. Encoding uses the
admitted instant and retained numeric display offset through Persistence's
ISO scalar wrapper; it introduces no further precision loss.

Each session event is a `batch` with ordered `locations` or a nonterminal
`failure` with a bounded error. Nonnegative `delay` is successive from session
start or the preceding event. Sum all event delays, including failures, through
the current batch to obtain its delivery offset. Reconstruct each timestamp:

```
session: timestampOrigin + cumulative delivery offset - location.latency
initial: timestampOrigin - location.latency
```

Locations in one batch share its delivery offset and have independent latencies.
Negative latency permits a timestamp ahead of the logical delivery timeline;
older and backward-moving timestamps remain representable. Delays and latency
use the shared `s`/`ms` grammar. Validate arithmetic and materialized dates
before admission. Use scheduled offsets, never actual callback arrival time.
Reading initial data does not change its timestamp. Editing a delivery delay
also shifts subsequent timestamps unless their latencies are adjusted.

Empty sessions omit the origin. Every session has required
`conclusion: "openAtRecordingHorizon"`; caller stop is not a dependency event.
The standard-update surface has no dependency completion callback.

## Decimal precision

The reader accepts additional decimal places and normalizes into the same
strict values as capture preparation. Record consumers receive materialized
fresh normalized values, following [DD09](design-decisions/09-normalization-and-redaction.md#normalized-record-delivery-and-baseline-override-isolation--owner-approved-2026-10-17).
Baseline overrides are merged into publication only; they never affect record
consumer output. Passthrough retains original live values.
Use nearest decimal rounding, with halfway cases away from zero:

| Values | Maximum decimal places |
| --- | --- |
| Meter coordinate offsets, altitude origins/offsets, horizontal/vertical accuracy | 3 |
| Speed and speed accuracy (m/s), course and course accuracy (degrees) | 3 |
| Coordinate origin and degree coordinate offsets | 8 |

Write JSON numbers without padded zeros; normalize negative zero. Canonicalize
angles after rounding. Positive vertical accuracy below the representable
minimum becomes `0.001` m; other accuracies may round to zero. Validate raw
ranges first and reject any rounded meter offset exceeding the radius, without
clamping. Origins and retained offsets support later independent origin edits.
The combined coordinate codec retains the 1 cm budget. Absolute altitudes are
also normalized after adding origin and offset, so record/replay consumers use
the same canonical value. Reconstruct coordinates and timestamps using the same
materialization path in both modes, with fresh origins before baseline merge.

A normalized Double approximates the selected decimal. Encoding writes the
corresponding Decimal as a JSON number directly and checks that its conversion
back preserves the canonical Double. It cannot silently round an unprepared
value. Finite whole values beyond Decimal's range encode directly, requiring no
fractional rounding. Bounded error user-info numbers and dates are exempt from
measurement rounding.

Missing optional fields are omitted; `null`, unknown fields, mixed coordinate
formats, and out-of-range values are rejected. This reviewed layout remains
schema version one; the earlier unmerged G03 spelling is not a reader format.

## Access and errors

`access` has a complete `initialState`, an ordered
`initialNotifications` segment, and ordered `requests`. Each request contains
its `whenInUse` or `always` barrier and the notifications anchored to that
request invocation. This maps to a Core access track whose first claimable
record is the initial segment; each later request has one separate record.
Notifications contain a nonnegative successive `delay` and a complete state.
Current-state reads and individual notifications do not become separate Core
claims. Permission cases are `notDetermined`, `restricted`, `denied`,
`whenInUse`, and `always`; accuracy cases are `full` and `reduced`.

Unknown native permission or accuracy raw values cannot enter the strict
recording. A later native recorder must keep live delivery unchanged, emit a
safe diagnostic, and mark its candidate unhealthy. Unknown persisted cases
fail validation before replay. The known `whenInUse` case remains stored as
recorded on macOS; [G05's approved replay rule](design-decisions/16-location-system.md#macos-authorization-presentation--owner-approved-2026-10-17)
will present it as native `authorizedAlways` there. No codec rewrite or
barrier-match substitution performs that presentation change.

Failures adopt Persistence's package-visible `NSErrorSnapshotPayload`
[shared error representation](persistence-schema-v1.md#shared-bounded-nserror-payload).
Location retains ownership of its versioned enclosing schema and metadata
policy; the extraction changes no version-one JSON bytes.

Failures store `domain`, integral `code`, and `userInfo`. Each supported
user-info value has an explicit `type` (`string`, `integer`, `real`, `boolean`,
`data`, `date`, `array`, or `dictionary`) and a corresponding `value`. Binary
data is Base64; error user-info dates use exact finite Unix-second numbers so
submillisecond data from the shared error snapshot does not silently change.
Timestamp origins still use the shared ISO 8601 codec. The shared
`NSErrorSnapshot` limits nesting, counts, and byte sizes before a decoded
failure enters a strict session. No Foundation archive is stored.

The version-one reader rejects unsupported schema versions, unknown keys,
unknown cases, missing required fields, invalid numbers and durations, excess
radius, invalid origin combinations, and bounded-error violations. Decoded
content becomes one strict runtime interpretation before Core admits its
session and access tracks. Later schema changes require an explicit reader;
the general [persistence policy](persistence-schema-v1.md) applies.
