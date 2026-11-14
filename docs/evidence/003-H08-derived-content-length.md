# 003-H08 — Derived Content-Length and exact body edits

- Status: Complete; owner review is the next checkpoint.
- Verified: 2026-11-15.
- Base: H07A at `4f7b1b4`; this branch is stacked above its review branch.

## Implemented contract

The owner confirms H08's scope and the plan's GPT-6 Sol / `medium`
recommendation before implementation. This unit adds no dependency or native
adapter. DD11/DD17 govern the new explicit field value and exact-byte behavior.
The [public schema](../http-message-schema-v1.md#derived-content-length)
documents the API and persistence contract.

`HTTPContentLength.request` and `.response` accept prepared values and explicitly
select a derived length only after confidentiality transforms and normalization.
Response selection requires the effective request method and a successful body
conclusion. Ordinary builders and codecs preserve literals; encoding does not
infer a derived field from an authored value merely because it equals body size.

Proof requires one decimal Content-Length equal to a present complete body's
byte count. Empty bytes count as zero; absent/unavailable content does not.
Repeated values, signs, lists, overflow, mismatches, HEAD/CONNECT methods,
informational and 204/205/206/304 responses, and all encoding/transfer/range fields
conservatively retain literals. Failed/open responses never derive a length.

The strict field codec accepts `{ "derivedFrom": "bodyByteCount" }` only as the sole
Content-Length. Request decoding resolves against its current inline/resource
body. Response-node decoding reads the body first, requires completion, resolves
the timed head, and validates semantics before constructing the node. Interaction
encoding and decoding additionally reject derived response lengths for HEAD and
CONNECT requests. Standalone response heads cannot decode a derived marker
without the owning body and reject it. No unresolved numeric placeholder enters
the runtime model.

The runtime head contains the decimal length; `derivesContentLength` retains
persistence intent. Request storage selection preserves that intent. Rebuilding
with the ordinary head/message initializer authors literal fields, including a
deliberate mismatch. Existing literals, field bytes/order, exact body spelling,
validators, and signatures remain unchanged. Resource bytes still use H07's
explicit resolution and owned-byte contract. No JSON parsing, pretty printing,
transcoding, validator regeneration, or new persistence version is introduced.

## Verification

On repository-selected Xcode 27.2 / Swift 6.4.2:

- Eight focused public-import tests pass. They exercise proof exclusions,
  prepared-body changes before proof, storage selection, explicit marker
  validation, literal preservation, request and response edits across UTF-8 text,
  opaque base64, and owned typed resources, successful completion, standalone
  head rejection, and edited response profile allocation. Independently authored
  body fragments retain duplicate JSON names, number spellings, and whitespace.
  Existing resource/body-profile suites supply their publication and allocation
  regression coverage.
- Final `scripts/check` passes strict format/lint, all eight host test products
  (733 tests), coverage-export fixture checks, public authoring compiler probes
  (one positive/seven negative), public lifecycle probes (one positive/eleven
  negative), release builds, and compiled Random/Date usage examples.
- `git diff --check` passes; modified documentation file links resolve.

Initial test compilation corrects HTTP Types collection construction and field
names. Lint finds test formatting, forced-try, and Data-to-String conversions;
these are corrected before the passing gate. The first sandboxed build cannot
write compiler caches; successful runs use approved normal cache access. No
compiler/linter warning is waived.

No iOS, Linux, new coverage collection, or hosted CI result is claimed. Required
PR checks must pass before merge; PR creation and merge require separate owner
authorization. Native materialization and future redirect/authentication edges
remain adapter/later-unit work and must supply their effective method context.

## Review boundary and commit

The initial coherent commit contains selection, strict field coding and contextual
resolution, exact-byte editing tests, the storage-marker integration correction,
public documentation, this evidence, its index link, and owning-plan completion:

`003-H08: feat(http): derive proven content lengths from body bytes`

The complete review diff is against `4f7b1b4` and excludes H07A. Review the public
selection API, conservative exclusion set, persisted marker, and standalone
response-head decoding limitation. H09 does not start automatically.

## Review update — derived field spelling

On 2026-11-15, the owner approves replacing the boolean marker with
`{ "derivedFrom": "bodyByteCount" }`. The codec writes and reads this exact
form; unknown sources, non-string sources, extra keys, and the earlier boolean
form fail decoding. The approved spelling is recorded in
[DD17's amendment](../design-decisions/17-http-lifecycle-composition.md#derived-field-spelling--owner-approved-2026-11-15).

Tests verify the exact encoded shape, rejection of malformed markers in requests
and responses, preservation of field order and repeated neighbors, and literal
strings such as `"auto"` and `"bodyByteCount"`. Existing proof and edited-body
tests continue to pass. The focused macOS run passes all eight tests, and
`scripts/check` passes all eight host products (733 tests), strict format/lint,
compiler probes, release builds, coverage-export fixtures, and usage examples.
The current gate's actual count corrects the initial evidence's 832-test total.
An overlong test-fixture line is corrected before the passing gate.

The owner approves this review update and its squash on 2026-11-15. The final
H08 commit includes the marker spelling change. Full platform verification
remains with CI.

## Review update — body byte-count ownership

On 2026-11-15, the owner requests moving `byteCount` from extensions in
`HTTPContentLength.swift` directly into `HTTPRequestBody` and `HTTPResponseBody`
in `HTTPBody.swift`. The implementations and internal visibility are unchanged:
absent/unavailable content has no count, present empty bytes count as zero, and
inline or owned resource bytes supply their exact count.

All eight focused Content-Length tests and the canonical macOS `scripts/check`
gate pass, including 733 tests across eight host products, strict format/lint,
compiler probes, release builds, coverage-export fixtures, and usage examples.
The owner approves the relocation and its squash into H08 on 2026-11-15.
Full platform verification remains with CI.

## Review update — readable ASCII digit bounds

On 2026-11-15, the owner selects a named `asciiDigits` range using
`UInt8(ascii: "0")...UInt8(ascii: "9")` in the Content-Length proof. The check
uses `bytes.allSatisfy(asciiDigits.contains)` with unchanged ASCII-only decimal
semantics. All eight focused Content-Length tests and the canonical macOS
`scripts/check` gate pass, including 733 host tests, strict format/lint,
compiler probes, release builds, coverage-export fixtures, and usage examples.
The owner approves this review update and its squash into H08 on 2026-11-15.

## Review update — complete immutable message construction

On 2026-11-15, the owner approves internal complete-state initializers for
`HTTPRequestMessage` and `HTTPResponseHead`, with `derivesContentLength` stored
as `public let`. Existing public initializers delegate with literal intent.
Request head validation remains in the internal head/body initializer. A small
internal initializer copies an already validated request when only its
derivation intent changes, preserving the nonthrowing request-selection API.

Storage selection, length selection, decoding, and response-node resolution now
construct complete values without subsequent flag assignments. Existing proof,
contextual validation, field preservation, and public initializer signatures
remain unchanged. The 55 focused message, Content-Length, storage, and lifecycle
tests pass. The canonical macOS `scripts/check` gate also passes all 733 host
tests, strict format/lint, compiler probes, release builds, coverage-export
fixtures, and usage examples. The owner approves this review update and its
squash into H08 on 2026-11-15; full platform verification remains with CI.
