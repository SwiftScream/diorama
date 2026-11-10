# 003-H06 — Weighted body allocation and local timing

- Date: 2026-11-11
- Status: Complete; the owner authorizes PR creation on 2026-11-13.
- Owning unit: [003-H06](../plans/003-clean-slate-implementation.md#003-h06--weighted-body-allocation-and-local-timing)
- Base: `master` at `dbb635c` (merged H05).
- Contract: [Weighted delivery and local timing](../http-message-schema-v1.md#weighted-delivery-and-local-timing).

## Delivered behavior

The owner confirms the proposed scope, GPT-6 Sol / `high` reasoning, and stacked
base on 2026-11-11 before implementation. H06 remains a separate review unit.

`HTTPBodySegment` owns a nonnegative `Int64` byte weight and a successive
`HTTPDelay`. `HTTPBodyProfile` validates a nonempty ordered sequence with checked
weight and effective millisecond sums. Both sums must fit `Int64`. Omission of
an optional profile differs from an explicit empty profile, which is invalid.
Zero-weight deliveries retain their timing position, including for empty bodies.

Allocation uses exact cumulative integer proportions rounded down. A nonfinal
boundary is `floor(currentByteCount * cumulativeWeight / totalWeight)`; the
final boundary is the current byte count. `Int128` holds the full product of
every supported `Int` length and `Int64` weight. There is no floating-point
rounding or multiplication overflow. Each allocation exposes a contiguous range,
its effective successive delay with authorship, and its offset from the head.
The final segment absorbs the remainder. All-zero profiles assign a nonempty
edited body entirely to the final segment.

Unchanged observed weights reproduce their original byte boundaries. Edited
lengths scale ranges without rewriting weights, duplicating bytes, decoding text,
or requiring UTF-8 boundaries. The resolver supplies a resource's current length;
this unit performs no resource I/O. Derived ranges cover exactly that length and
are never persisted. The same allocation applies to inline and resource bytes.

Profiled body construction accepts only bytes/resources and stores them in
strict internal cases. Its public `content` and `profile` views are read-only.
Absent/unavailable bodies cannot acquire profiles. All three body conclusions
support profiles, including failed/open prefixes and completion-only trailers.

Cumulative timing validates segments, then the conclusion, then the head. The
existing `HTTPBodyCompletion` and `HTTPResponseNode` builders now throw on
overflow. The complete observed invocation-relative timeline must fit
`0...Int64.max` milliseconds. Open work contributes no synthetic terminal delay.
Already-validated local components remain immutable; no runtime scheduler or
application decision latency enters these values.

Diorama-owned codecs add optional `segments` to bodies and reject invalid fields,
weights, timing sums, and profile placement before runtime use. Observed-plus-
override editing forms select one effective override before cumulative checks.
Canonical output retains only segment weights and effective successive delays.
Path-specific structural errors omit body and adapter-failure content.
Existing unprofiled H05 goldens remain byte-for-byte identical.

No dependency, manifest, platform floor, concurrency exception, warning policy,
resource publication, native adapter, or replay-engine change is needed.

## Behavioral evidence

Fourteen new public-import test functions, including parameterized cases, prove:

- Eighteen independent allocation goldens: unchanged/edited lengths, rounding
  boundaries, trailing/interior zeros, all-zero/empty content, and full-width
  integer products without allocating enormous bodies.
- Exhaustive small three-segment allocations across 25 weight combinations
  and 17 effective lengths, including contiguous bounds and empty deliveries.
- Exact original boundaries and byte concatenation across split UTF-8 and binary
  prefixes, with no text decoding or alternate byte authority.
- Canonical timed profile encoding, resource/inline equivalence under length
  edits, all body conclusions, trailers, and observed/override normalization.
- Builder and decoder rejection of absent/unavailable profiles, negative and
  invalid weights, missing/null/unknown fields, empty profiles, and overflowing
  weight/delay sums; inclusive integer limits remain valid.
- Cumulative head/segment/trailer/completion/failure timing and safe nested
  decoding paths, including an open profile at the maximum timing boundary.

The existing thirteen H05 lifecycle tests retain their assertions and fixtures.
The documented message, lifecycle, and weighted-profile examples type-check as
one external consumer with Swift 6 complete concurrency checking and compiler
warnings treated as errors.

## Verification

- Toolchain: Xcode 27.2 (`27B52`), Apple Swift 6.4.2
  (`swiftlang-6.4.2.1.9`), arm64 macOS host.
- `swift test --filter 'HTTPBodyProfileTests|HTTPLifecycleTests' -Xswiftc -warnings-as-errors`
  passes all 27 focused test functions, including parameterized cases.
- `scripts/check` passes formatting, strict lint, all 678 host tests,
  debug/release warning-as-error builds, public compiler probes, coverage-export
  fixtures, and compiled usage examples.
- `scripts/coverage swiftpm macos` passes 678 tests in a fresh build, release
  and example builds, compiler probes, and LCOV export.
- `scripts/coverage ios` passes 677 tests in a fresh iPhone 17 / iOS 27.2
  Simulator build, release compilation with the iOS 18 deployment floor,
  public lifecycle compiler probes, and LCOV export. This does not establish
  execution on an actual iOS 18 runtime.
- Before the review extraction below, all four affected HTTP source files have
  full executable-line coverage on both platforms: `HTTPBodyProfile.swift` 68/68,
  `HTTPDelay.swift` 34/34,
  `HTTPLifecycle.swift` 52/52, and `HTTPLifecycle+Codable.swift` 139/139;
  combined 293/293 lines. Coverage comes from the current fresh builds.
- The first three Swift blocks in the public schema document type-check
  together through `swiftc -typecheck -swift-version 6 -strict-concurrency=complete -warnings-as-errors`,
  using the current debug modules and a task-owned module cache.
- Local Linux is unavailable: `container system status` reports
  “apiserver is not running and not registered with launchd.” No Linux execution
  or hosted CI result is claimed.
- V-doc: all local file links in the changed documents resolve, the new section
  anchors match their headings, and the complete H06 diff passes
  `git diff --check`.

The first sandboxed Swift invocation cannot write the normal module cache;
the successful gates use normal tool/cache access. The first focused run catches
the hand-authored fixture's empty-array whitespace, which is corrected to match
the canonical writer. Strict lint catches two long lines, which are corrected
before the canonical gate. Xcode retains its existing no-AppIntents metadata
extraction notices; there are no Swift compiler or linter warnings. No quality
policy or production behavior is weakened to pass verification.

## Review update — 2026-11-13

Move `HTTPLifecycleError` unchanged from `HTTPDelay.swift` into its own file,
reflecting its shared use across delay, profile, allocation, and lifecycle
validation. The owner requests direct amendment into the H06 commit.

The 27 focused HTTP tests and `scripts/check` pass on macOS, including all 678
host tests, strict formatting/lint, compiler probes, and release/example builds.
The initial sandboxed attempts cannot write tool caches; successful reruns use
normal cache access. `git diff --check` passes. No additional iOS or Linux
validation runs for this review update, as requested by the owner.

## Review unit

One coherent implementation commit contains the model and strict codec changes,
public-import tests, independent allocation and canonical profile fixtures,
public schema documentation, documentation navigation, owning-plan status, and
this evidence. The complete H06 diff is against `dbb635c`, excluding H01–H05.
The owner authorizes PR creation on 2026-11-13 after reviewing the unit.
The PR targets `master` following H05's merge. Required PR checks enforce quality,
macOS/iOS/Linux execution, and Codecov results before separately authorized merge.

Changed files:

- `Sources/DioramaHTTP/HTTPBodyProfile.swift`: segments, validated profiles,
  deterministic allocation, and derived immutable range/timing values.
- `Sources/DioramaHTTP/HTTPDelay.swift`: checked local timing sums.
- `Sources/DioramaHTTP/HTTPLifecycleError.swift`: shared safe structural
  validation errors for delays, body profiles, allocation, and lifecycle construction.
- `Sources/DioramaHTTP/HTTPLifecycle.swift`: strict profiled body storage and
  cumulative construction checks through completion and response boundaries.
- `Sources/DioramaHTTP/HTTPLifecycle+Codable.swift`: owned profile encoding,
  validation-only reading, and cumulative failure paths.
- `Tests/DioramaHTTPTests/HTTPBodyProfileTests.swift`,
  `Fixtures/body-allocations.json`, and `Fixtures/body-profile.json`: allocation,
  lifecycle, editing, overflow, malformed-input, and canonical encoding evidence.
- `docs/http-message-schema-v1.md`, `docs/README.md`, the owning plan, and this
  evidence: public contract, navigation, status, verification, and review boundary.
