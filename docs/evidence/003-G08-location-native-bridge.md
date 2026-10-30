# 003-G08: Private Core Location capture and live forwarding

- Status: Complete; owner review and fixup squashing are approved, and stacked
  PR creation is authorized on 2026-11-02.
- Authority: Owner confirms commencement of the outlined G08 scope, stacked above G07,
  with GPT-6.1 Sol at `high` reasoning on 2026-10-31.
- Review base: `feat/003-g07a-location-request-tracking` at `9fe5bbc`, above merged G07.
- Branch: `feat/003-g08-location-native-bridge`.
- Plan: [G08](../plans/003-clean-slate-implementation.md#003-g08--private-core-location-capture-and-live-forwarding).
- Contracts: DD06, DD09, DD16, DD20, and DD21, including their accepted amendments.

## Behavior and ownership

`DioramaLocationSystem.instance` exposes the first-party attachment and persistence
capability. Each record or passthrough activation constructs its own private
MainActor `CLLocationManager`, delegate proxy, and facade. Replay constructs only
the existing replay engines. Native construction follows fallible lease lookup;
the dependency factory starts no standard updates or authorization requests.
Conversion failures are contained as recording-health failures. There is no
fallible construction step after delegate connection that can abandon an active
native manager. Once the dependency returns, Core owns rollback and finish.

A narrow internal driver protocol permits controlled native observations without
mutating an application's manager. The facade dispatches through one internal
mode boundary; each backend retains its concrete typed execution and state.
Native calls and consumer callbacks run outside Core's state lock. Record-mode
commands and callbacks use tracked state-member scopes, with quiet callback
admission before publication and after closure. No callback launches a task.

Core's stop hook detaches the native delegate, stops updates, clears delivery
closures, and releases the owned driver and capture-local origins. It is
idempotent and tolerates an earlier consumer stop. All native bridge work is
synchronous on MainActor, so there is no separate async cleanup task to join.
Record/replay and passthrough all leave escaped facades frozen and inert after
finish. Retained native locations and configuration remain readable; start,
authorization requests, and setters diagnose closed use, while stop is a no-op.
Passthrough does not continue native observation after execution finish.

## Capture and normalization

Initial cached location and access state are sampled during construction.
The initial empty access prefix is reserved at logical zero, since execution
time starts after activation. First delegate registration or the first request
anchors an unused initial segment to tracking time. Before tracking, record-mode
access properties retain the captured initial state. Authorization requests
reserve independent segments before calling the native manager; synchronous
native notifications therefore belong to the request segment even without a
delegate. Once tracking starts, native notifications update recorded current
state regardless of delegate presence. Later registration does not reset timing
or repeat notifications. Passthrough always reflects native access changes.
Sessions are idempotent while active and
restart with fresh wall and logical anchors. Stopped callbacks are ignored.

Callbacks reserve ordering and logical delivery time before extraction. Only
prepared stable locations, error snapshots, and access states enter Core tracks.
The shared materializer builds normalized native locations from fresh prepared
origins, offsets, and signed latency. Current location installs before delegate
delivery; empty batches preserve it. Failure callbacks are nonterminal.

`LocationRecordingOptions` selects regional meter offsets or global degree
offsets and validates optional coordinate, independent altitude, and timestamp
origin defaults. Setup defaults affect fresh normalized consumer delivery;
baseline authored origins are consulted only by G06's finalization merge.
Capture-local raw origins are not placed in tracks, diagnostics, or resources.

`LocationFidelityOptions` controls native reconstruction equally in record and
replay. Capture retains floor and ellipsoidal altitude regardless of these
options. Passthrough never converts: original locations and errors retain their
object identity, including opaque user information. Its consumer operations do
not pass through Core track operations or recording preparation.

Supported error user-info values use Core's bounded snapshot. Each omitted entry
emits a non-invalidating `nativeErrorMetadataOmitted` fact containing only its key
and runtime type. Report rendering escapes those fields. This narrow diagnostic
case fulfills DD06/DD16's omission contract; no general metadata bag or native
value description is added. Other conversion failures preserve live delivery,
report safe infrastructure facts, and prevent healthy publication.

## Native capability boundary

The Apple product retains the iOS 18 and macOS 15 deployment floors.

| Surface | Initial support |
| --- | --- |
| Location | Coordinates, horizontal accuracy, positive-accuracy orthometric/ellipsoidal heights, floor, valid speed/course and uncertainties, measurement timestamp, optional source flags |
| Access | Service availability, known native authorization and accuracy values, when-in-use/always request barriers; existing macOS presentation rules remain |
| Configuration | desiredAccuracy, distanceFilter, activityType, pausesLocationUpdatesAutomatically; forwarded live, local in replay, never persisted or matched |
| Errors | Domain/code and bounded supported user information; reconstructed in record/replay and original in passthrough |
| Excluded | Heading, region, significant-change, background/deferred, one-shot services, consumer-manager mutation, Linux live access |

Native negative sentinels remain absence under the existing measurement rules.
Floor and ellipsoidal-height native fidelity require the existing opt-in subclass;
secure-archive limitations and diagnostics remain unchanged. Applications own
usage descriptions, entitlements, and permission presentation.

## Verification and limits

Verification uses Xcode 27.0 (27A266a) and Apple Swift 6.4
(swiftlang-6.4.0.34.1), targeting arm64 macOS.

`scripts/check` passes pinned non-mutating formatting, strict lint, all 590 host
tests, public authoring and lifecycle compiler probes, warning-as-error Debug and
Release builds, and the compiled examples and executable examples. The bridge
suite covers initial/current state, normalized batches/errors, state before
callbacks, independent supplemental-field capture, all four fidelity combinations,
record/replay downstream scalar equivalence, source isolation, fresh default vs.
baseline override precedence, absence of raw coordinates from publication,
conversion failure, passthrough identity and unchanged tracks, counted manager
operations, stop/restart, empty recordings, and rollback in record/passthrough.

`scripts/coverage swiftpm macos` passes the fresh host coverage workflow and
exports `.build/coverage/macos.lcov`. Coverage does not establish real GPS or
native authorization behavior: native callback tests use the controlled driver.
The thin production Core Location driver is compiler-verified; actual Apple
integration and broader shutdown conformance remain G09 evidence obligations.

`scripts/coverage ios` aborts with exit 134 during its first `xcodebuild build`,
before a build result or runtime tests. Output reports failure to start a file
event stream and `DARWIN_USER_CACHE_DIR` I/O failure. Direct library
cross-compilation passes at the iOS 18 floor:

```sh
swift build --build-system native --triple arm64-apple-ios18.0-simulator \
  --sdk /Applications/Xcode-27.0.0.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator27.0.sdk \
  --scratch-path .build/g08-ios-cross -Xswiftc -warnings-as-errors
```

SwiftPM emits its native-build-system CLI deprecation notice; compiler warnings
remain errors. This proves library compilation, not iOS test compilation or
runtime execution. Docker is installed but no daemon is available at
`/var/run/docker.sock`; no local Linux test result is claimed. Required PR CI
must establish the complete platform matrix before integration.

## G07 dependency restack — 2026-11-01

The existing G08 commits are restacked above the reviewed and squashed G07
branch at `bb2b0cd` (PR #113). The production replay State factory now supplies
only its two track leases; engine initialization reads their headers through
the Core accessor introduced by G07. This is the only production adaptation
in the restack and introduces no new live behavior.

The focused native-bridge, manager, and replay-header suites pass all 18 tests.
`scripts/check` passes pinned formatting, strict lint, all 596 host tests,
public compiler probes, warning-as-error builds, and release examples.
Verification uses local Xcode 27.2 / Apple Swift 6.4.2 on macOS 27.2 (`26B123`).
No new iOS, Linux, or coverage result is claimed. The owner approves squashing
the constructor and evidence fixups on 2026-11-01; G08 remains under review.

## Authorization tracking review update — 2026-11-01

The owner approves [G07A](003-G07A-location-request-tracking.md) as a separate
replay/contract prerequisite rather than requiring clients to register a delegate
before requesting authorization. G08 is restacked above its preparatory commit.
The native fixup separates tracking from callback registration and starts tracking
before forwarding a request. Pre-tracking record-mode callbacks leave all three
access properties at their captured initial values, keeping healthy empty
recordings reproducible. Passthrough retains native updates and request forwarding.

The focused native/access/facade suites pass all 35 tests. Controlled-clock tests
record and replay both authorization request kinds before delegate registration,
including a synchronous native response, complete state before registration,
later registration without redelivery or deadline changes, exact request claims
and consumption, and zero native driver construction in replay. A separate probe
proves pre-tracking recorded state equals replay; passthrough probes preserve
native access changes before any registration or request.

`scripts/check` passes pinned formatting, strict lint, all 603 host tests, both
public compiler-probe suites, warning-as-error Debug/Release builds, and release
examples on local Xcode 27.2 (`27B52`) / Apple Swift 6.4.2 / macOS 27.2 (`26B123`).
No new iOS, Linux, or coverage result is claimed for this review fixup. The full
required platform matrix remains a PR gate. The owner approves squashing the
native feature and evidence fixups on 2026-11-02. Both are folded into their
respective targets; the source and test trees are unchanged by the rewrite.

## Review boundaries

The preparatory commit separates facade mode operations while preserving replay
behavior. The feature commit adds owned live capture/forwarding, public setup
options, typed omission diagnostics, and their controlled tests. The documentation
commit records this evidence, application setup guidance, and owning plan status.

No dependency, persisted schema change, unsafe isolation annotation, new Core
lifecycle abstraction, or additional Core Location service is introduced. The
owner completes review, approves fixup squashing, and authorizes pushing G08 and
creating its stacked PR on 2026-11-02. Its base is G07A's branch while
[PR #114](https://github.com/SwiftScream/diorama/pull/114) remains open. Required
PR checks enforce the complete platform and coverage matrix. Merge and G09 each
require separate explicit authorization.
