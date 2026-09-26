# 003-D05: Native quiescence and consolidated feasibility

- Dates: 2026-09-26–2026-09-27.
- Owning unit: [003-D05](../plans/003-clean-slate-implementation.md#003-d05--native-quiescence-and-consolidated-feasibility-gate).
- Approved scope/model: GPT-6 Astra, `xhigh`; the owner directs commencement
  and a combined Phase D review and merge unit.
- Base: D04 commit `7dd4b3e`.
- Status: Complete as an isolated investigation on 2026-09-27; ready for the
  combined Phase D owner review. Linux conformance remains conditional on the
  required upstream repairs. No production implementation is introduced.
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
tasks finish with detached forwarding. The experiments below separately establish the native quiescence and
forwarding feasibility evidence.

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
before that assertion is the finding, not successful conformance. The owner now accepts this native boundary. The unsafe probe remains
opt-in as historical evidence; its recoverable-error assertion records the rejected
promise. Safe lifetime controls remain mandatory.

## Initial checkpoint verification

This historical checkpoint runs targeted native probes only. The final gate
is recorded separately below.
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

## Replay quiescence

The executable fixtures establish these separate boundaries:

1. Close routing/admission and stop the synchronized protocol delivery wrapper.
   A late asynchronous ownership result must revalidate its lease. Expired,
   absent, ambiguous, or canceled ownership cannot start replay or live work.
2. Cancel owned replay tasks on an executor outside Foundation's work queue.
   Explicitly dispose outstanding native response/redirect/challenge answers
   once, with their runtime cancellation/refusal cleanup values. A retained
   consumer answer then owns only an inert box. These cleanup calls do not
   invent recorded decisions or terminal lifecycle nodes.
3. Call `finishTasksAndInvalidate()`, observe native invalidation, and drain
   the native delegate queue. Stopping `URLProtocol` delivery alone does not
   prove that callbacks already queued by Foundation have returned.
4. Assert that later controlled heads, bytes, terminal events, and consumer
   answers produce no further callbacks and no loopback connection.

The experiment initially relied on task cancellation alone with an unanswered
response decision. Apple did not acknowledge invalidation within the watchdog.
Explicitly disposing the pending native answer resolves that case. Both queued
callbacks (a suspended native delegate queue) and executing callbacks (a
controlled synchronous consumer block) must drain before quiescence returns.
The blocked-callback test records callback return before the quiescent event;
it does not count a timeout or an empty queue snapshot as proof.

A consumer callback that never returns can still prevent replay finish, as
DD14 specifies. Foundation invalidation also does not await arbitrary consumer
Swift `Task` scheduling after an async result; the tests await that producer
separately and make no broader application-task quiescence claim.

## Live horizon and forwarding ownership

The recording horizon atomically detaches the observation gate and removes
execution routing, then begins graceful invalidation of the returned session.
It does not cancel or await an unfinished consumer-owned live operation. The
weak scenario reference releases immediately at that boundary, while the
request still has no completion. Later data and decisions reach the consumer,
without adding any scenario observations. Record and passthrough controls cover
before-head, partial-body, and unanswered response phases; completion and both
async presentations also finish after the horizon.

On Apple, loopback HTTP controls additionally hold a redirect or Basic/Digest
challenge across the horizon. Redirect follow starts a replacement protocol
instance **after execution routing is gone**; refusal preserves the redirect
body. The native session delegate owns an admitted per-task continuation; the
replacement-instance lookup is weak and task-identity based. It admits no new
execution work. Terminal delivery removes that lookup and the delegate's
ownership. The continuation keeps weak task/owner backreferences and only a
detached observation gate, avoiding a task/protocol/continuation retain cycle.

Each private forwarding hop owns its pending native decision independently.
The first experiment canceled a superseded redirect transport or an unanswered
authentication transport without reliably releasing that decision. Its task
completed and invalidation was observed, but a weak private session remained
retained. Answering the private redirect with `nil`, or disposing its challenge
continuation, before cancellation resolves the release checks. Private decision
ownership must survive outer completion and must not be stolen by another hop.
This is fixture/adapter cleanup evidence, not a newly assigned Foundation bug.

Native task creation, cancellation, and invalidation use an independent serial
forwarding executor (FN-09). Cancellation before private creation starts no
transport; cancellation after creation reaches exactly that owned transport.
Successful live completion causes no explicit task cancellation. Outer and
private session weak references release after actual completion/invalidation.
Thirty repeated owned-session lifetimes release session, route lease, and
scenario; these bounded experiments are not a universal leak proof.

The spike's combined consumer/decision observer admits one live operation per
session. Production must key decision admission and disposal **per task** and
verify concurrent operations without canceling another task's decision. This
fixture is not a production finalizer, delegate proxy, scheduler, or dependency.

## FN-09/FN-10 audit

The independent forwarding executor passes the demonstrated start/cancel/finish
paths. FN-10 now has a second concrete failure: the stable Linux cancellation
race with a native delegate queue width of four can deliver two completion
callbacks and trap when removing the task twice. The protocol emits only one
terminal event under its existing callback/stop lock; Foundation independently
injects the cancellation failure. Its completion branches check task state,
invoke the consumer, then mark the task completed. Concurrent callbacks can
both pass that check before either writes the completed state.

Use serial native delegate queues for the owned session and private transport.
Apple's [initializer documentation](https://developer.apple.com/documentation/foundation/urlsession/init(configuration:delegate:delegatequeue:))
recommends a serial queue for callback ordering. This is compatible with DD12's
configuration-first construction and lack of a callback-queue identity promise.
The ordinary serial race test remains mandatory; the 1,000-iteration audit
checks the same path more deeply. Keep the concurrent Linux crash as an opt-in
upstream regression, without calling its disabled result a pass. The
[handoff](003-D02-foundationnetworking-handoff.md#d05-terminal-race-audit--2026-09-27)
records exact source paths, classification, and reproduction.

The original invalid-download-resume registration race remains separately
identified. Serial delegate queues do not repair its independently initialized
task work queue. The existing fixture registration barrier remains; excluded
resume-data operations do not become supported Diorama behavior.

## Consolidated six-question matrix

“Proved” here means the isolated cases on the tested runtimes, not production
implementation or validation of every OS release at the deployment floors.

| DD12 question | Apple macOS/iOS evidence | Stock Linux evidence and implementation constraint |
| --- | --- | --- |
| 1. Creation forms, routing, cache/live isolation | D01/D02 prove the covered data-task forms, cache disabling, private forwarding, and task ownership; D05 revalidates delayed ownership and removes expired routes | Task ownership works without FN-03/FN-04 repairs. FN-08 with FN-05/FN-07 still prevents the full transparent delegate-integration claim. |
| 2. Early task/body rejection | D02 creation hooks reject excluded tasks with diagnostics and native errors; original-request bodies distinguish data from streams | Preserve demonstrated native refusals, including unsupported WebSockets. Do not advertise missing delegate guards as enforced. |
| 3. Heads, segments, presentation | D02 controlled delivery covers delegate, completion, and async results; D05 cancels/drains all four presentation categories | FN-01 still breaks segmented aggregate results. Preserve the approved native response-disposition limitation; reject incompatible replay and unrepresentable recordings. |
| 4. Redirect correlation/decisions | D03 follows/modifies/refuses correlated hops; D05 keeps admitted live redirects working after the horizon without scenario retention | FN-11 is required for custom redirects. FN-12–FN-14 are inherited native findings; the private-hop body workaround remains unproved on Linux. |
| 5. Basic/Digest and safe decisions | D04 observes ordinary delegate completion decisions and bridges the private sender; D05 releases pending decisions during cancellation and preserves post-horizon live answers | FN-15 must prevent replay from becoming live HTTP. FN-16 Digest has the owner-approved native exception. FN-17 proxy support and FN-18 TLS error mapping remain native upstream recommendations. |
| 6. Finish, cancellation, routing and lifetime | D05 stops/drains replay, detaches live observation, continues admitted live work, and releases completed native ownership; creating new tasks after invalidation crashes | Covered serial-queue paths run directly. Custom redirect/auth lifecycle cases remain disabled pending FN-11/FN-15. FN-09 uses an independent executor; FN-10 concurrent terminal delivery needs isolation or repair. Native post-invalidation creation also crashes. |

## Production plan review

Retain H01–H14's stable HTTP model, recursive decisions, exact body storage,
persistence, matching, and preparation boundaries. Native queue/ownership types
remain inside the URLSession bridges. H01 still needs its separate dependency
approval, and no spike target becomes a production import.

Retain I01–I09's small capability sequence, with explicit constraints now added
to the owning plan:

- **I01:** task ownership replaces obsolete header/property requirements;
  independent forwarding execution, serial native queues, lease revalidation,
  replay drainage, live observation detachment, and native invalidation start
  in the first supported vertical path.
- **I02/I04:** carry FN-01 aggregation and FN-08 delegate integration as required
  upstream work. Preserve the approved Linux disposition exception. Own and
  dispose per-task native answers; do not synthesize recorded decisions.
- **I03:** preserve native failures and the distinction between dependency
  failure, caller cancellation, and cleanup. FN-18 does not require remapping
  live Linux errors into invented Apple errors.
- **I05/I06:** carry admitted live continuation state across replacement native
  instances after route removal. Resolve ordinary delegate completion decisions
  through the private bridge; each hop owns its pending answers. FN-11/FN-15
  remain required for offline Linux fidelity.
- **I07:** apply the approved native Linux Digest exception; no hand-written
  Digest implementation or unsupported Linux replay claim.
- **I08:** extend the proved boundaries across all production phases, concurrent
  tasks, repeated/concurrent/canceled finish waiters, scheduler acknowledgements,
  recording publication, and re-recording. These integrations are not proved by
  this isolated native spike.
- **I09:** validate the repaired runtime and cross-bridge fixture intersection.
  Disabled/known-issue tests never establish a supported capability.

Continue Linux implementation assuming required upstream fixes will arrive,
as already directed. D05 introduces no new production dependency or unapproved
API change. The approved invalidation amendment resolves the raw-session
contract conflict; Phase D remains one owner review/merge unit. Production may
depend on this feasibility boundary after that review and the ordinary unit
approvals, not merely because a local spike command exits successfully.

## Executable case index

All files below belong to the isolated spike test target:

| Cases | Source |
| --- | --- |
| Replay cancellation, executing callbacks, open decisions | [D05ReplayTests.swift](../../Spikes/URLSessionInterception/Tests/URLSessionInterceptionTests/D05ReplayTests.swift) |
| Queued native callback drainage | [D05QueuedCallbackTests.swift](../../Spikes/URLSessionInterception/Tests/URLSessionInterceptionTests/D05QueuedCallbackTests.swift) |
| Expired lookup and repeated ownership release | [D05OwnershipTests.swift](../../Spikes/URLSessionInterception/Tests/URLSessionInterceptionTests/D05OwnershipTests.swift) |
| Live horizon, private startup/cancellation, weak release | [D05ForwardingTests.swift](../../Spikes/URLSessionInterception/Tests/URLSessionInterceptionTests/D05ForwardingTests.swift) |
| Live redirect/authentication continuation after route removal | [D05DecisionForwardingTests.swift](../../Spikes/URLSessionInterception/Tests/URLSessionInterceptionTests/D05DecisionForwardingTests.swift) |
| Completion/async live continuation | [D05AggregateForwardingTests.swift](../../Spikes/URLSessionInterception/Tests/URLSessionInterceptionTests/D05AggregateForwardingTests.swift) |
| Terminal races and FN-10 investigation | [D05CancellationRaceTests.swift](../../Spikes/URLSessionInterception/Tests/URLSessionInterceptionTests/D05CancellationRaceTests.swift) |

## Final executable gate

The final revision passes the canonical V-spike checks with warnings as errors:

| Profile | Complete D01–D05 gate | D05 contribution | Additional serial audit |
| --- | --- | --- | --- |
| macOS 27.0 / Xcode 27 / Swift 6.4 | 306 expanded cases pass; no unexpected issues | 45 cases | Ordinary 50 serial and 50 concurrent iterations are included |
| iOS 27.0 / iPhone 17 Simulator | 306 expanded cases pass; no failures or runtime warnings | 45 cases | Ordinary 50 serial and 50 concurrent iterations are included |
| Stable Linux `swift:6.4.0-noble` | 201 expanded cases pass with 61 existing known-issue assertions | 34 cases | 1,000 additional serial iterations pass |
| Pinned Swift 6.4.2 Linux snapshot | 201 expanded cases pass with the same 61 known-issue assertions | 34 cases | 1,000 additional serial iterations pass |

The Swift Testing summaries report 81 declarations on Apple (77 run and four
opt-in probes skipped), and 78 on Linux (58 run and 20 skipped, excluding the
skipped suite container). The table expands parameterized cases. Xcode reports
77 passed declarations, four skipped, 50 parameterized declarations containing
279 cases, and zero failed tests. The default Linux count excludes the known
fatal/escaping custom redirect/auth paths and the concurrent terminal race.
Their intended assertions remain available through the documented controls.
The 61 known assertions are inherited from D01–D04; D05 adds no blanket expected
failure. Passing this gate does not claim that stock Linux is fully compatible.

`scripts/lint` passes with zero violations across 138 Swift files. Changed documents' local
Markdown file targets resolve and `git diff --check` passes. No hosted D05 CI,
external HTTPS rerun, deployment-floor runtime run, or patched Foundation build
is claimed. D04's separately recorded HTTPS evidence remains historical.

Local artifacts: `.build/d05-gate-macos-final.log`, `.build/d05-gate-ios.log`,
`.build/urlsession-spike-ios.xcresult`, `.build/d05-gate-linux-stable.log`,
`.build/d05-gate-linux-snapshot.log`, `.build/d05-serial-audit-linux.log`, and
`.build/d05-lint.log`. The snapshot log includes its extra serial audit after
the complete gate. The first fatal concurrent Linux run is retained separately
as `.build/d05-all-linux.log`.

Canonical commands are `Spikes/URLSessionInterception/run swiftpm`,
`Spikes/URLSessionInterception/run ios`, and `scripts/lint`. Linux uses the same
SwiftPM entry point after copying `Spikes/URLSessionInterception` and `scripts`
from a read-only mount into `/work`. Exact runtimes and the snapshot digest
are recorded in the initial checkpoint table above.

Additional audit commands:

```sh
DIORAMA_D05_STRESS_SERIAL=1 swift test \
  --package-path Spikes/URLSessionInterception \
  --scratch-path .build/urlsession-spike -Xswiftc -warnings-as-errors \
  --filter 'D05ReplayTests.*extended'

# Separate process: this can crash an unpatched Linux runtime.
DIORAMA_D05_UNSAFE_TERMINAL_RACE=1 swift test \
  --package-path Spikes/URLSessionInterception \
  --scratch-path .build/urlsession-spike -Xswiftc -warnings-as-errors \
  --filter 'D05ReplayTests.*concurrent'
```

`DIORAMA_VERIFY_FOUNDATION_FIXES=1` also restores the concurrent terminal test
and the FN-11/FN-15 decision probes. Native Digest remains outside the stock
Linux profile. No upstream patch is tested by this branch. D05 adds no known
issue that conceals an unexpected assertion failure.
