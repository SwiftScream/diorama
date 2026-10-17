# 003-G03B — Native CLLocation materialization

- Date: 2026-10-18
- Status: Complete. Local macOS and iOS gates pass; required PR checks verify
  the applicable Linux package boundary and platform coverage uploads.
- Scope/model: The owner authorizes this separate native-materialization slice,
  GPT-6.1 Sol at `high` reasoning, a PR stacked on the delegate-first documentation
  PR, and subsequent G04 implementation. No dependency or schema changes.

## Result

`LocationNativeMaterializer` converts G03's already normalized
`LocationMeasurement` into a native `CLLocation`. It neither selects origins nor
rounds values again. Coordinate, timestamp, orthometric altitude, accuracy,
speed, course, and explicit source flags use public native constructors. Missing
vertical measurements use altitude zero and accuracy -1; missing speed/course
and their accuracy use -1. Absent source information follows the ordinary native
initializer: the tested runtime supplies two false flags rather than nil. The
stable recording continues distinguishing absence from explicit false flags.

Public immutable `LocationFidelityOptions` supplies independent, default-off
floor and ellipsoidal-altitude preservation settings. Both off returns an
ordinary native location. Ellipsoidal preservation selects the subclass for
every location; floor preservation alone selects it only for a present floor.
The subclass overrides only the supplemental getters and coding/copy behavior.
Disabled fields keep the ordinary native reconstruction's values. Floor remains
independent of vertical accuracy. Record and replay will use the same options;
passthrough remains native and capture always retains both fields.

The final CLLocation and CLFloor subclasses are immutable. Their NSCopying
implementations return self, retaining enabled values without introducing
mutable sharing. Native distance works with either receiver direction. Secure
keyed archiving advertises CLLocation as the coding class and uses native
encoding; decoding yields an ordinary CLLocation with native supplemental
fields. Each subclass encoding records `location.archiveFidelityLoss` with safe
identity context and no recording-health impact. Ordinary native encoding adds
no loss fact. Repeated archives produce separate facts; a fact after reporter
freeze enters only the post-finish log.

## Sendability justification

Both SDK classes inherit unchecked Sendable. Swift requires their final
subclasses to restate that conformance. Every added field is immutable: scalars,
CLFloor, the synchronized Sendable DiagnosticReporter, and safe DiagnosticContext.
No executor-dependent state, native manager, arbitrary callback, or execution is
retained. Getter/copy/encode methods do not mutate subclass fields; concurrent
reporting is serialized by the existing reporter. Concurrent read/copy/archive
and escaped-value ownership tests exercise this invariant. This is a narrow
inherited-conformance justification, not a general unsafe-isolation exception.

## Verification

- Focused `swift test -Xswiftc -warnings-as-errors --filter
  LocationNativeMaterializerTests` passes seven tests, including sixteen
  field/selection combinations and eight archive combinations. Cases cover both
  options, nil/present floors, valid/absent vertical values, source behavior,
  canonical sentinels, timestamps, native distance, copying and secure coding.
- Twenty-four concurrent copy/archive operations retain every loss fact, preserve
  supplemental values, and leave recording health unchanged. A subsequent
  archive preserves the frozen report and adds exactly one post-finish fact.
- An escaped native value survives actual execution finalization without retaining
  the execution, and continues routing safe post-finish archive diagnostics.

### Final revision gates

- `scripts/verify-apple-toolchain` verifies Xcode 27.0 (`27A266a`) and Apple
  Swift 6.4 (`swiftlang-6.4.0.34.1`, `clang-2100.3.34.1`).
- `scripts/lint` passes repository-wide SwiftFormat and strict SwiftLint.
- `scripts/coverage swiftpm macos` passes all 535 host tests, coverage fixture
  checks, public authoring/lifecycle compiler probes, strict Release builds,
  and examples. It exports `.build/coverage/macos.lcov`.
- `scripts/coverage ios` passes the Release build, all 534 iPhone 17 / iOS 27.0
  Simulator tests, lifecycle compiler probes, and `.build/coverage/ios.lcov`.
- Both Apple reports cover 100/106 executable materializer lines (94.34%) and
  all four executable fidelity-option lines. Required coder initializers reject
  subclass decoding; ordinary secure decoding uses the advertised native class.
- Required PR checks are Quality, macOS, iOS, and Linux with platform Codecov
  uploads. The Linux job verifies applicable products without importing Location;
  no local Linux run is claimed for this Apple-only implementation.
- `git diff docs/location-delegate-first --check`, local documentation links,
  and the complete branch diff against its documentation base pass review.

## Boundary

This unit provides native value construction only. It adds no async sequence,
manager/delegate facade, live manager, session replay, scheduling, origin merge,
or public attachment constructor. G04 uses the materializer for callback-based
replay; G07/G08 provide the consumer facade and live bridge. The approved
subclasses follow DD16's explicit opt-in policy; these checks establish the
listed native operations, not compatibility with every Apple framework or an
iOS 18 device runtime.
