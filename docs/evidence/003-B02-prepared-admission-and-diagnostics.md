# 003-B02: Prepared admission, safe diagnostics, and health

- Date: 2026-09-09
- Plan: [003-B02](../plans/003-clean-slate-implementation.md#003-b02--prepared-admission-safe-diagnostics-and-health)
- Status: Complete; owner accepted the review unit on 2026-09-12. Hosted
  V-code evidence remains pending before integration.
- Authority: [DD05](../design-decisions/05-consumption-and-verification.md),
  [DD06](../design-decisions/06-runtime-to-snapshot-conversion.md),
  [DD09](../design-decisions/09-normalization-and-redaction.md),
  [DD10](../design-decisions/10-lifecycle-and-ownership.md), and Plan 003's
  resolved Q3 reporting contract.
- Owner confirmation: GPT-6 Astra, `high` reasoning, and the bounded B02 scope.

## Prepared admission

`ValuePreparation<Value>` is an immutable, typed setup policy. Its synchronous,
nonescaping capture closure lets the system detach native data in its valid
isolation. The policy then applies structural canonicalization, redaction,
volatile normalization, and validation in that order. The first failure stops
the pipeline. Only successful preparation creates `PreparedValue<Value>`;
its initializer is inaccessible to consumers.

`SequentialTrack<Value>` now takes `[PreparedValue<Value>]`. Its records expose
the resulting semantic values with the existing stable identities and ordering.
Empty tracks still work without a preparation call. The existing definition
tests explicitly select an unchanged-value policy for their safe fixtures.

Systems own transformation semantics, determinism, idempotence, and stable value
semantics. The default policy deliberately preserves custom values unchanged.
Preparation does not certify that a payload contains no personal data, and
`Sendable` alone does not make a reference-backed value semantically immutable.
The core adds no native codec, reflection sanitizer, domain redaction defaults,
matching projection, or persistence policy.

Preparation failure retains a diagnostic before returning a typed
`PreparationFailure`. The diagnostic contains the conversion/preparation stage,
stable identity context, optional static field/rule labels, and recording
impact. The raw value, underlying error, its description, and runtime type are
never retained or rendered. Recording-purpose failures invalidate candidate
health; replay-purpose failures remain infrastructure facts without declaring
a recording damaged. Successful later preparation does not clear prior damage.
Adapters remain responsible for forwarding live behavior after recording
failure and for prohibiting live fallback during replay. Passthrough requires
no preparation call.

## Safe diagnostics and ordering

`Diagnostic` represents infrastructure and verification facts separately from
dependency errors and test outcomes. `DiagnosticContext` selects one scenario,
attachment, track, or record identity; ancestor identities derive from that
case rather than allowing contradictory fields. `DiagnosticLabel` accepts only
`StaticString`, allowing setup-authored rule names, semantic field labels, and
consumer-system issue codes without interpolated runtime payloads. Identity
strings remain the safe setup-authored identifiers required by the system
contract; callers must not use them to smuggle captured data into diagnostics.

`DiagnosticReporter` copies only scenario, attachment, and track identity
metadata from a definition. It does not retain that definition's heterogeneous
content. Every fact receives a unique admission sequence under the state lock.
Inspection returns immutable snapshots ordered by scenario context first,
attachment declaration order, track declaration order, record sequence, then
diagnostic admission sequence. Undeclared identities follow declared ones in
lexical system/key order. Concurrent callers determine admission order when
they reach the lock; callback completion does not determine report order.

`DiagnosticReport.recordingHealth` derives its failure facts from precisely the
same snapshot. It has no overall test verdict. `ScenarioStartupFailure` carries
a safe immutable report for an attempt that yields no execution; activation
and rollback disposition belong to B03.

## Callbacks and ownership

`DiagnosticSink` is an optional reusable closure-backed destination. Retention
and health are visible before the callback starts. Callbacks execute
synchronously outside the reporter lock, may overlap, and may reenter reporting
or inspection. Sink implementations synchronize their own captured state.
Thrown sink errors produce an additional safe `sinkFailed` fact without
rendering the error or recursively notifying the failing sink. A sink failure
alone does not invalidate an otherwise healthy candidate.

The reporter's internal `freeze()` atomically preserves one diagnostic report
and routes later facts to its separately inspectable `postFinishDiagnostics`.
Repeated freezes and active-report inspection return the same frozen facts and
health. A callback failure arriving after freeze enters the late log. Both logs
work without an installed sink. This is the diagnostic foundation for Q3;
execution `finish()`, leases, quiescence, and the full concurrent finalization
proof remain in B03/B08.

The reporter retains only safe facts, ordering metadata, and the configured
sink. It has no global registry, scheduling work, or ownership of native live
sources. A lifetime test proves that definition content is released while the
reporter remains usable and that the reporter is released with its last owner.
Consumer sinks must avoid strong cycles back to their reporter or execution;
the sink documentation states this ownership responsibility.

The reporter stores its state directly in `Synchronization.Mutex`, using the
same primitive on Apple and Linux. The owner's separate
[deployment prerequisite](003-B02-deployment-minimums.md) raises the supported
floors to macOS 15 and iOS 18, allowing the implementation to omit the earlier
`Locked<State>` wrapper and all platform-specific lock branches. The tests
also use `Mutex` directly; their error-description and lifetime probes report
through closures instead of copying a noncopyable mutex. The reporter's
public API and retention/callback behavior are unchanged. Diorama adds no
dependency, `@unchecked Sendable`, unsafe isolation annotation, or detached task.

The first multiline public declarations exposed an existing overlap:
SwiftFormat's `wrapMultilineStatementBraces` and SwiftLint's `opening_brace`
require different placements. `.swiftlint.yml` assigns brace ownership to the
pinned formatter by disabling only that duplicate lint rule, as required by
the quality policy. Strict lint and non-mutating formatting checks remain
mandatory.

## Verification

The 20 Swift Testing tests include parameterized cases for every failed capture
or transform stage, concurrent inspection with and without sinks, reentrant
sinks, throwing sinks, deterministic context ordering, retained health,
secret-marker exclusion, immutable frozen facts, a controlled blocked callback
crossing the freeze boundary, and resource release. Existing heterogeneous and
non-Codable definition tests continue to pass with prepared fixtures.

- `scripts/check`: passes formatting, strict lint including public documentation,
  all 20 tests, and debug/release builds with warnings as errors on the selected
  Xcode 27.0 beta 6 / Apple Swift 6.4 toolchain.
- `scripts/coverage swiftpm macos`: passes and produces the discovered macOS
  JSON coverage report.
- `scripts/coverage ios`: passes the iOS 18 library build and all 20 tests on
  the iOS 27 simulator after the direct-Mutex amendment; `xccov` reads the
  result bundle.
- `scripts/coverage swiftpm linux`: passes all 20 tests, debug/release builds,
  and coverage discovery after the direct-Mutex amendment in the approved
  x86_64 image with Swift
  `6.4.2-dev (LLVM 15622a86b1749a9, Swift d2e983b81b18217)`.
- `xcrun vtool -show-build` confirms the compiled `DioramaCore.o` declares
  `minos 15.0` for macOS and `minos 18.0` for the iOS Simulator. These results
  establish the actual library deployment floors independently of the test
  framework's own build-version banner.
- Three external-client negative typechecks reject `[Int]` passed to a track,
  direct `PreparedValue<Int>(1)` construction, and a runtime `String` passed to
  `DiagnosticLabel`. They use `xcrun swiftc -typecheck -swift-version 6
  -target arm64-apple-macosx15.0 -I .build/out/Products/Debug <probe.swift>`
  after building the amended package.
- `git diff --check master` and local documentation link checks pass across the
  complete proposed change. The complete branch diff is reviewed against
  `master`, including staged and uncommitted changes.

Linux verification uses the approved image
`swiftlang/swift@sha256:15ae709b1d8eb1f8691b300f5721499d007e944694f2c0e9929a55580c9bf1a5`
with x86_64, two CPUs, and 4 GB in Apple Container. The repository is mounted
read-only; `Package.swift`, `Sources`, `Tests`, and `scripts` are copied into an
isolated container directory, where `scripts/coverage swiftpm linux` runs.

Hosted Quality, macOS, iOS, Linux, and all three Codecov uploads remain pending
the owner's authorization to push and create a PR. Local platform results do
not substitute for that required integration gate. No execution activation,
replay claims, random implementation, persistence, test-framework integration,
or later plan unit is included.
