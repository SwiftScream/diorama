# 003-H05 — Strict HTTP response/body/failed/open lifecycle

- Date: 2026-11-08
- Status: Complete; owner review is approved and local verification is recorded below.
- Owning unit: [003-H05](../plans/003-clean-slate-implementation.md#003-h05--strict-responsebodyfailedopen-lifecycle)
- Base: `feat/003-h04-http-matching` at `e3f50b6`.
- Contract: [Strict lifecycle components](../http-message-schema-v1.md#strict-lifecycle-components).

## Delivered behavior

The owner confirms the scope and recommended GPT-6 Sol / high reasoning setting
before implementation. The isolated H05 branch is stacked on H04.

`HTTPInteraction<Failure>` owns the initial request and one attempt result.
Received responses own one timed head and one body delivery. Body delivery owns
exact content once and one returned, failed, or explicit-open conclusion. There
is no independent root conclusion. Failure before a head differs from failure
after an observed prefix. HTTP 4xx/5xx can return successfully. Open work has no
terminal timing or synthetic completion. Failures remain typed adapter values;
the tests supply a synthetic enum without introducing a transport taxonomy.

Only successful body completion can own trailers. Trailer fields share the
message codec, preserving ordered repetitions, original name spelling, and exact
bytes. Body content reuses the absent/empty/bytes/resource/unavailable model and
the lossless text/base64 codec, including partial UTF-8 prefixes. Unavailable
content does not imply absent or empty bytes; native replay support remains a
separate capability question.

Immutable public builders compose already validated components. Result enums
make contradictory leaves and failed/open trailers unconstructable. `HTTPDelay`
validates nonnegative effective millisecond timing, reuses shared duration
scalars and observed/override normalization, and preserves authorship.
Diorama-owned tagged readers reject missing/null/unknown/conflicting fields at
each lifecycle boundary. Invalid delays and unknown lifecycle tags have coding
paths and safe descriptions without their supplied values.

This is DD17's response/body foundation. Weighted profiles and allocation belong
to H06. Redirect, authentication, and disposition nodes belong to H10–H12;
there are no placeholder cases. Resource I/O, capture/replay execution, native
failure conversion, capability validation, system registration, and system
version dispatch remain assigned to their later units. No dependency, manifest,
unsafe-concurrency annotation, warning suppression, or platform-floor change is
needed.

## Behavioral evidence

Thirteen public-import test functions, including parameterized cases, cover:

- A canonical nine-interaction fixture with complete success, pre-head
  failure/open, partial body failure/open, trailers, and every content form.
- Successful 404 and 503 delivery, typed failures with and without a response,
  exact binary/partial UTF-8 prefixes, and no synthesized completion for open work.
- The cross-product of all five content representations and all three body
  conclusions, with explicit ownership assertions and round trips.
- Ordered repeated trailers and raw field bytes, absent versus empty trailers,
  completion-only placement, and malformed trailer fields.
- Builder rejection of negative delays, zero and `Int64.max`, observations and
  overrides, canonical scalar spelling, and effective-override normalization.
- Missing/null/unknown fields at every new object boundary, conflicting and
  unknown result/conclusion tags, invalid timing, and nested diagnostic paths.

The documented public builder example also type-checks against the built modules
with Swift 6 complete concurrency checking and warnings as errors.

## Verification

- Toolchain: Xcode 27.2 (`27B52`), Apple Swift 6.4.2
  (`swiftlang-6.4.2.1.9`), arm64 macOS host.
- `swift test --filter HTTPLifecycleTests -Xswiftc -warnings-as-errors` passes
  all thirteen focused test functions.
- `scripts/check` passes formatting, strict lint, host tests, debug/release
  warning-as-error builds, public compiler probes, coverage-export fixtures,
  and compiled usage examples.
- `scripts/coverage swiftpm macos` passes fresh-build host tests, release/example
  builds, compiler probes, and LCOV export. New lifecycle source coverage is
  167/167 executable lines (100%).
- `scripts/coverage ios` passes the fresh iPhone 17 / iOS 27.2 Simulator suite,
  release build, lifecycle compiler probes, and LCOV export with the iOS 18
  deployment floor. New lifecycle source coverage is 167/167 executable lines
  (100%). This does not establish execution on an actual iOS 18 runtime.
- Local Linux is unavailable: `container system status` reports “apiserver is not
  running and not registered with launchd.” No Linux execution is claimed.
- V-doc: all 304 local file links in the changed documentation resolve, the new
  section anchors match their headings, and the complete H05 diff passes
  `git diff --check`.
- Required PR checks enforce formatting/lint, macOS, iOS, Linux, and Codecov
  verification before merge.

The first sandboxed Swift invocation cannot write the standard module cache;
verification uses normal cache access. Initial tests expose a test-builder reason
phrase mismatch: HTTP Types numeric status construction leaves the phrase empty,
while named status constants preserve the fixture's phrase. The tests use named
constants. Initial lint catches line lengths and Data-to-String conversion in
test helpers; these are corrected before the canonical gate passes. No production
behavior or quality policy is weakened to pass checks.

## Review unit

One coherent implementation commit contains the strict model, shared trailer
codec reuse, tagged codecs, public-import tests, golden fixture, public schema
documentation, documentation index, plan status, and this evidence. The complete
H05 diff is against `e3f50b6`, excluding the prerequisite H01–H04 stack. The owner
approves review and authorizes stacked PR creation on 2026-11-11, with H05 targeting
H04. Merge requires passing required PR checks and a separate explicit owner request.

Changed files:

- `Sources/DioramaHTTP/HTTPDelay.swift`: validated successive delays and timed values.
- `Sources/DioramaHTTP/HTTPLifecycle.swift`: strict public lifecycle components.
- `Sources/DioramaHTTP/HTTPLifecycle+Codable.swift`: owned tagged codecs and trailers.
- `Sources/DioramaHTTP/HTTPMessage+Codable.swift`: module-internal field payload
  shared with trailers; existing message encoding stays identical.
- `Tests/DioramaHTTPTests/HTTPLifecycleTests.swift` and `Fixtures/lifecycle.json`:
  public API behavior, rejection cases, and canonical schema evidence.
- `docs/http-message-schema-v1.md`, `docs/README.md`, the owning plan, and this
  evidence: public contract, navigation, completed local status, and review boundary.
