# 003-G09: Location shutdown and Apple acceptance

- Status: Complete; the owner authorizes PR creation on 2026-11-02.
- Authority: The owner confirms the outlined G09 scope on 2026-11-02.
- Branch: `feat/003-g09-location-acceptance`.
- Review base: `master` at merged G08 commit `80828ee` (PR #115).
- Plan: [G09](../plans/003-clean-slate-implementation.md#003-g09--location-shutdown-and-cross-platform-acceptance).
- Contracts: DD10, DD14, and DD16 with their accepted amendments; G08's explicit
  shutdown policy applies to passthrough as well as record/replay.

## Acceptance and capability evidence

This unit adds acceptance tests and a persisted native-capture fixture. The
existing production cleanup paths satisfy these checks without modification.

| Contract | Evidence |
| --- | --- |
| Record/passthrough shutdown | New parameterized bridge test finishes with an active batch session and an authorization request, both with and without an earlier consumer stop. Concurrent and canceled finish waiters return the same report. The native driver is detached, stopped, and released even while the facade and bridge remain retained. |
| Late events and escaped facades | Retained bridge callbacks for locations, errors, and access cannot deliver after finish. Retained location and configuration stay frozen; start, request, and setter calls cannot restart observation. |
| Independent native managers | Two separately keyed attachments capture distinct batches. Stopping one does not stop or contaminate the other's recording; finish closes both. |
| Claimed and executing replay delivery | Existing `LocationUpdateReplayTests` and `LocationAccessReplayTests` cover pending deadlines, claimed-but-not-entered callbacks, callbacks executing during finish, canceled/concurrent finish, frozen progress, access barriers, and no post-finish delivery. |
| Real Apple integration | New tests construct the production `CoreLocationDriver` and its real `CLLocationManager`, sample native access, configure it, connect the delegate, and exercise stop/detach. Controlled delegate entry verifies authorization forwarding and late-event suppression. Native authorization notifications may also arrive before finish; assertions deliberately permit them. |
| Persisted Apple capture | `Fixtures/native-recorded.json` is captured on macOS through G08's record bridge using synthetic `CLLocation` inputs and a controlled driver. The new replay test decodes it, checks canonical encoding, and delivers its populated batch, empty batch, error, and request-gated authorization through the production facade with all four fidelity options. Replay constructs no native driver. |
| Re-recording | Existing native bridge origin tests and `LocationOriginPublicationTests` cover fresh/default/baseline isolation, keyed origins, shorter replacement, override retention, publication, and replay of the replacement. |
| Fidelity and secure archives | Existing `LocationNativeMaterializerTests` exercise the opt-in subclass, floor/ellipsoidal fields, copying, concurrent access, native secure unarchiving, and retained archive-loss diagnostics. These tests are part of the Apple Location suite. |
| Linux boundary | `Package.swift` conditions the Location product and test target on Core Location availability. Applicable non-Location products remain covered by the required Linux CI job. |

The fixture's measurements, coordinates, error domain, and access changes are
synthetic, not device location observations. Its timestamp origins are the
macOS capture time; negative signed latencies retain the deliberately future
measurement timestamp. It is committed once and replayed unchanged on Apple
platforms. It does not require runtime fixture regeneration or wall-clock
matching. Supplemental-field fidelity is proved by the dedicated materializer
and native supplemental capture tests, not by claiming the fixture contains a
native floor observation.

## Verification

Local environment: Xcode 27.2 (`27B52`), Apple Swift 6.4.2
(`swiftlang-6.4.2.1.9`), arm64 macOS 27.2 (`26B123`).

- `swift test --filter DioramaLocationTests`: all 114 Location tests pass.
- `scripts/check`: passes pinned formatting, strict lint, all 607 host tests,
  public authoring/lifecycle compiler probes, warning-as-error Debug/Release
  builds, and compiled/executable examples.
- `scripts/coverage swiftpm macos`: passes and exports fresh
  `.build/coverage/macos.lcov`.
- Focused iOS 27.2 Simulator run: all 114 Location tests pass on iPhone 17,
  including the persisted macOS capture and secure-archive tests. Command:

  ```sh
  xcodebuild test -scheme Diorama-Package \
    -destination 'platform=iOS Simulator,name=iPhone 17,OS=27.2' \
    IPHONEOS_DEPLOYMENT_TARGET=18.0 SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
    -derivedDataPath .build/g09-ios -only-testing:DioramaLocationTests
  ```

The initial verification found test-only lint violations and a weak-variable
mutability warning. These are corrected without suppressions. The initial
native-driver assertion also incorrectly assumed no native authorization callback
could arrive during awaited finish; the corrected assertion snapshots the count
after finish and verifies silence from that boundary.

## Limits

The real-driver checks establish native construction, property access,
configuration, and cleanup, together with controlled delegate routing. They do
not request permission, start GPS, or establish sensor accuracy, permission UI,
background delivery, or entitlement behavior. Applications continue to own
usage descriptions and entitlements. No unsupported Core Location service or
synthetic completion is introduced.

Local `scripts/coverage ios` cannot select its configured iPhone 17 / iOS 27.0
destination: this machine has iOS 27.2, and its iOS 27.0 runtime is unavailable.
The installed 27.2 runtime is used for a separate focused Location test run.
Docker has no daemon at `/var/run/docker.sock`, so no local Linux result is
claimed. Required PR checks must establish the canonical platform and coverage
matrix before merge.
