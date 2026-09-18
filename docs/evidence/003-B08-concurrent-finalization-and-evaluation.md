# 003-B08: Concurrent finalization and report evaluation

- Date: 2026-09-14
- Status: Complete; accepted by the owner and authorized for pull request
  creation on 2026-09-16.
- Authority: Owner confirmation of 003-B08's scope and GPT-6 Astra at `xhigh`
  reasoning, including initial stacked development atop B07 and the owner's
  requested local rebase onto B07A on 2026-09-16. Owner review consolidated
  lease closure into one usage-returning, discardable-result operation.
- Prerequisites: [B07A evidence](003-B07A-typed-dependency-keys.md),
  [DD05](../design-decisions/05-consumption-and-verification.md),
  [DD10](../design-decisions/10-lifecycle-and-ownership.md),
  [DD13](../design-decisions/13-random-proving-system.md), and Plan 003's resolved Q3.

## Public behavior

`ScenarioFinalizationResult` now includes ordered attachment and sequential-track
usage alongside the existing immutable diagnostics, recording health, and cleanup
outcomes. It has no test pass/fail status. `finish()` remains a nondiscardable
asynchronous operation.

Each active track reports one activity: record, replay, or passthrough.
Record activity counts admitted and incomplete observations. Replay counts used
and unused records, with every unused identity available in sequence order.
Exhaustion attempts do not inflate the used count. Record and passthrough do not
incur replay consumption obligations. Successful sequential claims complete
synchronously; this capability has no separate incomplete replay lifecycle.
Grouped lifecycle-completion evaluation belongs with the later grouped engines.

Usage follows attachment and track declaration order, even when registrations
or lease requests arrive in a different order. Reports contain identities and
counts, never recorded values, source factories, live sources, or arbitrary
errors. Escaped leases retain only their frozen usage and existing lightweight
identity, mode, admission, and reporter context.

## Later revision: unmatched loaded attachments

The existing distinction between an active attachment declaration and its
required runtime registration remains intact: missing, extra, duplicate, or
incompatible registrations still fail startup.

This unit originally added value-free `UnattachedTrack` inventory to core usage
and evaluation. On 2026-09-18, before C01 review continued, the owner approved a
prerequisite revision that removes that inventory. Persistence still registers,
decodes, prepares, and validates the complete loaded document. Repository
startup then diagnoses and discards attachments absent from current setup, so
only active attachments enter core execution usage. `ignoredAttachments` now
names configured attachments and exempts only their unused-recording facts;
unknown ignored keys still fail definition validation in lexical order.

## Finalization and synchronization

The execution still closes shared admission and starts one owned task. Every
concurrent or repeated caller awaits the same task/result. Canceling a waiter,
including the first caller before it starts finishing, does not cancel cleanup.
This sequential API continues waiting until cleanup completes; it does not
promise early cancellation of an individual wait.

Lease closure captures usage under the same mutex that serializes claims and
record admission. It then detaches content and releases it outside that mutex.
The internal lease boundary exposes one `@discardableResult close()` operation:
finalization retains its usage, while rollback can intentionally ignore it.
Preparation slots distinguish preparing, failed, and admitted observations.
An already reported preparation failure retains its original diagnostic; a
reservation still preparing at closure produces `recordingNotAdmitted` and
makes recording health invalid before result freeze. Late preparation cannot
admit a value or alter the frozen counts.

Cleanup remains in reverse activation order and continues after a callback
throws. Cleanup outcomes render in attachment order. The resource-release scope
ends before the reporter freezes, preserving diagnostics emitted during release.
Reporter retention and freeze share a mutex, so a racing diagnostic enters
exactly one of the immutable execution report or the separately inspectable
post-finish log. Sink notification follows retention outside the lock.

An escaped random generator remains offline after finish and can diagnose new
misuse after the execution is released. The reporter releases when its last
execution, escaped handle/context, or direct owner releases it. Retaining the
final result does not keep the reporter alive.

## Evaluation and rendering

`result.evaluate(condition, attachments: keys)` returns structured failures and
an explicit `isSatisfied` result. Omitting keys selects the whole scenario;
selecting keys includes only facts attributed to those attachments. Scenario
diagnostics are therefore evaluated by the whole-scenario call. Unknown selected
keys yield failures, while an explicitly empty set selects nothing.
Dependency lookup failures identify the requested attachment when its key is
known, including closed lookups; unknown-key lookups remain scenario facts.

The available conditions are `noUnexpectedOperations`, `noDiagnostics`,
`allRecordingsUsed`, `healthyRecording`, and `successfulCleanup`.
`noUnexpectedOperations` recognizes core exhaustion, wrong-mode, and invalid
access facts; system-authored labels have no universal operation meaning and
can be checked with `noDiagnostics` or consumer inspection. Only
`allRecordingsUsed` honors usage exclusions. Evaluation neither emits new
diagnostics nor calls a test framework, and later misuse cannot change it.

For example, after application work using an explicitly retained execution:

```swift
let result = await execution.finish()
let randomUsage = result.evaluate(
    .allRecordingsUsed,
    attachments: [AttachmentKey(rawValue: "random")])
print(result.rendered())
// The caller chooses how randomUsage.failures affect its test or harness.
```

`rendered()` uses owned text spelling and stable report ordering. It escapes
quotes, backslashes, control characters, and directional formatting controls in
setup-authored identities and labels. It never uses descriptions of recorded
values or errors, wall time, locale, process identity, or a test-outcome flag.
Its text is a human-readable report rather than a persistence schema.

## Scope and review boundary

Production changes are confined to `DioramaCore`. Core tests prove usage,
evaluation, deterministic safe text, controlled cancellation and cleanup overlap,
in-flight preparation, and lossless diagnostic routing across freeze. Random
tests prove the public result accounts for racing claims and unused values,
and that escaped generators/reporters honor their release boundaries.

No dependency, unsafe concurrency annotation, deployment-floor change,
persistence format, scheduler, native adapter, scoped convenience, or test
integration is added. Timed callback quiescence remains 003-E03, publication
remains 003-C05, and scoped execution remains 003-B09.

## Verification method

The canonical gate is `scripts/check`: pinned Mint formatting and strict lint,
Swift 6 warnings-as-errors host tests, and release compilation. Platform
coverage uses `scripts/coverage swiftpm macos`, `scripts/coverage ios`, and the
[canonical Apple Container reproduction](../quality-gates-and-ci.md#local-entry-points)
of `scripts/coverage swiftpm linux` with the exact approved image digest,
`x86_64` architecture, two CPUs, and 4 GB of memory. The Linux source mount is
read-only and package inputs are copied into the container's working directory.

The first Linux run exposed cooperative-worker starvation in the new test
harness. Its deliberately blocked capture now runs on a Dispatch worker;
controlled blocking test cases are serialized so they cannot occupy both
cooperative workers. Their explicit concurrent finish/diagnostic tasks still
race. CPU limits, ten-second failure timeouts, assertions, and production
shutdown behavior are unchanged.

A negative compiler probe also typechecks a consumer that discards
`await execution.finish()`. `swiftc -swift-version 6 -warnings-as-errors
-typecheck -target arm64-apple-macos15.0 -I .build/out/Products/Debug` rejects it
with `result of call to 'finish()' is unused`, proving the public result remains
nondiscardable.

## Verification results

The following checks passed for the accepted revision on 2026-09-16 after its
B07A rebase and owner-requested close-API refinement:

| Gate | Result |
| --- | --- |
| `scripts/check` | Zero formatting/lint violations; 78 tests pass (59 core, 15 random, 4 consumer); debug and release compilation pass with warnings as errors. |
| Local Apple toolchain | Xcode 27.0 final, build `27A266a`; Apple Swift 6.4 `swiftlang-6.4.0.34.1`. |
| `scripts/coverage swiftpm macos` | All 78 tests and release compilation pass; repository-relative LCOV exports successfully. |
| `scripts/coverage ios` | All 78 tests and release compilation pass on iPhone 17 / iOS 27.0 Simulator with the iOS 18 deployment floor; LCOV exports successfully. |
| Pinned Linux container | All 78 tests and release compilation pass with Swift 6.4.2-dev (`d2e983b81b18217`), target `x86_64-unknown-linux-gnu`; LCOV exports successfully. |
| Nondiscardable-result probe | The compiler rejects an ignored `finish()` result with the expected unused-result diagnostic. |
| Documentation/diff | Local links and anchors resolve; the complete B08 diff against B07A passes `git diff --check`. |

macOS and iOS source coverage are each 1,453 of 1,481 lines (98.11%); the pinned
Linux export also completes successfully. These measurements are evidence, not
new coverage thresholds; 003-B10 still owns that policy decision. LCOV files
are generated under `.build/coverage` and are not committed. Hosted Quality,
macOS, iOS, Linux, and Codecov statuses are required integration gates obtained
through the authorized PR workflow.

The review base is B07A. At the owner's request, the feature, tests, acceptance
status, and evidence form one squashed review commit. This review does not
incorporate B07A's own changes into the B08 diff.
