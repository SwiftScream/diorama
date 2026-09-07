# Decision 16: Initial location system

- Status: Accepted
- Last updated: 2026-09-06
- Depends on: [Decision 1: Common abstraction](01-common-abstraction.md),
  [Decision 2: Shared and system-specific semantics](02-shared-vs-system-semantics.md),
  [Decision 3: Recorded behaviors](03-recorded-behaviors.md),
  [Decision 4: Replay selection](04-replay-selection.md),
  [Decision 5: Consumption and verification](05-consumption-and-verification.md),
  [Decision 6: Runtime-to-snapshot conversion](06-runtime-to-snapshot-conversion.md),
  [Decision 8: Schema compatibility](08-schema-compatibility.md),
  [Decision 9: Normalization and redaction](09-normalization-and-redaction.md),
  [Decision 10: Lifecycle and ownership](10-lifecycle-and-ownership.md),
  [Decision 14: Real-time replay scheduler](14-real-time-replay-scheduler.md), and
  [Decision 15: Initial clock system](15-clock-system.md)

## Decision

What portable location behavior does Diorama record and replay, how do existing
Core Location delegate consumers adopt it, and how are location, access,
failure, timing, privacy, mismatch, and lifecycle semantics represented?

## Context

A standard location manager combines several behavior shapes:

- synchronous current state, such as authorization and the latest location;
- demand-driven commands, such as requesting authorization or starting
  updates;
- long-lived streams of batched locations and nonterminal failures;
- mutable configuration that influences a live provider;
- Apple-specific runtime objects that cannot all be recreated through public
  initializers.

Diorama must not turn those behaviors into one request/response exchange or
require test-only identifiers in application calls. It also must not claim
transparent compatibility with all of `CLLocationManager`. A narrow,
intentional interface makes unsupported services visible and allows the stable
domain to remain independent of Core Location.

## Platform boundary

The portable location domain, persistence model, and replay service are
available on every Diorama platform, including Linux. Diorama does not provide
a live Linux location source or claim to record a Linux system location API.
A consumer can still use the portable model and replay service in Linux tests.

Live recording from Core Location is implemented in an Apple-only adapter. It
owns a private `CLLocationManager` and converts callbacks while their native
values are valid. Core Location types do not enter the stable scenario model.

Any number of named location attachments may coexist. Each owns independent
access state, coordinate origin, current location, update sessions, cursors,
diagnostics, and configuration. Consumers needing concurrent independent
location domains attach multiple systems.

## Consumer interfaces

### Portable async interface

The portable service is `AsyncSequence`-first. Each update subscription emits
an event value conceptually shaped as:

```swift
enum LocationEvent {
    case locations([DioramaLocation])
    case failure(DioramaLocationFailure)
}
```

Failures are elements rather than thrown sequence termination because a
location provider may report a failure and later recover. Batch boundaries and
the order of locations inside each batch are preserved. Authorization changes
use a separate state sequence.

Exact generic declarations and type-erasure choices remain implementation
details. The public contract must be `Sendable` where its isolation permits and
must not expose a process-specific clock instant.

### Apple delegate interface

Existing delegate-based applications should not need to adopt async iteration
solely to use Diorama. The Apple adapter therefore supplies a Diorama-owned,
delegate-shaped facade instead of subclassing `CLLocationManager`:

```swift
@MainActor
protocol DioramaLocationManagerDelegate: AnyObject {
    func locationManager(
        _ manager: DioramaLocationManager,
        didUpdateLocations locations: [DioramaLocation]
    )

    func locationManager(
        _ manager: DioramaLocationManager,
        didFailWithError error: Error
    )

    func locationManagerDidChangeAuthorization(
        _ manager: DioramaLocationManager
    )
}
```

The facade is deliberately not a `CLLocationManager` subclass. Subclassing
would inherit live operations that Diorama does not intercept and would make
the supported replay surface difficult to state honestly.

The facade initially provides the conceptual surface:

```swift
@MainActor
final class DioramaLocationManager {
    weak var delegate: DioramaLocationManagerDelegate?

    var locationServicesEnabled: Bool { get }
    var authorizationStatus: CLAuthorizationStatus { get }
    var accuracyAuthorization: CLAccuracyAuthorization { get }
    var location: DioramaLocation? { get }

    var desiredAccuracy: CLLocationAccuracy { get set }
    var distanceFilter: CLLocationDistance { get set }
    var activityType: CLActivityType { get set }
    var pausesLocationUpdatesAutomatically: Bool { get set }

    func requestWhenInUseAuthorization()
    func requestAlwaysAuthorization()
    func startUpdatingLocation()
    func stopUpdatingLocation()
}
```

The Core Location configuration types are acceptable in this Apple-only
facade. Configuration is forwarded to the private manager in live modes and
retained locally during replay. It is not persisted, matched, or verified in
the initial implementation.

The facade and its callbacks are main-actor isolated. The adapter creates and
operates its private manager on that actor. Portable async consumers may await
events from other actors.

## Why location values are portable

The Apple delegate retains native `Error`, authorization, accuracy, and
configuration types where they can be reproduced through public API. Location
delivery instead uses `DioramaLocation`.

`CLLocation.floor` and `CLLocation.ellipsoidalAltitude` are get-only, and the
public initializer surface cannot independently reconstruct them. Opaque native
archives, private mutation, and runtime subclass tricks would undermine
editability, portability, and compatibility. A portable value can faithfully
carry those fields while keeping migration largely mechanical.

## Stable location value

The initial stable value contains:

- a horizontal position relative to the attachment origin;
- nonnegative horizontal accuracy;
- an optional vertical estimate with positive accuracy and independently
  represented orthometric and WGS84 ellipsoidal altitudes;
- optional logical floor level;
- an optional nonnegative speed estimate with nonnegative accuracy;
- an optional course estimate with nonnegative accuracy;
- a required wall-clock measurement timestamp;
- optional source information distinguishing absence from two false flags.

Native invalid sentinels normalize to semantic absence. Negative speed or
course is absent. Nonpositive vertical accuracy makes both altitude values
absent. Replay converts absence to the appropriate canonical native sentinel
only when an Apple convenience requires it.

All numeric values must be finite. Course is canonical in `[0, 360)`. Stable
source information records `simulatedBySoftware` and `producedByAccessory`.

## Coordinate representation

Each named attachment has one horizontal WGS84 origin. Every recorded
coordinate is stored as an east/north displacement in meters from that common
origin rather than as a displacement from the preceding location.

Common-origin displacement makes route relocation a one-origin edit, prevents
cumulative conversion error, and lets one position be edited without shifting
later positions. The mapping algorithm and Earth constants are part of the
stable codec and require cross-platform golden tests. It is intended for local
and regional tracks; relocating a route spanning a substantial portion of the
globe does not promise identical global geodesic shape.

Orthometric and ellipsoidal altitude have distinct optional origins and
per-location offsets. A single `up` value would conflate height above
approximate mean sea level with height above the WGS84 ellipsoid. The first
valid value establishes each vertical origin independently. Missing vertical
components remain missing. Floor is an optional absolute integer because it is
a logical building level, not a physical height.

An attachment containing only access behavior or no location values has no
coordinate or vertical origin. An optional initial cached location participates
in the same coordinate space.

## Location measurement and delivery time

Measurement time and callback delivery time are independent:

- each update session owns one ISO 8601 measurement origin;
- each location stores a signed successive measurement delta from the previous
  location in that session, including locations inside one batch;
- each delivered batch, failure, and conclusion stores a nonnegative
  successive delay from the preceding delivered event, or from session start
  for the first event.

Measurement deltas materialize `DioramaLocation.timestamp` but never schedule a
callback. Delivery delays accumulate into scheduler deadlines but never change
the measurement timestamp. This represents cached fixes, duplicate timestamps,
wall-clock corrections, and delayed callback delivery without conflation.

An initial cached location outside an update session stores its timestamp as a
standalone ISO 8601 measurement origin. It becomes the facade's initial
non-consuming `location` value.

Location time reuses decision 15's millisecond-precision ISO 8601 and `s`/`ms`
codecs. A test comparing measurement time with current time should attach and
coordinate a Diorama clock explicitly; the location system does not require or
silently consult a clock attachment.

## Update-session lifecycle

Each named attachment permits one active update session at a time:

- start while inactive begins or selects the next session group;
- start while active is idempotent;
- stop while active cancels runtime delivery and releases scheduler work;
- stop while inactive is idempotent;
- a later start begins or selects the next session with a fresh delivery anchor.

Portable iterator cancellation has the same runtime effect as stop. Consumers
needing independent simultaneous sessions use separate named attachments.

Caller stop and cancellation are not stable events and are not verified. If
observation ends because the caller stops, no dependency terminal event was
observed, so the group retains the explicit `openAtRecordingHorizon`
conclusion. Replay delivers its recorded events and then remains active and
silent until caller stop or execution finalization.

Every native `didFailWithError` callback is a timed nonterminal event. Diorama
does not infer that a particular code ends standard updates. The current
location becomes the final location in a delivered batch before the consumer
callback runs. A failure leaves it unchanged. Reads of current location do not
consume records.

## Access state

Authorization and service availability form one complete state:

```swift
struct LocationAccessState {
    var servicesEnabled: Bool
    var permission: LocationPermission
    var accuracy: LocationAccuracyAuthorization
}
```

Permission distinguishes not determined, restricted, denied, when in use, and
always. Accuracy distinguishes reduced and full. Unknown future native values
are preserved explicitly rather than mapped to a known case. Cross-field
combinations are not overvalidated because platform policy may evolve.

Each attachment records one initial state and an ordered lifecycle containing
authorization-request barriers and complete state notifications. Current-state
reads are non-consuming. Immediately before a notification is delivered,
Diorama atomically installs its complete state, so reads from inside the
callback observe the new value. Duplicate notifications remain observable and
are not deduplicated.

Service availability is attachment-scoped in the snapshot even though it is
device-global on Apple platforms. This avoids hidden coordination between
independently configured systems. Disabling services is a state transition,
not a stream failure; a recorded failure callback may follow separately.

## Authorization request barriers

The access lifecycle is one ordered state machine. Scheduled notifications
proceed until a demand-driven request marker is reached. A matching
`requestWhenInUseAuthorization()` or `requestAlwaysAuthorization()` call
consumes the marker and subsequent notification delays anchor to the replay
invocation time.

This ordering does not assert that a request caused a later state. It records
only that the state notification followed the request. A state change observed
without a preceding request marker schedules automatically and can represent a
Settings or policy change.

Request timing itself is not compared with the recording. An expected request
that is never made remains unused in the final report. An unexpected, duplicate,
or wrong request is a serious runtime mismatch and never contacts Core
Location.

Authorization observation begins when the delegate or portable authorization
sequence is registered. The initial access state is synchronously available
before its initial notification.

## Error fidelity

The Apple delegate continues to receive `Error`. Core Location failures are
documented as `NSError` values, so the stable error stores at least domain and
integer code plus supported user-info values. Replay constructs a fresh
`NSError`; existing domain-and-code handling remains valid.

Record and passthrough forward the native error to the consumer after capturing
its stable representation. Replay delivers the reconstructed error. The
warning below makes any resulting loss of user-info fidelity visible.

The persistence codec supports an explicit, recursively bounded set of
property-list-like user-info values. Unsupported values emit a warning that
identifies the key and runtime type without rendering the value. Recording
continues and omits only that value. This warning does not make the candidate
unhealthy.

Localized descriptions, concrete custom Swift error identity, and arbitrary
object graphs are not promised. Known Core Location supplements may gain typed
codecs when a supported capability requires them. Portable async delivery uses
a stable failure value representing the same recorded domain, code, and
supported information.

Recorded dependency failures remain separate from Diorama diagnostics. A
replay mismatch is never delivered through `didFailWithError`.

## Scalar encoding

Location measurements use JSON numbers with unit-bearing field names, such as
`latitudeDegrees`, `eastMeters`, `horizontalAccuracyMeters`,
`speedMetersPerSecond`, and `courseDegrees`. Floor is an integer. Access states
and known failure codes use descriptive string cases.

The writer emits the shortest decimal that round-trips each finite `Double`,
normalizes negative zero to zero, and does not quantize by default. Latitude is
validated within `-90...90`; longitude is canonical in `[-180, 180)`. Accuracy,
speed, and course validation follows their semantic rules. Projects may apply
an explicit quantizing normalization policy before persistence.

## Origin defaults and overrides

Coordinate origins and measurement-time origins are the only initial location
fields with re-record-preserving override semantics. Location events are too
variable for safe positional override merging.

Origin precedence is:

1. an explicit persisted authored override;
2. a setup-configured default origin;
3. the fresh observed origin.

Setup defaults are re-evaluated for every recording and are persisted as the
ordinary stable baseline, not as an authored override. Otherwise the first
default would become sticky and later setup changes would have no effect.

Re-recording first derives fresh coordinate offsets and measurement deltas from
fresh observed origins. It then substitutes the winning origins. An explicit
coordinate-origin override remains attachment-scoped. A measurement-origin
override is retained only for the corresponding sequential session that still
exists. If its session disappears, the override is dropped and may be reported
informationally.

All sessions, batches, locations, access transitions, failures, delivery
delays, and non-origin values are replaced wholesale on location re-record.
Direct fixture edits remain useful for replay but are not merged into a new
recording. Git history is the recovery mechanism.

## Privacy boundary

A setup default can relocate a freshly observed route and retime its
measurements before the candidate is encoded. The raw origins exist transiently
to calculate offsets but must not appear in the candidate file, diagnostics,
or transformation errors.

Relocation hides the exact origin but is not comprehensive redaction. Route
shape, timing, floor changes, speed, altitude, source flags, and other context
may still disclose information. Diorama records location observations with
replayable fidelity by default, and consumers remain responsible for the data
they commit.

## Runtime mismatches

Corrupt, incompatible, or missing named location tracks fail before a replay
execution becomes runnable. Nonthrowing operations use the common serious
diagnostic handler at runtime:

- starting when no recorded session remains diagnoses the mismatch and, if the
  handler returns, enters an inert active session;
- an unexpected authorization request diagnoses the mismatch, returns without
  consuming another marker, and leaves the access lifecycle at its barrier;
- no mismatch falls back to live Core Location;
- stop always releases an active or inert session idempotently.

The inert continuation emits no dependency failure or synthetic completion.
Consumers can install the accepted trap-or-test-failure handler while the core
retains deterministic behavior if that handler returns.

## Finalization and escaped handles

The adapter owns its private live manager. Finalization cancels pending replay
delivery, drains already claimed callbacks, stops the private manager in live
modes, detaches its native proxy, ends portable sequences as runtime cleanup,
and returns only after Diorama-owned location callbacks are quiescent.

An escaped facade is frozen and inert:

- current location and access properties return their last values;
- configuration getters return their last local values;
- configuration setters diagnose lifecycle misuse and have no effect;
- stop remains an idempotent no-op;
- start and authorization requests emit serious execution-closed diagnostics;
- delegate replacement cannot cause a callback;
- no operation contacts Core Location.

A selected session with undelivered events is used but incomplete in the final
report. Ending a portable sequence at execution cleanup is not persisted as a
dependency completion, and the delegate facade invents no completion callback.

## Deferred Core Location capabilities

The initial facade does not expose:

- one-shot location requests;
- temporary full-accuracy authorization requests;
- background-update configuration;
- deferred updates;
- significant-change monitoring;
- headings, visits, regions, ranging, or beacons.

Each has distinct operations, callbacks, errors, and availability. A later
extension must define those semantics and persistence before adding the native
surface; unsupported operations never silently pass through during replay.

## Implementation progression

The clean-slate plan should split this milestone into small slices:

1. portable access, coordinate, measurement, source, floor, and error values;
2. numeric validation plus WGS84 and time codecs with cross-platform golden
   tests;
3. portable sequential update sessions over the shared scheduler;
4. access-state notifications and request barriers;
5. current-location state, nonterminal failures, and mismatch continuation;
6. setup defaults, origin overrides, re-record replacement, and privacy tests;
7. the main-actor Apple facade and private Core Location bridge;
8. finalization, escaped handles, multiple attachments, and platform tests.

The portable implementation must be exercised on Linux without pretending to
provide a live Linux source. Apple integration tests should use controlled
adapter boundaries where simulator Core Location cannot provide deterministic
live behavior.

## Consequences

Benefits:

- Existing delegate code keeps a familiar lifecycle without fragile native
  subclassing.
- Floor and ellipsoidal altitude replay faithfully through a portable value.
- Location, authorization, and availability retain their distinct semantics.
- Routes are readable, relocatable, and compatible with setup-time privacy
  normalization.
- Cached measurement time and callback delivery time cannot be conflated.
- Nonterminal failures and open streams replay without inventing completion.
- Portable model and replay work on Linux while live Core Location stays Apple
  only.

Costs:

- Delegate consumers change manager, delegate, and delivered location types.
- The initial facade intentionally covers only a subset of Core Location.
- WGS84 conversion and floating-point canonicalization require careful tests.
- Omitted unsupported error information can reduce fidelity despite a warning.
- Re-recording discards manual non-origin edits.
- Multiple simultaneous consumers require multiple named attachments initially.

## Explicit non-decisions

This decision does not determine:

- exact Swift type names, generic declarations, or target boundaries;
- global-route relocation with guaranteed geodesic equivalence;
- scenario pseudonyms shared by location and clock origins;
- whole-event or whole-track authored overrides;
- matching update sessions by configuration instead of sequence;
- a live Linux provider;
- the deferred Core Location capabilities listed above.

## Review questions

1. **Platform and system boundary: Resolved.** Stable models and replay are
   portable; only Apple platforms receive a live Core Location adapter.
2. **Consumer API: Resolved.** Portable consumers use async event sequences,
   while Apple delegate consumers receive a narrow, main-actor Diorama facade.
3. **Native compatibility: Resolved.** Do not subclass `CLLocationManager`.
   Preserve reproducible Apple types but deliver `DioramaLocation` so floor and
   ellipsoidal altitude remain faithful.
4. **Coordinate representation: Resolved.** Each attachment has a WGS84 origin
   and common-origin east/north meter offsets.
5. **Stable payload: Resolved.** Preserve reconstructible measurements, floor,
   ellipsoidal altitude, timestamp, and source flags while normalizing invalid
   sentinels to absence.
6. **Timing: Resolved.** Measurement timestamps use signed successive deltas;
   delivery uses independent nonnegative successive delays.
7. **Session lifecycle: Resolved.** One session is active per attachment;
   caller stop is runtime cancellation and groups without dependency conclusion
   remain explicitly open.
8. **Access state: Resolved.** Availability, permission, and accuracy form one
   non-consuming current state with complete transition notifications.
9. **Authorization requests: Resolved.** Request markers gate the ordered access
   lifecycle without claiming causal knowledge.
10. **Failures: Resolved.** Apple delegates retain `Error`; stable NSError
    domain, code, and supported user info reconstruct replay values. Unsupported
    user-info values warn and are omitted without blocking recording.
11. **Mismatch: Resolved.** Serious diagnostics plus deterministic inert
    continuation keep nonthrowing APIs offline.
12. **Facade scope: Resolved.** Standard updates, core access state, current
    location, common configuration, and when-in-use/always requests form the
    initial Apple surface.
13. **Re-recording: Resolved.** Only coordinate and measurement origins retain
    overrides; all variable location behavior is replaced wholesale.
14. **Origin precedence: Resolved.** Explicit persisted override wins over a
    re-evaluated setup default, which wins over the fresh observation.
15. **Vertical model: Resolved.** Orthometric and ellipsoidal heights use
    independent optional origins and offsets; floor is an absolute logical
    level.
16. **Scalars: Resolved.** Measurements are finite JSON numbers with explicit
    unit-bearing field names and no default quantization.
17. **Finalization: Resolved.** Owned live resources stop, scheduled delivery
    quiesces, and escaped handles freeze without live fallback.

## Accepted answer

Diorama's initial location system provides portable stable values and async
replay on all supported platforms, plus an Apple-only main-actor facade that
bridges a deliberately limited subset of `CLLocationManagerDelegate`. It does
not subclass or transparently imitate the complete native manager.

Named attachments record sequential open update sessions containing timed
batches and nonterminal NSError-derived failures. Location values preserve
floor, both altitude systems, accuracy, movement, timestamps, and source flags.
Coordinates use an attachment origin with east/north offsets; measurement and
delivery time remain independent.

Availability, permission, and accuracy form a stateful access lifecycle whose
reads do not consume records. Normal API authorization requests act as ordered
barriers, while externally initiated transitions schedule automatically.

Coordinate and measurement-time origins alone retain authored overrides.
Explicit overrides beat re-evaluated setup defaults, allowing raw origins to be
relocated or retimed before persistence. Other location behavior is replaced
wholesale on re-record. Replay mismatches diagnose and remain offline;
finalization stops owned live resources and leaves escaped handles inert.
