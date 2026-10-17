# 003-G03A — Location-owned incremental capture

- Date: 2026-10-17
- Status: Complete. The owner approves fixup squashing and PR creation against
  master on 2026-10-18 after G03 merges. Full local macOS and iOS gates pass.
- Scope/model: The owner confirms G03A, GPT-6.1 Sol at `high` reasoning, and
  separate stacked development above G03 on 2026-10-17. No dependency is added.

## Result

`LocationCaptureState` builds Location's existing strict session and access
records through Core's `SystemOperation.beginRecord` boundary. Core's protected
mode state owns the mutable drafts. Each session start reserves one Core
record; an active start is idempotent. Stop closes new observation admission
without inventing a dependency completion. Restart reserves a new session and
delivery anchor. Empty sessions and empty callback batches remain distinct.

At each callback boundary, a protected reservation captures monotonic logical
time and appends a pending slot before conversion starts. Prepared callbacks
can complete those slots in any order. Each session starts with an explicit
normalized `TimestampOrigin`. Observation tokens carry that origin and their
reserved cumulative delivery offset, allowing preparation to derive signed
per-location latency before consumer materialization. Freeze traverses
reservation order and retains prepared locations, batch boundaries, and
nonterminal failures without changing their values or latencies.
Delivery instants round to integral milliseconds, with exact halves rounded
up, before subtraction; this avoids accumulating per-interval rounding error.
The first measurement does not redefine the session-start origin. Duplicate,
older, and future measurement times do not affect delivery timing.

An initial access segment owns notifications before the first authorization
request. Each request reserves another Core record and supplies the next
delivery anchor. A request before observation establishes an empty initial
segment first. Notifications already reserved before a barrier retain their
original segment even if their preparation finishes afterward. Duplicate
notifications and requests are retained in order.

Completion accepts only `PreparedValue` content. Locations already contain
normalized origin-relative measurements and signed latency against the reserved
delivery timeline. Independently round measurement instants before deriving
latency, rejecting unrepresentable dates and subtraction overflow. This
unit derives no horizontal or vertical origin and selects no privacy policy;
G06 owns origin preparation and replacement. Initial access state and the
optional initial location snapshot remain track-header inputs, established by
later attachment setup.
Freeze constructs the strict records without rerunning capture transformations.
Incomplete preparation, duplicate completion, a foreign execution's token, or
unusable timing blocks a healthy candidate. Captured values and arbitrary
underlying errors do not enter failure diagnostics.

Core freezes each registered draft once after cleanup, removing it from mode
state before constructing the immutable record. A stopped session can finish
an already reserved conversion before this boundary. A pending conversion at
freeze produces no complete record. Later completion cannot reenter detached
state or alter the immutable final report. Escaped observation tokens retain
only a lightweight execution-local identity, a record identity, an index, and
the session's scalar timing context. They retain no execution, time service,
lease, native object, or callback.

## Verification

The focused `LocationCaptureTests` suite covers controlled callback completion
out of order, interleaved access, signed latency and duplicate measurement times,
failure then recovery, start/stop/restart, empty/open sessions, request barriers,
duplicate notifications, prepared-only completion, preparation failure,
duplicate/foreign tokens, concurrent reservations, exact millisecond rounding,
time failure, repeat finalization, and runtime reference release. A blocked
conversion explicitly races freeze; the test joins its late completion and
checks that the final report remains unchanged.

### Rebase onto reviewed G03

The owner requests rebasing G03a onto G03's reviewed schema and shared
timestamp foundation. The branch builds directly on merged G03 commit
`c8279d6`. The owner approves squashing the adaptation fixup, leaving separate
capture and evidence commits. Capture uses explicit session-start origins, prepared
`LocationRecordedLocation` batches, and `initial`/`degrees` header names. No G03
or master history is rewritten, and no new dependency or schema is introduced.

- `swift test -Xswiftc -warnings-as-errors --filter 'LocationCaptureTests|LocationCodecTests'`
  passes 34 tests: 17 capture tests (19 cases) and all 17 codec tests. Added
  coverage proves normalized preparation, signed latency, a session-start
  reference independent of its first measurement, late completion, persistence
  round trips, invalid dates, and latency subtraction overflow.
- Changed-file SwiftFormat and strict SwiftLint pass.

### Final PR verification

- `scripts/verify-apple-toolchain` verifies Xcode 27.0 (`27A266a`) and Apple
  Swift 6.4 (`swiftlang-6.4.0.34.1`, `clang-2100.3.34.1`).
- `scripts/lint` passes repository-wide SwiftFormat and strict SwiftLint.
- `scripts/coverage swiftpm macos` passes all 528 host tests, coverage fixture
  checks, public system-authoring and state-lifecycle compiler probes, strict
  Release builds, and examples. It exports `.build/coverage/macos.lcov`.
- `scripts/coverage ios` passes the Release build, all 527 Simulator tests,
  compiler probes, and LCOV export on iPhone 17 / iOS 27.0. It exports
  `.build/coverage/ios.lcov`. Both Apple runs include all 17 capture tests.
- Each Apple coverage report covers 113/119 executable lines (94.96%) in
  `LocationCaptureState.swift` and 77/78 (98.72%) in `LocationCaptureDrafts.swift`.
- Required PR checks are Quality, macOS, iOS, and Linux, with Codecov uploads
  from the platform coverage jobs. The hosted Linux gate verifies the pinned
  toolchain, applicable tests, compiler probes, Release builds, and examples
  without importing Location. Linux verification for this final revision uses
  that hosted gate.

## Boundary

This is an internal domain-capture capability. It introduces no consumer
Location API, native manager, replay delivery, origin override merge, generic
subscription helper, or schema change. The controlled test definition supplies
prepared headers and leases through the production `SystemDefinition` API.
Native callback lifetime and manager ownership remain G08/G09 evidence; these
tests do not establish live Core Location behavior or iOS 18 device behavior.
