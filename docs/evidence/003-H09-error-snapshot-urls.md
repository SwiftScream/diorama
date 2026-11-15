# 003-H09 — Preparatory shared error snapshot URLs

- Status: Complete; approved for a separate PR on 2026-11-15.
- Verified: 2026-11-15, macOS only.
- Base: `0f5e7e8`, immediately before the existing H09 implementation.
- Scope: The owner requests URL/NSURL support in the shared NSError snapshot
  and codec as a separate preparatory commit. The owner explicitly approves
  extending Location's unreleased version-one schema with the shared URL tag.
  The preparatory change remains separate from H09's URLSession failure wrapper.

## Behavior

`NSErrorSnapshotValue.url` stores a detached Foundation `URL` value, distinct from
an ordinary string. Capture accepts URL and NSURL values at every supported
nesting level, resolving their base through `absoluteString` and reparsing once.
Relative URLs without a base remain relative. Reconstruction supplies the stored
URL directly in a fresh NSError; it requires no parsing or failure branch and
does not retain a base object or URL subclass identity.

URL spellings share the existing 4,096-byte string limit and the 65,536-byte
combined budget. Capture and decoding parse with character repair disabled and
require the same spelling. Capture omits an unrepresentable or oversized entry
using the existing sorted key/type facts while retaining healthy siblings.
Explicit snapshots reject URL values with retained bases or excessive byte sizes;
decoded payloads reject malformed spellings and invalid bounds. Preparation and each
system's metadata policy remain separate responsibilities.

`NSErrorSnapshotPayload` uses `{"type":"url","value":"..."}`. The existing
Location adoption also supports this scalar; its version remains one under
[the owner's explicit unreleased-schema exception](../design-decisions/08-schema-compatibility.md#unreleased-url-value-extension--owner-approved-2026-11-15).
Existing tagged encodings and Location golden fixtures remain byte-exact.
Older development readers reject URL tags. No production dependency, native
adapter, public failure wrapper, or URLSession-specific metadata policy is added.

## Verification

With repository-selected Xcode 27.2 / Swift 6.4.2:

- `swift test --filter 'NSErrorSnapshot|LocationCodecTests' -Xswiftc -warnings-as-errors`
  passes the shared snapshot, payload, and Location codec suites (32 reported
  tests). Coverage includes URL/NSURL bridging, native failing-URL metadata,
  nested and relative URLs, base resolution and rejection of explicit retained
  bases, typed snapshot/payload values, exact percent escapes, string/URL
  distinction, byte boundaries and budget rollback, malformed tags, missing/null
  and wrong-type values, canonical re-encoding, and Location reconstruction.
- `scripts/check` passes formatting, strict lint, all eight host test products,
  coverage-export fixture checks, public system-authoring and lifecycle compiler
  probes, release builds, and the Random/Date usage examples.
- `git diff --check` and modified-document local link/anchor validation pass.

The first focused run exposes an invalid test assumption that Foundation accepts
an empty URL spelling; the case now proves rejection. The first canonical gate
finds a scalar-conversion complexity violation and nested-literal trailing-comma
violations. A focused URL conversion helper and simpler test literals resolve
these without changing any lint policy. The initial sandboxed build cannot write
the compiler cache; passing checks use approved normal cache access.

No local iOS, Linux, or new coverage collection is claimed. The PR's required
Quality, macOS, iOS, Linux, and coverage checks provide hosted verification before
merge; their results are retained with the PR.

## Review boundary

One preparatory commit contains the shared value and codec extension, Core and
Persistence tests, one Location integration test, updated contracts and decision
amendments, this evidence, and the owning-plan completion note. Its PR contains
only shared URL snapshot support. H09's URLSession
wrapper remains a separate review unit above this commit. PR creation is approved;
merge requires passing required checks and a separate owner request.

The owner approves replacing the string-backed URL case with `url(URL)`, squashing
the review update into this preparatory commit, and updating PR #131. The JSON
shape and URL spelling contract remain unchanged by this representation change.
