# 003-D05: Native quiescence and lifetime checkpoint

- Date: 2026-09-26.
- Owning unit: [003-D05](../plans/003-clean-slate-implementation.md#003-d05--native-quiescence-and-consolidated-feasibility-gate).
- Approved scope/model: GPT-6 Astra, `xhigh`; the owner directs commencement
  and a combined Phase D review and merge unit.
- Base: D04 commit `7dd4b3e`.
- Status: In progress; the owner resolves the initial lifetime checkpoint by
  approving native session invalidation. Remaining D05 experiments continue.
- No production code or dependency changes; DD12/DD17 record the approved
  amendment, reconciled with DD10 and the design overview.

## First finding: invalidation conflicts with escaped-session failure

[DD12](../design-decisions/12-urlsession-scope.md#session-construction-and-ownership)
selects an adapter-created native `URLSession` and lifecycle-appropriate
invalidation. [DD17](../design-decisions/17-http-lifecycle-composition.md#open-interactions-and-finalization)
also promises that a later request on an escaped session returns a deterministic
infrastructure failure without contacting the live dependency.

The ordinary native session cannot provide that combination through the tested
invalidation/interception approach:

1. Create an ephemeral session with an inert custom protocol. Its only behavior
   is returning `NSError(domain: "D05ExpiredLease", code: 1)`.
2. Call `finishTasksAndInvalidate()` and await the delegate's explicit
   invalidation notification.
3. Call ordinary async `data(from:)` on the retained session.
4. On macOS, task creation raises an uncaught `NSGenericException` with reason
   `Task created in a session that has been invalidated`. It does not throw a
   Swift `Error` into the request's `catch` block or reach the custom protocol.

The stable Linux process terminates with signal 4 and
`FoundationNetworking/URLSession.swift:575: Fatal error: Session invalidated`.
The inspected release source guards data-task construction with
[`fatalError("Session invalidated")`](https://github.com/swiftlang/swift-corelibs-foundation/blob/d29d01ba165f6957141e07ea7fe8144ab491bc24/Sources/FoundationNetworking/URLSession/URLSession.swift#L573-L583).
This is outside Diorama's `URLProtocol` interception boundary. A routing lookup,
error response, or delegate proxy in that boundary cannot recover task creation.

Apple documents that [new tasks cannot be created after invalidation](https://developer.apple.com/documentation/foundation/urlsession/finishtasksandinvalidate()).
Treating this as a newly discovered Linux defect would misclassify the result:
the tested Apple native API also rejects this use before interception. Existing
FN repair priorities remain unchanged.

### Leaving the session uninvalidated does not establish cleanup on Apple

The companion test performs one inert request, lets it fail normally, releases
the application's strong session reference, and keeps only a synchronized weak
reference. The delegate owns a count, with no reference to the session. There
is no session registry, execution object, or outstanding fixture delivery.

In the initial macOS probe the weak reference stays non-nil for the entire
30-second observation. Invalidating the retained native session then allows
release. This bounded observation is not a proof about infinite retention;
it agrees with Apple's documented requirement to
[invalidate sessions to avoid leaking memory](https://developer.apple.com/documentation/foundation/urlsession/delegatequeue).
The final safe control checks the observed native retention and then performs
cleanup, instead of leaving a deliberately retained session in the test run.

Stable Linux releases the otherwise unowned session in this control even
without invalidation. That difference does not establish a cross-platform
solution, and the probe does not cover active tasks or live forwarding tails.

The D01 expired-route test remains valid: a session that has **not** been
invalidated can reject through its custom protocol. D05 exposes the additional
lifetime question when that same raw session must be cleaned up.

## Owner decision — 2026-09-26

The owner directs: invalidate the session and document that it is not usable
beyond scenario execution; using it to create new tasks afterward crashes.
The [DD12](../design-decisions/12-urlsession-scope.md#session-invalidation-amendment--2026-09-26)
and [DD17](../design-decisions/17-http-lifecycle-composition.md#session-invalidation-amendment--2026-09-26)
amendments retain the ordinary URLSession surface and replace the recoverable
escaped-session failure promise. DD10 reconciles the narrower reporting boundary.

No facade is introduced. Do not keep native sessions open solely to diagnose
misuse. Stop and drain replay delivery, remove routing, and let existing live
tasks finish with detached forwarding. Neither the decision nor the lifetime
controls prove the remaining native quiescence and forwarding requirements.

## Executable probes and reproduction

[D05SessionLifetimeTests.swift](../../Spikes/URLSessionInterception/Tests/URLSessionInterceptionTests/D05SessionLifetimeTests.swift)
contains two safe lifetime cases and one deliberately unsafe, opt-in process
probe. No new unsafe sendability annotation is added. The weak reference and
delegate observation are protected by `Synchronization.Mutex`.

Safe controls:

```sh
swift test --package-path Spikes/URLSessionInterception \
  --scratch-path .build/urlsession-spike -Xswiftc -warnings-as-errors \
  --filter D05SessionLifetimeTests
```

Run the crashing experiment in its own process, never the ordinary matrix:

```sh
DIORAMA_D05_INVALIDATED_SESSION=1 \
  SWIFT_BACKTRACE=enable=yes,interactive=no,threads=crashed \
  swift test --package-path Spikes/URLSessionInterception \
  --scratch-path .build/urlsession-spike -Xswiftc -warnings-as-errors \
  --filter 'D05SessionLifetimeTests.*request'
```

The opt-in test retains the desired recoverable-error assertion. Termination
before that assertion is the finding, not successful conformance. The owner now accepts this native boundary. The unsafe probe remains opt-in
as historical evidence; its recoverable-error assertion records the rejected
promise. Safe lifetime controls remain mandatory. This does not mark D05 complete.

## Verification at this checkpoint

Targeted native probes only; the complete V-spike gate is not yet established.
The initial macOS desired-release experiment fails as described above. The
final safe controls assert the native behavior observed, not Diorama's unproved
post-finish contract.

| Platform | Safe controls | Invalidated-session experiment |
| --- | --- | --- |
| macOS 27.0, Xcode 27.0 `27A266a`, Apple Swift 6.4 `swiftlang-6.4.0.34.1` | Two cases pass; uninvalidated session retained until cleanup | Process terminates with signal 6 and `NSGenericException` |
| iOS 27.0, iPhone 17 simulator, deployment target iOS 18 | Two cases pass; uninvalidated session retained until cleanup | Xcode records `Test crashed with signal abrt.` for the selected request probe |
| Linux x86_64, `swift:6.4.0-noble` | Two cases pass; session releases without explicit invalidation | Process terminates with signal 4, `Fatal error: Session invalidated` |
| Linux x86_64, pinned Swift 6.4.2 development snapshot `d2e983b81b18217` | Two cases pass; session releases without explicit invalidation | Process terminates with signal 4, `Fatal error: Session invalidated` |

The Linux snapshot is
`swiftlang/swift@sha256:15ae709b1d8eb1f8691b300f5721499d007e944694f2c0e9929a55580c9bf1a5`.
Linux probes use Apple Container with `--arch x86_64 --cpus 2 --memory 4G`,
a read-only repository mount, and a writable copy of the isolated spike.
The iOS check uses `xcodebuild test` for `URLSessionInterception-Package`,
`-only-testing:URLSessionInterceptionTests/D05SessionLifetimeTests`,
`IPHONEOS_DEPLOYMENT_TARGET=18.0`, and `SWIFT_TREAT_WARNINGS_AS_ERRORS=YES`.
The separate crashing iOS run sets
`TEST_RUNNER_DIORAMA_D05_INVALIDATED_SESSION=1`; its two safe cases pass and
the request probe crashes. Its Xcode exit status is 65.

The safe controls skip the opt-in crash experiment on every platform. The
canonical `scripts/lint` gate passes with zero violations across 127 Swift
files. Local documentation file targets resolve and the checkpoint diff passes
`git diff --check`. No hosted CI or full Phase D rerun is claimed at this stop.

The Linux command runs safe controls before the separately selected crash:

```sh
container run --rm --arch x86_64 --cpus 2 --memory 4G \
  --mount type=bind,source="$PWD",target=/source,readonly --workdir /work \
  swift:6.4.0-noble bash -lc '
    cp -R /source/Spikes/URLSessionInterception /work/ &&
    swift test --package-path URLSessionInterception -Xswiftc -warnings-as-errors \
      --filter D05SessionLifetimeTests &&
    DIORAMA_D05_INVALIDATED_SESSION=1 \
      SWIFT_BACKTRACE=enable=yes,interactive=no,threads=crashed \
      swift test --package-path URLSessionInterception -Xswiftc -warnings-as-errors \
      --filter "D05SessionLifetimeTests.*request"'
```

The snapshot uses the same command with the image above. Local logs are retained
in `.build/d05-lifetime-controls-macos.log`, `.build/d05-invalidated-macos.log`,
`.build/d05-lifetime-ios.log`, `.build/d05-invalidated-ios.log`,
`.build/d05-invalidated-linux.log`, and
`.build/d05-invalidated-linux-snapshot.log`; the iOS runs retain corresponding
`.xcresult` bundles. The initial unsuccessful release experiment is preserved
separately in `.build/d05-lifetime-macos.log`.

## Remaining D05 work

- Pending and in-flight callbacks, including blocked consumer callbacks.
- Unanswered response, redirect, and authentication decisions.
- Admission closure and lease revalidation after asynchronous task lookup.
- Replay cancellation and explicit native callback drainage.
- Minimal live forwarding tails with no scenario retention or mutation.
- Repeated setup/cleanup and the FN-09 independent executor/FN-10 registry audit.
- Consolidation of all six DD12 spike questions, platform capability profiles,
  and confirmation or revision of the H/I production units.

Phase D remains one intended owner review/merge unit. This checkpoint does not
authorize a merge or establish the production feasibility gate.
