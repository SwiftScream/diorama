# 003-G07: Main-actor Location manager and delegate

- Status: Complete; owner review and fixup squashing are approved, and PR creation is authorized on 2026-11-01.
- Authority: Owner confirms the G07 scope, authorizes implementation atop G06, and approves PR creation after review.
- Review base: `master` at `e840723`, including merged G06.
- Branch: `feat/003-g07-location-manager`.
- Plan: [G07](../plans/003-clean-slate-implementation.md#003-g07--main-actor-managerdelegate-facade-over-location-replay).
- Contract: [DD16](../design-decisions/16-location-system.md), including the
  delegate-first and normalized native delivery amendments, and
  [DD21](../design-decisions/21-managed-native-lifecycle.md).

## Behavior

`DioramaLocationManager` and its class-bound delegate protocol are public and
MainActor-isolated. The manager holds its delegate weakly; callback methods have
no-op defaults so consumers can implement only the notifications they need.
Update batches deliver native `CLLocation` values through the existing shared
materializer and attachment-wide fidelity options. Failure callbacks receive
reconstructed native errors and do not terminate updates.

The update and access engines share one strict `LocationReplayState` containing
only their two typed track leases. Each reads its validated header during
initialization through `SystemOperation.replayHeader(on:)`, supplied by the
[preparatory Core commit](003-G07-replay-header-read.md). Access initializes its
current state from that header; updates retain their header snapshot in the
actor-bound runtime for location materialization until close. Each engine keeps
its independent claim and delivery state machine and the same attachment's Core
lifetime. No generic projection, type erasure, or async sequence is introduced.

Initial and current location, authorization, accuracy authorization, and service
availability reads do not claim records. Complete state installs before delegate
callbacks. The first non-nil delegate registration begins access observation;
replacement routes subsequent notifications to the latest delegate without
restarting the timeline. Setting the delegate to nil suppresses callback delivery
without stopping state progression. Empty update batches retain the last location.

The supported operations are standard update start/stop and the when-in-use/always
authorization requests. The four local configuration properties use native Apple
types, with defaults of best accuracy, no distance filter, other activity, and
automatic pausing enabled. Configuration is not persisted or matched. No live
manager is constructed or contacted in replay.

Core's selected mode stop hook closes both engines on MainActor before scheduler
drainage. This releases pending delivery and runtime ownership; current native
values and local configuration remain readable. After admission closes, configuration
setters diagnose lifecycle misuse and leave their values frozen. Start and requests
retain closed-use diagnostics; stop is a no-op. Delegate replacement after finish
cannot schedule or deliver a callback. Callback closures capture the manager weakly.

G07 exposes the facade and its controlled replay construction, not a public live
attachment factory. G08 owns native construction, forwarding, and the first-party
live setup integration. The manager initializer remains internal. The compiled
[application migration](../../Examples/Sources/LocationMigration/LocationConsumer.swift)
uses ordinary imports and accepts an injected public manager. Its Apple-only
example target uses Swift 6 and the package's explicit concurrency settings;
Linux retains its existing example targets.

## Tests and verification

The facade suite exercises all four fidelity combinations, current-location
identity inside callbacks, native error reconstruction, weak delegate release,
configuration freeze, initial access reads, complete notified native state,
authorization barrier dispatch, delegate replacement before pending delivery,
finish suppressing pending updates, and post-finish inert calls and replacement.
Controlled time supplies ordering; no elapsed-time sleeps prove these invariants.
Existing update/access suites continue covering reentrant callbacks, cancellation,
claim progress, barriers, and admitted callback drainage with the shared State.

Initial implementation verification: `scripts/check` passes pinned formatting,
strict lint, all 582 host tests, both
public compiler-probe suites, warning-as-error Debug/Release compilation, and
the example build and executions. The example build includes the new Apple
migration target. `scripts/coverage swiftpm macos` independently passes all
582 tests and subordinate gates and exports fresh LCOV. The manager covers 68
of 71 executable lines (95.77%); the three uncovered lines are the delegate's
optional no-op default callbacks.

Direct iOS library cross-compilation passes with:

```sh
swift build --build-system native --triple arm64-apple-ios18.0-simulator \
  --sdk /Applications/Xcode-27.0.0.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator27.0.sdk \
  --scratch-path .build/g07-ios-cross -Xswiftc -warnings-as-errors
```

The selected Xcode 27.0 / Swift 6.4 SDK compiles all library targets, including
the manager, at the iOS 18 deployment floor. SwiftPM emits its CLI deprecation
notice for the native build system; compiler warnings remain errors. This fallback
follows an `xcodebuild build-for-testing` exit of 134 before a build result,
with file-event-stream and Darwin user-cache I/O diagnostics. It does not establish
iOS test compilation or runtime execution. No local Linux test result is claimed
for G07. The Apple-only Location target
and migration target remain excluded from the Linux package graphs. Required PR
CI checks the complete macOS, iOS, Linux, and Codecov matrix before integration.

## Header-read review update — 2026-11-01

The owner requests removing the separately supplied headers from shared replay
State now that Core exposes typed replay-header reads. Update/access definitions
and the facade fixture now construct State using only their two leases. Engines
obtain the authoritative header through managed initialization without consuming
records or changing replay delivery and shutdown behavior.

The focused Location update, access, manager, and Core replay-header suites pass
all 40 tests. `scripts/check` also passes pinned formatting, strict lint, all
588 host tests, compiler probes, warning-as-error builds, and release examples.
Verification uses the locally selected Xcode 27.2 / Apple Swift
6.4.2 on macOS 27.2 (`26B123`); it does not establish verification with the branch's
older pinned Xcode 27.0 / Swift 6.4 toolchain. No new iOS, Linux, or coverage
result is claimed for this review update.

## Review boundaries

The owner approves squashing the review fixups and authorizes PR creation on
2026-11-01. The final branch contains five atomic commits:

1. Disable the file-length lint rule and update its policy.
2. Add Core's typed replay-header reads, proving tests, and contract documentation.
3. Share Location's two replay leases and obtain headers through managed reads.
4. Add the public manager/delegate facade, facade tests, and compiled migration example.
5. Record the completed unit, review verification, and documentation indexes.

G06 is merged through PR #112; this branch targets `master` directly. Merge
requires passing required CI and a separate explicit owner request. G08 retains
its separate owner checkpoint. No native recording or passthrough,
CLLocationManager subclass, public async interface, persistence schema change,
third-party dependency, or unsafe concurrency annotation is added by this unit.
