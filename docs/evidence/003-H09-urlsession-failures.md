# 003-H09 — Snapshot-backed URLSession failures

- Status: Complete; the owner approves the implementation, source consolidation,
  squashing, and PR creation on 2026-11-15.
- Verified: 2026-11-15, macOS only.
- Base: Shared URL snapshot preparatory commit `cab2519`; complete branch review
  starts at `0f5e7e8`, including that separate preparatory commit.
- Scope: The owner approves retaining a thin snapshot-backed failure value and
  removing URLSession-specific code-name, reason, URL-alias, and key-policy logic.
  Adapter-specific metadata policy is deferred until the concrete system needs it.
  Capture and Codable implementation are consolidated into `URLSessionFailure.swift`.

## Delivered boundary

`DioramaURLSession` supplies `URLSessionFailure` as the concrete failure parameter
for shared HTTP lifecycle values. It stores only Core's validated
`NSErrorSnapshot`; public identity accessors and `init(domain:code:)` remain.
Native capture, supported metadata conversion, limits, and fresh reconstruction
all use that shared helper. `makeError()` returns `any Error` and explicitly wraps
URL-domain NSError values in `URLError(_nsError:)`; other domains remain NSError.
This ensures native URL error casts work without platform-specific automatic
bridging. The codec wraps `NSErrorSnapshotPayload` in a strict
version-one `version`/`error` object. No separate failing URL or recognized name
is stored or derived. No key-specific reason properties, alias rules, or
URLSession-specific metadata allowlist remain.

The product/target and public-import test target remain. Production dependencies
are Core and Persistence; HTTP composition is exercised by tests. No new dependency,
interception, session construction, or forwarding engine is added. The value,
capture/preparation, native reconstruction, Codable conformance, and construction
errors live together in `URLSessionFailure.swift`. The consolidation only groups
the implementation; the subsequent Linux CI fix changes `makeError()` from
NSError to `any Error` to preserve the native error type. H09 changes no production
sources in HTTP, Core, or Persistence.

The [component contract](../urlsession-failure-schema-v1.md) describes approximate
round trips of domain/code and supported nested metadata, including native URLs.
Every error domain uses the shared structural rules. Supported strings, including
explicit description entries, survive by default. Preparation owns redaction;
serializability does not establish confidentiality. Tests demonstrate editing a
reconstructed NSError and recapturing it during preparation while preserving
healthy sibling metadata and leaving the original live error unchanged.

Unsupported objects, underlying errors, and unrepresentable values are omitted
with sorted key/type-only facts and no recording-health impact. Unrepresentable
domains or failed preparation retain safe unhealthy evidence. Edited persistence
is strict, with no omission leniency. Native delivery, cancellation provenance,
and the final URLSession metadata policy remain I03 adapter work under
[DD17's explicit amendment](../design-decisions/17-http-lifecycle-composition.md#snapshot-backed-failure-foundation--owner-approved-2026-11-15).

## Verification

With repository-selected Xcode 27.2 / Swift 6.4.2:

- `swift test --filter 'URLSessionFailure|NSErrorSnapshot' -Xswiftc -warnings-as-errors`
  passes both H09 suites and the shared snapshot/codec suites (25 reported tests).
  Public imports exercise known and unknown codes, nested metadata in URL and
  non-URL domains, native URL/URLError reconstruction, explicit description
  retention, healthy omissions without rendering objects or values, preparation
  ordering, validation-only admission, original-error preservation, strict
  persisted fields/tags/bounds, and byte-exact canonical fixture re-encoding.
- Generic `HTTPInteraction<URLSessionFailure>` round trips preserve both
  pre-response and response-owned partial-body failures. A received 503 stays a
  response; only its explicit failure leaf denotes transport failure.
- `scripts/check` passes formatting, strict lint, all nine host test products,
  coverage-export fixture checks, public system-authoring and lifecycle compiler
  probes, release builds, and Random/Date usage examples. No warning or lint
  exception is added. Checks use approved access to normal compiler/tool caches.
- Complete proposed-diff whitespace and modified-document local links/anchors
  pass validation.

Linux CI on the original H09 revision identifies one failure at
`URLSessionFailureTests.swift:51`: casting the reconstructed NSError to URLError
returns nil after its domain, code, URL, and metadata checks pass. The
[failed job](https://github.com/SwiftScream/diorama/actions/runs/43712197347/job/132805996810)
demonstrates the automatic-bridging assumption. The fix explicitly constructs the
native URL error in production. The test retains its native cast and also checks
non-URL NSError delivery, unknown numeric-code retention, and recapture of the
hydrated error into an equal stable value. It does not skip Linux or weaken the
native type assertion.

The [hosted Linux rerun](https://github.com/SwiftScream/diorama/actions/runs/43716491386/job/132819054778)
passes the native hydration fix, including tests, coverage collection, and the
Codecov upload. This evidence precedes the owner-approved history squash; the
production and test code remain identical after that rewrite.

No local iOS, Linux, or new coverage collection is claimed. Required PR Quality,
macOS, iOS, Linux, and coverage checks provide hosted verification before merge;
their results are retained with the PR. Native URLSession conformance remains
outside this unit.

## Review and commit boundary

The separate preparatory commit `cab2519` extends shared snapshots and their codec
with native URLs in PR #131. The owner approves squashing H09's review updates,
including consolidation into the primary source file, into its implementation
commit on 2026-11-15. On 2026-11-16, the owner also approves squashing the native
error hydration correction into H09. PR #132 targets master after the prerequisite
merges; its diff contains one H09 commit. The shared Core helper remains unchanged
by this correction.

Review the remaining H09 diff against `cab2519`, or the complete stack against
`0f5e7e8`. Tests, fixture, component contract, decision amendment, architecture/index
descriptions, and owning-plan scope describe the final contract. PR creation is
approved; merge requires passing required checks and a separate owner request.
