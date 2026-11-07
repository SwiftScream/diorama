# 003-H02 — Shared HTTP message values

- Date: 2026-11-08
- Status: Complete; stacked PR creation is owner-authorized on 2026-11-08.
- Owning unit: [003-H02](../plans/003-clean-slate-implementation.md#003-h02--shared-message-heads-fields-and-body-values)
- Contract: [HTTP message schema components](../http-message-schema-v1.md)
- Base: `docs/003-h01-http-types-adoption` at `51c52da`.

## Delivered behavior

The owner confirms scope and authorizes commencement on 2026-11-07. The optional
`DioramaHTTP` product adopts only the approved `HTTPTypes` product using
`from: "1.8.0"`; local resolution selects 1.8.0. No HTTP dependency enters Core,
and no URLSession target or Foundation conversion product is introduced.

Immutable request messages and response heads use HTTP Types currency. Separate
body enums make response-only unavailable content impossible in requests.
Resource references validate literal relative paths without I/O. Request heads
reject unsupported extended CONNECT and non-UTF-8 target bytes before encoding.

Owned Codable shapes preserve method and target text, status and reason phrase,
ordered repeated fields, original field-name spelling, raw field bytes, and
absent/empty/resource/unavailable distinctions. Strict readers reject unknown
keys at every object level, malformed names/values, invalid bytes/status ranges,
and contradictory tagged bodies. Header value strings use a documented Latin-1
scalar-to-byte mapping, so invalid UTF-8 header bytes still round-trip exactly.
There is no native HTTP wrapper, invented protocol version, live network access,
resource loading, or dependency-owned Codable in the stable contract.

These component codecs are intended for the future version-one HTTP payload;
they do not introduce a standalone document version or bypass H13 registration
and version dispatch. H05 owns lifecycle conclusions, H07 owns resource
publication, and H08 owns derived Content-Length. Existing direct builders and
the golden fixtures require no native adapter.

## Initial implementation verification

Host: arm64 macOS with the selected Xcode 27.2 / Swift 6.4.2 toolchain, macOS 15
and iOS 18 deployment floors. Commands use repository strict concurrency and
warnings-as-errors settings.

- `swift package resolve`: selects the approved release 1.8.0.
- `swift test --filter HTTPMessageTests -Xswiftc -warnings-as-errors`: passes
  the focused value/codec suite.
- `scripts/check`: passes strict formatting/lint, all host test suites,
  consumer compilation/lifecycle probes, debug/release builds, and examples.
- `scripts/coverage swiftpm macos`: passes the fresh-build full host suite,
  release/examples checks, compiler probes, and LCOV export. New HTTP source
  line coverage is 129/130 (99.23%) on both macOS and iOS. The unexecuted line
  rejects non-UTF-8 request target bytes.
- `scripts/coverage ios`: passes the full iPhone 17 / iOS 27.2 Simulator suite,
  release build, lifecycle compiler probes, and LCOV export with deployment
  target iOS 18. This does not prove execution on an iOS 18 runtime.
- Final focused iOS rerun: `xcodebuild test -scheme Diorama-Package
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=27.2'
  -derivedDataPath /tmp/diorama-h02-final-ios -only-testing:DioramaHTTPTests
  IPHONEOS_DEPLOYMENT_TARGET=18.0 SWIFT_TREAT_WARNINGS_AS_ERRORS=YES
  SWIFT_SUPPRESS_WARNINGS=NO` passes all eight HTTP tests with the final
  all-body golden fixture.

The first iOS gate fails because Xcode gives external package targets
`-suppress-warnings` while the canonical gate requires `-warnings-as-errors`.
The iOS command now explicitly sets `SWIFT_SUPPRESS_WARNINGS=NO`, retaining
warnings-as-errors for both Diorama and upstream targets. No warning exception
or suppression is added. SwiftLint explicitly excludes the generated
`Examples/.build` and `Examples/.swiftpm` directories so subsequent gates do not
lint upstream dependency checkouts. Repository source checks remain enabled. Initial test-builder compilation and line-length lint
failures are corrected before the passing host gate. The new all-body golden
initially differs from Foundation's pretty-printed empty-array whitespace; the
fixture is corrected to the encoder's output. An overlapping first coverage run
snapshots resources before that new fixture exists; final verification uses a
fresh build with all fixtures present.

Local Linux execution is unavailable: `docker info` reports no daemon socket at
`/var/run/docker.sock`. No Linux behavior, hosted CI, or Codecov upload is claimed.
The required macOS/iOS/Linux CI matrix must pass on the owner's authorized PR
revision before integration. This local review does not authorize pushing,
creating a PR, merging, or starting H03.

V-doc passes: all 295 local file links in the changed documentation resolve;
new section links match their headings; the complete H02 diff against `51c52da`
passes `git diff --check`.

## Review unit

One coherent feature commit contains the manifest, shared values/codecs,
public-consumer tests and goldens, documentation/plan evidence, and the required
iOS warning-setting and generated-directory lint corrections. It is stacked on the H01 adoption record;
the H02 diff is measured against `51c52da`, excluding H01's separate review unit.


## Review update — base64 inline bodies, 2026-11-08

The owner requests a base64 string instead of numeric byte arrays for persisted
inline bodies. The owned shape is now `{"kind":"bytes","base64":"AID/"}`;
empty inline content uses `""`. In-memory request and response body APIs continue
to carry exact `[UInt8]` values. This is an encoding change within the unreleased
version-one components, so no compatibility reader or version increment is added.

Foundation performs base64 conversion. Readers require the standard alphabet,
canonical padding and unused bits, and no whitespace; malformed or noncanonical
strings are rejected without exposing their contents. Unknown fields and
contradictory cases remain strict, including rejection of the former numeric
array shape. Base64 is compact and convenient to copy but does not make textual
content directly readable; exact JSON resources remain the later H08 authoring
path.

Request and body goldens reflect the new encoding. Focused tests cover empty
content, all 256 byte values, all padding lengths, both request and response
decoding, invalid characters, whitespace, missing/extra padding, and nonzero
unused padding bits. This review update remains an adjacent, unsquashed fixup
to `8d9483a` until the owner approves the update and explicitly permits squashing.

Review-update verification passes: all ten focused HTTP tests pass with
`swift test --filter HTTPMessageTests -Xswiftc -warnings-as-errors`, followed by
`scripts/check` (strict formatting/lint, all macOS tests, consumer compiler
probes, release builds, and examples). Documentation links and whitespace checks
pass for the isolated fixup and complete H02 diff. The initial Apple coverage
figures above describe the initial implementation. No new coverage collection,
iOS/Linux execution, hosted CI, or Codecov upload is claimed for this fixup;
the full platform matrix remains a PR gate under the repository's review policy.


## Review update — lossless inline text, 2026-11-08

The owner approves adding lossless UTF-8 text to H02 and recording configurable
resource placement as future work. Inline bytes now canonically use
`{"kind":"bytes","text":"..."}` when strict Swift UTF-8 decoding followed by
encoding reproduces the exact bytes. Other bytes retain the base64 shape.
Readers accept either representation and reject simultaneous text/base64,
non-string/null text, and text on incompatible body cases. Valid base64 encoding
of UTF-8 content canonicalizes to text on write without changing body bytes.
No structured JSON representation or automatic resource-selection API is added.

The existing byte enums remain the strict runtime model. Empty bytes canonically
use empty text. Tests preserve HTML CRLF/quotes, Unicode normalization spelling,
non-BMP characters, BOMs, and JSON whitespace/duplicate names/number spellings/
escapes. Malformed UTF-8 and incomplete multibyte prefixes remain base64. Swift's
strict `String(validating:as:)` avoids BOM removal by Foundation's string decoding;
the production JSONDecoder path is also tested for exact byte recovery.

This update remains a separate unsquashed fixup to the original H02 commit.
Automatic placement, media-type configuration, and typed resource extensions are
planned separately; no future implementation unit is started by this update.

Inline-text verification passes: all 13 focused HTTP tests pass with
`swift test --filter HTTPMessageTests -Xswiftc -warnings-as-errors`; the canonical
`scripts/check` then passes strict formatting/lint, all macOS tests, compiler
probes, release builds, and examples. Complete-diff whitespace checks and changed
document file-link checks pass. As required for a review fixup, no new local
iOS/Linux matrix or coverage collection is claimed; the initial implementation
results above remain historical, and hosted checks remain a PR integration gate.

The separately committed documentation amendment records the owner-approved
DD17 revision, updates its decision index and consolidated overview, extends H02's
recorded scope, inserts approved future H07A after H07, and narrows H08 to derived
Content-Length and edited-body consistency. H07A remains unstarted. Its public
policy API, metadata handling, and exact media-type mappings retain an explicit
scope/review checkpoint. All 304 local file links in the changed documentation
resolve, new amendment/plan anchors resolve, and both isolated and complete H02
whitespace checks pass.

## Final review and pull request authorization

The review updates described above are incorporated into the H02 implementation
commit; references to unsquashed fixups describe their earlier review state.
The separate body-storage design amendment remains its own documentation commit.
The owner authorizes stacked H01/H02/H03 PR creation on 2026-11-08. H02 is complete
and targets `docs/003-h01-http-types-adoption`; no H03 or later implementation is
included in its diff. Required checks and a separate owner merge request govern
integration. Local verification results above remain historical measurements.
