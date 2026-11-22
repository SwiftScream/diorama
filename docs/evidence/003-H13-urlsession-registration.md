# 003-H13 — URLSession registration and whole-record validation

The owner confirms H13 on 2026-11-20. The URLSession integration builds on the
Core and HTTP preparatory commits.
The [URLSession schema](../http-message-schema-v1.md#urlsession-registration-and-replay-setup)
defines the payload and the system authoring entry points.

## Registration and admission

The system type `diorama.urlsession` registers a version-one payload with one
ordered `interactions` array. Decoding and programmatic construction admit the
same typed HTTP interactions to one headerless track. The writer checks track
identity, value and header types, and the selected keyed preparation policy.
Resource resolution uses the enclosing scenario repository. The runtime
interaction owns its bytes before admission returns.

A system definition declares the schema's track and calls its validation hook
on the resolved baseline. The hook traverses each complete interaction in
record order before Core activates any dependency. It checks prepared values
in record and replay modes. In replay mode it also compares each required
behavior with the supplied bridge profile. Failed checks identify the record,
zero-based attempt, and affected field using safe diagnostic labels.

## Acceptance evidence

The [mixed scenario fixture](../../Tests/DioramaURLSessionTests/Fixtures/scenario.json)
includes Random, a URLSession attachment with three records, and an empty
URLSession attachment. It exercises pre-head failure, a followed redirect,
Digest authentication, a response decision, weighted body segments with edited
timing, trailers, and an open operation. Rebuilding it through the public
builder reproduces its canonical JSON byte for byte.

The [registration tests](../../Tests/DioramaURLSessionTests/URLSessionRecordingSchemaTests.swift)
exercise version dispatch, strict decoding with deep field paths, independent
keyed credential policies, owned resource resolution after body edits, and
missing-resource refusal. An actual Core startup attempt withholds trailer
support. It reports the second interaction's third attempt and never runs its
dependency factory. Record and passthrough setup also run with an empty
replay profile.

The [branch tests](../../Tests/DioramaURLSessionTests/URLSessionBranchAdmissionTests.swift)
exercise modified and refused redirects, pending decisions, proxy Basic
authentication, inherited or replaced requests, failed and open prefixes,
and observed disposition cancellation, including dispositions under a refused
redirect. Removing each required capability from
a supplied profile causes admission to fail. Native bridge profiles and
callback conformance belong to Phase I.

## Capability API review update

Replay admission uses its typed capability profile to require
`.responseDecision` for every recorded disposition and
`.dispositionCancellation` for a recorded cancel. Admission tests cover
direct and nested dispositions, including an allow with decision gating
and no cancellation support.

All 11 focused admission tests and the canonical macOS gate pass for this
fixup, including 830 tests across nine host products.

## Local verification

All 11 focused H13 tests pass with warnings treated as errors. The canonical
macOS `scripts/check` passes on Xcode 27.2 and Swift 6.4.2 with 826 tests
across nine host products, zero format and lint violations, coverage-tool
fixtures, compiler probes, release builds, and the Random and Date examples.

On the iPhone 17 simulator running iOS 27.2, `scripts/coverage ios` passes
the release build, all nine test products, lifecycle compiler probes, and
LCOV export before the final nested-decoding diagnostic edit. The final source
passes the affected HTTP suite (157 tests) and URLSession suite (31 tests),
including the new malformed-value path test.

An early pinned Linux run stops during test compilation. The H12 revision used
for that run names `becomeDownload` in a native disposition test, which
FoundationNetworking deprecates and the strict build treats as an error.
All 11 H13 tests pass with warnings treated as errors in the same pinned
x86_64 Linux image. That focused run uses a temporary copy containing only
the URLSession test target and omits the H12 native disposition test file.

## Decoder diagnostic review update

HTTP decoders attach coding paths where they recognize malformed bodies and
fields. `HTTPTimed` propagates errors from the embedded decoder. URLSession
reports unsupported failure versions at `version`, and the shared snapshot
decoder reports invalid metadata at `userInfo` using the schema key. Tests
cover field paths in individual codecs and through versioned registration,
along with the unavailable-resource error category.

All 169 HTTP tests and 17 focused URLSession tests pass. The canonical macOS
`scripts/check` passes with 841 tests across nine host products.

## Three-commit review revision

The Core startup suite passes all seven tests, including both diagnostic
rejection paths before dependency construction. All 167 HTTP tests pass,
including the added nested coding-path and missing-resource regressions. All
11 focused URLSession admission tests pass. The canonical macOS `scripts/check`
passes with 838 tests across nine host products and zero format or lint
violations.

## Startup validation review update

URLSession and consumer-defined systems can supply a diagnostic for an error
thrown by the startup validator using
`SystemValidationContext.validate(_:using:diagnosticForFailure:)`. Core records
the diagnostic and throws `PreparationFailure`. A factory that returns `nil`
uses the same track-level diagnostic as the two-argument overload.
`DiagnosticLabel(index:)` represents a numeric position in a schema field path.

All seven focused Core startup tests and 11 focused URLSession admission tests
pass. The canonical macOS `scripts/check` passes with 838 tests.
The external system-authoring compiler probe uses both public APIs.

## Request target and capability diagnostic review update

Admission checks that each recorded request can form a URL with a nonempty
host. The builder and registered reader reject refused redirect proposals
with missing authorities, missing paths, or hostless URLs. Both admit a
proposal with percent-encoded path and query components.

Replay startup includes the absent capability's fixed label in the diagnostic
rule. Withholding response-decision support or disposition cancellation from
the same recording produces distinct rules at the same attempt and field path.

All 13 focused admission tests pass. The canonical macOS `scripts/check`
passes with 843 tests and zero formatting or lint violations.

## Public preparation policy review update

`HTTPFieldRedactionPolicy.validatePrepared(_:)` lets consumer systems validate
standalone prepared fields such as trailers using their configured rules.
URLSession uses that method for fields and the public typed preparation APIs
for authentication challenges and credentials.

All 26 focused HTTP preparation and URLSession admission tests pass. An
external Swift module compiles a call to the public field validator. The
canonical macOS `scripts/check` passes with 843 tests.

## Shared response-node validation review update

The preparatory HTTP commit requires a final response head in each
`HTTPResponseNode`. Standalone `HTTPResponseHead` values can represent
informational statuses. The interaction decoder identifies an informational
node at `head.value.status`, and the registered URLSession decoder preserves
that path through the scenario envelope.

All 41 focused lifecycle, Content-Length, and URLSession admission tests pass.
The canonical macOS `scripts/check` passes with 844 tests.
