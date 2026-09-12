# 003-B03: Execution activation and sequential lease lifetime

- Date: 2026-09-10
- Authority: Owner confirmation of 003-B03's scope and GPT-6 Astra at `high`
  reasoning, including development on its own branch stacked on unmerged B02.
- Status: Complete; owner accepted the review unit on 2026-09-12.
- Prerequisites: [B02 evidence](003-B02-prepared-admission-and-diagnostics.md),
  [DD10](../design-decisions/10-lifecycle-and-ownership.md),
  [DD13](../design-decisions/13-random-proving-system.md), and the resolved
  [Q2/Q3 contracts](../plans/003-clean-slate-implementation.md#unresolved-gates-and-evidence-dependent-choices).

## Review boundary

This unit adds fresh in-memory execution startup, ordered system preparation
and activation, reverse rollback, typed sequential lease lifetime, and explicit
asynchronous finish. The owner authorizes stacking this work on B02 while B02
remains under review. That does not treat B02 as an accepted integration baseline;
B02 review changes must be incorporated before B03 integrates.

The deployment and lint prerequisites are already merged in
[PR #7](https://github.com/SwiftScream/diorama/pull/7). This branch contains one
B03 implementation review unit above the B02 implementation, not another copy
of those prerequisite changes.

## Public boundary

- `ScenarioSystem` registers exactly one declared attachment, with a typed
  preparation callback. Heterogeneous registrations coexist; their array order
  does not override the definition's attachment order.
- `SystemPreparationContext.lease(for:preparation:)` selects the current typed
  policy and creates a fresh reference-semantic `SequentialTrackLease`. Every
  declared track must prepare before activation. Repeated, incompatible, missing,
  and escaped-context requests produce safe diagnostic evidence.
- Record and replay input is prepared again under the selected setup policy.
  Passthrough checks identity but does not inspect or transform record values.
  This unit retains prepared baseline content; it does not append or claim it.
- `PreparedSystem` separates preparation from installation. Its activation
  returns a `SystemActivation` containing a sendable dependency and a synchronous
  cleanup callback, sufficient for the sequential proving system.
- `ScenarioExecution.start` validates registrations before callbacks, prepares
  every system before any activation, and publishes an execution only after all
  activations succeed. Every start has independent leases and a fresh reporter.
- `dependency(for:as:)` retrieves an activated dependency by key and type while
  running. A returned handle may race finish and must honor its lease closure.
- `finish()` closes admission, cleans up, releases execution-owned content and
  activation captures, then freezes one retained `ScenarioFinalizationResult`.
  Startup failure similarly returns a `ScenarioStartupFailure` with safe
  diagnostics and ordered rollback dispositions, never an underlying error.
- Lease `report` accepts safe system facts while open. After closure it reports
  `leaseClosed` instead, returning false. Later facts remain inspectable through
  the separately retained reporter without changing the frozen result.

## Ordering and ownership

```text
validate registrations
  -> prepare all tracks and systems
  -> activate attachments in definition order
  -> expose execution and typed dependencies
  -> close admission and leases
  -> clean up in reverse activation order
  -> release execution-owned resources
  -> freeze diagnostics and cleanup result
```

Failed preparation activates nothing. Failed activation closes all leases and
unwinds only successful activations. Cleanup continues after a callback throws;
the outcome array remains in definition order, independent of reverse cleanup.
If an activation throws before returning its cleanup obligation, the callback
must unwind its own partial installation. Callbacks must not independently
publish partially initialized dependencies.

An execution-owned, non-detached task performs finish exactly once. Its captured
resource holder is emptied before report freeze, so diagnostics emitted while
resources are destroyed are still part of the result. The startup resource scope
also ends before its failure report freezes. Neither cleanup, destruction of
stable values, nor sink notification runs under a core state lock.

Concurrent finish callers await the same result. A canceled caller still awaits
cleanup; it cannot abandon the execution's cleanup operation. This is the basic
lifetime boundary, not the complete B08 usage/evaluation and race-conformance
milestone. A cleanup callback must not synchronously wait for a recursive finish
of its own execution.

Closed leases retain identity, mode, a small admission-closed bit, and the
reporter, but no track values or execution reference. Preparation contexts drop
their declaration and lease storage when the callback ends. Handles and reporters
therefore need not retain the execution or its resources. Registration callbacks
must create fresh per-run state, and consumer handles must keep releasable live
resources behind their adapter's cleanup boundary. Diorama cannot correct a
consumer closure that deliberately captures its owner or retains live resources
inside an escaped dependency. Consumer-owned sources are not canceled or closed.

No dependency, manifest, deployment, unsafe-sendability, unsafe-isolation, or
detached-task exception is introduced.

## Verification

- `scripts/check` passes formatting, strict lint, 38 tests, and warning-free
  debug/release compilation in the selected Apple toolchain.
- `scripts/coverage swiftpm macos` passes all 38 tests and collects coverage.
- `swift test -c release -Xswiftc -warnings-as-errors` passes all 38 tests,
  including resource-release and freeze-boundary assertions under optimization.
- `scripts/coverage swiftpm linux` passes all 38 tests, debug/release builds,
  and coverage discovery in the approved x86_64 image
  `swiftlang/swift@sha256:15ae709b1d8eb1f8691b300f5721499d007e944694f2c0e9929a55580c9bf1a5`.
  It reports Swift `6.4.2-dev (LLVM 15622a86b1749a9, Swift d2e983b81b18217)` and
  `libcurl4-openssl-dev` `8.5.0-2ubuntu10.13`. The repository is mounted read-only
  and copied to an isolated temporary directory in a two-CPU, 4 GB container.
- `scripts/coverage ios` passes the release build, all 38 tests (55 invocations
  including parameterized cases), and coverage reporting on the selected
  iPhone 17 / iOS 27.0 simulator at the iOS 18 deployment floor. The final
  result bundle has no failures, skips, or runtime warnings. Xcode emits its
  metadata-extraction message for a test bundle without AppIntents; compiler
  warnings remain errors.
- An external client compiled with Swift 6, complete strict concurrency, the
  macOS 15 target, and warnings as errors rejects an ignored `finish()` result
  with `result of call to 'finish()' is unused`.
- Local Markdown file targets exist and the complete B03 diff passes
  `git diff --check` against its B02 base.

One iOS run concurrent with the Linux build timed out waiting for B02's
unchanged five-second blocked-callback handshake. Its failure is preserved in
`.build/003-B03-ios-timeout.xcresult`; Xcode's subsequent simulator diagnostics
collector was interrupted after the tests ended so the failed bundle could
finalize. An unchanged full rerun without the competing build passed, and the
final run after strengthening B03's exactly-once cleanup assertion also passed.
This is consistent with scheduling sensitivity, not proof that B02's timeout
is robust under load. The B02 test and production reporter remain unchanged in
this unit; no tests were skipped or deadlines relaxed.

The new tests use ordinary `import DioramaCore`, not `@testable` or SPI. They
prove ordered preparation/activation, independent starts, heterogeneous dependency
lookup, modes, failure at each preparation/activation position, continued reverse
cleanup, safe error handling, required track preparation, closed-context rejection,
reentrant callbacks, concurrent/canceled finish callers, immutable results, and
post-finish reporting with and without a sink. Release probes prove content,
source, recipe, execution, and reporter lifetime, including release-time
diagnostics before both normal and failed-start result freeze.

The required hosted Quality, macOS, iOS, Linux, and Codecov evidence remains
pending owner authorization to push and create a B03 PR. Local executions do
not establish runtime behavior on actual macOS 15 or iOS 18 installations.

## Exclusions and next boundary

B04 supplies ordered appends and atomic replay claims. B05 adds its separate
consumer-support module proof. Random, persistence, logical-time scheduling,
native adapters, asynchronous adapter quiescence, full usage/evaluation reports,
and scoped execution helpers remain in their owning units. No later unit is
started by completion of B03.
