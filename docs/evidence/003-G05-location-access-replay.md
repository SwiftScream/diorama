# 003-G05 — Access state replay and authorization barriers

- Date: 2026-10-18
- Status: Complete. Canonical checks and local macOS, iOS, and pinned Linux
  coverage gates pass. The owner authorizes a stacked PR on 2026-10-18.
- Scope/model: The owner confirms the outlined G05 scope and GPT-6 Astra at
  `high` reasoning on 2026-10-18.
- Base: `feat/003-G04-location-update-replay` at `1d2934b`.

## Result

`LocationAccessReplay` is an internal MainActor access service using the existing
strict access records, Core claims, and execution scheduler. G07 connects its
synchronous notification callback to the manager's weak delegate. Its initial
native state is readable before observation; reads never claim or consume a
record. The first `observe` registration claims the initial segment and anchors
its notification delays. Replacing delivery preserves the claim and timeline.

Access replay follows one ordered sequence. It finishes the current segment's
notifications before accepting a request at the next barrier. Selection checks
both the exact next record position and its request kind, so an earlier or later
record with the same kind cannot be selected accidentally. A matching request
claims only that segment and anchors its following delays to the invocation.
Early, wrong, duplicate, or exhausted requests retain a safe selection diagnostic
and return without advancing the lifecycle. No request invokes Core Location.

Each notification installs the complete native state before calling the consumer.
Duplicate states remain observable, and disabled services remain state rather
than a dependency failure. External changes in the initial segment schedule
without a request. Only the next notification is registered, using cumulative
delay from the segment's original anchor, so late callbacks do not add drift.
Zero-delay notifications still go through the scheduler's next drain.

The final notification exposes the next barrier before calling the consumer,
allowing a matching request from inside that callback. The completed old claim
is acknowledged after return without scheduling on behalf of the new segment.
Intermediate callbacks cannot skip their remaining notifications. Empty segments
are acknowledged immediately without synthesizing a notification. Claim progress
counts delivered notifications; an accepted empty request has zero progress and
is consumed. Requests never made remain independent unused Core records.

`LocationAccessState` explicitly converts known semantic authorization and accuracy
values to native values. A stored `whenInUse` state presents as `authorizedAlways`
on macOS and `authorizedWhenInUse` on iOS, for both initial and notified state.
The stored permission and request kind remain unchanged: a macOS `always` request
does not match a recorded `whenInUse` barrier.

## Lifecycle

The replay mode's `requestStop` calls `close()` on MainActor before Core joins
scheduled delivery. Close detaches execution ownership before canceling pending
work and releasing the callback. The last native state remains readable. Closed
authorization requests report lifecycle misuse; repeated close is harmless, and
replacement observation cannot retain or invoke a consumer after closure.

Scheduler closures capture the access service weakly and await actor delivery
inside Core's tracked scope. A claimed callback still waiting for MainActor is
suppressed when admission closes. A callback already executing completes before
report freeze; concurrent or canceled finish waiters share that completed result.
If more notifications remain when admission closes during a callback, their
delivery stops while the claim retains its partial progress. The new regression
first reproduced an attempted reschedule during shutdown; the engine now checks
admission before scheduling the remainder.

## Verification

Controlled tests exercise external changes, duplicate notifications, complete
state reads inside callbacks, initial native presentation, exact barrier matching,
request-relative timing, unrequested records, same-kind successive empty requests,
callback replacement, reentrant requests and close, independent attachments,
partial progress, pending cancellation, frozen state, and capture release.

A scheduler probe establishes a claimed handoff while MainActor is occupied,
then closes admission before actor entry. A separate gated callback proves finish
waits for consumer return with and without following notifications. The gates use
signals for ordering and semaphore timeouts only as failure safeguards. A real
ContinuousClock test verifies the request's twenty-millisecond delay does not
deliver early. An extreme valid delay remains pending until shutdown.

### Apple verification

- `scripts/verify-apple-toolchain` passes with Xcode 27.0 (`27A266a`), Apple
  Swift 6.4 (`swiftlang-6.4.0.34.1`, `clang-2100.3.34.1`), and the selected
  iOS 27.0 Simulator runtime.
- Focused `swift test -Xswiftc -warnings-as-errors --filter LocationAccess`
  passes nineteen tests across the access value and replay suites. The final
  canonical runs also include the added nonfinal-callback shutdown regression.
- `scripts/check` passes strict formatting/lint, all 566 tests, coverage-export
  fixtures, public system-authoring and lifecycle compiler probes, warnings-as-errors
  Release builds, and both usage examples.
- `scripts/coverage swiftpm macos` independently passes its clean-build gate
  with all 566 tests and exports `.build/coverage/macos.lcov`.
- `scripts/coverage ios` passes its Release build, all 565 iPhone 17 / iOS 27.0
  Simulator tests, lifecycle compiler probes, and `.build/coverage/ios.lcov`.
- Both Apple reports cover 152/155 executable access-replay lines (98.06%) and
  all fifteen native access-state conversion lines. The three uncovered lines
  clear pending work and enter the inert continuation after scheduler registration
  failure. No threshold or test job is weakened.

Initial sandboxed commands cannot write Swift/tool cache files or connect to
CoreSimulator. The successful gates use approved access to those local toolchain
facilities; no compiler or linter warning exception is added.

### Linux verification

The local gate uses Apple Container with the CI-pinned Swift image, x86_64
architecture, two CPUs, and 4 GB memory. The repository mount is read-only;
package inputs build in disposable container storage:

```bash
container run --rm --arch x86_64 --cpus 2 --memory 4G \
  --mount type=bind,source="$PWD",target=/source,readonly --workdir /work \
  swift@sha256:64bab762bc73a3fda6d9ebc559258bd6d7660c10a705bb25ecacad2f99d066f9 \
  bash -lc 'mkdir -p /work && cp -R /source/Package.swift /source/Sources /source/Tests /source/scripts /source/Examples /work/ && scripts/coverage swiftpm linux'
```

The gate passes all 487 applicable tests, coverage-export fixtures, public
system-authoring and lifecycle compiler probes, strict Release builds, both
examples, and LCOV export inside the container. Location is absent from the
Linux build graph. The emulated example launcher emits the previously recorded
`safeExec` signal 32/33 notices; both examples exit successfully.

### Documentation verification

All 281 local links in the owning plan, evidence, and documentation index resolve,
including Markdown heading anchors. The complete feature-branch whitespace check
uses `git diff feat/003-G04-location-update-replay --check`.

## Review boundary

The implementation and proving tests form one feature commit. Plan, evidence,
and index updates form a documentation commit. The complete review diff is
against the G04 feature branch. The required PR matrix is Quality, macOS, iOS,
and Linux with platform Codecov uploads. Merge requires passing checks for the
revision being merged and a separate owner request.

This unit establishes internal access replay. The manager/delegate facade remains
G07, origin policy and re-record replacement remain G06, and the native live bridge
and broader acceptance remain G08/G09. It introduces no public async interface,
production Core API, dependency, persistence schema, or deployment-floor change.
Native source construction, system permission prompts, and live recording are
outside this evidence. The owner authorizes PR creation and requests no CI
monitoring for this handoff. Merge and starting G06 remain separate owner
checkpoints.
