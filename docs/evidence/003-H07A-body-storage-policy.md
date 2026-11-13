# 003-H07A — Configurable type-aware HTTP body storage

- Status: Complete; owner approves fixup squashing and PR creation on 2026-11-14.

## Scope and review boundary

The owner confirms H07A's scope and the plan's GPT-6 Sol / `high` recommendation
on 2026-11-14, and authorizes stacked development while H07 remains under review.
The branch is `feat/003-h07a-body-storage-policy`, initially based on H07 at
`5697874` and subsequently restacked on its approved final revision, `561ca26`,
now on `master`.

This unit adds one immutable recording policy in `DioramaHTTP` and proves its
integration with H07's resource encoding/publication boundary. It adds no
dependency, native adapter, lifecycle engine, or system registration. The existing
message schema already represents every selected inline/resource form; no schema
version or persistence implementation changes are needed.

## Implemented contract

`HTTPBodyStoragePolicy.request` accepts a prepared request message. `response`
accepts prepared content and a prepared response head. Selection happens only for
newly recorded byte content, after confidentiality transforms and normalization.
Absent/unavailable bodies and existing resource references are preserved without
resolution, even if their unused resource stem is invalid. Admission, codecs,
matching, and replay never run this recording policy.

The public rules are nonthrowing `.inline`, `.resource(fileExtension:)`, and
`.automatic(inlineByteLimit:fileExtension:)`; `.standard(fileExtension:)` is the
inclusive 200-byte factory. Limits use `UInt`; zero keeps empty content inline
and externalizes nonempty content. Policy construction is nonthrowing and retains
rule keys exactly as supplied, with no validation, normalization, or wildcard interpretation. Exact
keys matched against the normalized header hint precede enabled standard rules,
followed by the configurable fallback. `useStandardRules` defaults to true;
disabling it applies the fallback to every type without a consumer override.
`HTTPBodyStoragePolicy.allInline` disables standard rules and uses `.inline` as
its fallback for newly recorded byte content. Standard extension defaults remain
available independently of standard placement rules. No wildcard or
order-dependent configuration is introduced.

Recognized PNG/JPEG/GIF/WebP always use resources by default. Textual mappings,
including JSON/HTML, use the inclusive 200-byte rule. Unknown content uses the
same default threshold. Limits measure prepared bytes, independent of characters,
JSON escaping, and base64. The supported mappings, precedence, syntax, and
configuration examples are in the [public contract](../http-message-schema-v1.md#recording-placement-policy).

Extensions come from the selected rule, then the media-type standard extension,
then `bin`. Body signatures, UTF-8 validity, and Content-Encoding do not affect
filenames. Unknown content uses `.bin` even when it is text; consumers can choose
`.txt` explicitly. The inline codec still chooses lossless UTF-8 text or base64.

One Content-Type field supplies a best-effort hint: discard the first semicolon
and everything after it, trim ASCII spaces/tabs, then lowercase. The value goes
straight to exact and family rule lookup without header type/subtype or parameter
validation. Malformed strings may match a family rule; unmatched hints, missing
fields, and repeated fields use fallback. Configured rule keys are used literally.
Header inspection preserves original field bytes. No charset
conversion, format validation, decompression, or body transformation occurs.

Explicit suffixes strip `/` and `\` scalars and otherwise retain the consumer's exact
spelling, including case, spaces, Unicode, dots, and empty content. There is no
suffix length limit or lowercasing; final resource-path validation and filesystem
limits still apply. Nil uses the standard rule's extension or `bin`; empty content
produces a trailing dot.
The caller assigns a
stable relative `resourceStem`; selection appends a literal dot and suffix.
Both the stem and result pass the existing H07 path validation. The policy keeps
no counter and uses no random/time identity. H07 continues to reject publication
aliases and disagreeing content at one path, and owns staging, exclusive
publication, rollback, and byte lifetime.

No body transcoding, decompression, normalization, JSON re-encoding, derived
Content-Length, or resource migration occurs. Returned bodies retain exact
logical byte meaning and request matching. Future adapter setup/capture must call
the policy only on its recording path; this unit does not invent that adapter.

## Proving tests

The public-only policy tests cover:

- 199/200/201-byte boundaries with multibyte UTF-8 and JSON escapes;
- PNG/JPEG/GIF/WebP, JSON/HTML/XML/CSS/CSV/JavaScript, text and unknown types;
- inline, resource, zero/custom/max thresholds, suffix overrides, and precedence;
- missing/repeated/unmatched hints, malformed family matches, and ignored parameters;
- strict space/tab handling versus Unicode whitespace, and raw header octets;
- rule-defined filenames for invalid UTF-8, partial prefixes, and encoded/opaque bytes;
- safe configuration, independent stem validation, and deterministic literal names;
- prepared request redaction before selection and equivalent inline/resource matching;
- absent/unavailable bodies and preservation of existing baseline references.

The committed `body-storage.json` fixture fixes the canonical inline text/base64
and typed reference spellings independently of runtime selection.

The added repository integration test publishes only redacted prepared bytes as
an automatic `.json` resource alongside inline opaque content. It verifies literal
stored bytes, successful loading with read-only document/resource files, exact
re-encoding, baseline reference preservation after a recording-policy change,
and independently owned loaded bytes after fixture deletion. H07's existing
failure, ownership, and collision tests remain part of the focused regression run.

## Initial implementation verification

The initial implementation passes on the repository-selected Xcode 27.2 (`27B52`) /
Swift 6.4.2 toolchain:

- `swift test --filter 'HTTPBodyStoragePolicyTests|HTTPResourceRepositoryTests'`:
  20 tests pass across the policy and publication suites.
- `scripts/check`: passes strict formatting/lint with no violations, 714 macOS
  host tests, public authoring probes (one positive/seven negative), lifecycle
  probes (one positive/eleven negative), release builds, and Random/Date examples.
- `scripts/coverage swiftpm macos`: passes with fresh products and LCOV export.
  The new policy has 148/148 executable lines covered (100%).
- `scripts/coverage ios`: passes the release build, 713 applicable tests on
  iPhone 17 / iOS 27.2 Simulator with the iOS 18 deployment floor, public
  lifecycle compiler probes, and LCOV export.
- An external-module compiler check accepts `try HTTPBodyStoragePolicy()`.
- Local file links and section anchors resolve; the complete branch/worktree
  diff against `5697874` passes `git diff --check`.

Initial test compilation and fixture assumptions are corrected before these
passing gates. Self-review adds regression coverage for opaque header octets and
strict HTTP padding, then reruns the focused, canonical, and fresh coverage gates
on the final revision. Xcode emits its existing no-AppIntents metadata extraction
notices; no Swift compiler or linter warnings are waived. Sandboxed cache writes
are unavailable; successful toolchain/quality runs use normal cache access.

Local Linux is unavailable: `container system status` reports “apiserver is not
running and not registered with launchd.” No Linux execution or hosted CI result
is claimed. Required PR checks enforce the macOS/iOS/Linux and coverage matrix
before a separately authorized merge.

## Standard rule selection and opt-out review — 2026-11-14

The owner approves explicit rule resolution and a standard-placement opt-out.
The public initializer adds `useStandardRules: Bool = true`; the nonthrowing
`HTTPBodyStoragePolicy.allInline` convenience uses no standard rules and an inline
fallback. Exact consumer overrides remain first, enabled standard rules second,
and fallback last. Baseline resources, absent/unavailable content, and prepared
bytes retain their existing preservation guarantees. No recording adapter is added.

Private media-type definitions now use `Rule` directly for default placement and
extension hints, replacing the image Boolean and ad hoc rule construction inside
`select`. The owner rejects a redundant `MediaTypeDefaults` wrapper during review;
no such wrapper remains. Standard extension hints still undergo byte/header
checks, while explicit consumer extensions retain their override semantics.
`rule(for:)` spells out precedence with branches. Selection applies that rule and
constructs a resource only when needed; metadata handles suffix inference
independently of placement configuration, including the existing opaque-content
and image-signature guards. Default behavior and canonical body fixtures remain
unchanged.

New tests exercise `.allInline` and its explicit initializer equivalent over
request/response bodies, all recognized image types, text/JSON families, unknown
types, empty content, and content above the standard threshold. They prove
consumer overrides still win with standard rules disabled, media-type and
encoding-based suffix inference remains available, and existing baseline
resources remain resources under `.allInline`.

Validation on macOS passes all 27 focused body-policy/resource tests and
`scripts/check`, including strict formatting/lint, all 723 host tests, compiler
probes, coverage-export fixtures, release builds, and usage examples. The initial
new request fixture's header construction is corrected before the passing tests.
`git diff --check` passes. No iOS, Linux, or new coverage collection runs. The
update is recorded as a review fixup, separate from literal-extension review.

## Persistence review restack — 2026-11-14

The owner requests restacking H07A after the approved persistence encoding and
resource-path reviews are squashed. The resource integration assertion now reads
`.data` from the complete public encoder. Stem tests retain structural rejection
and prove that trailing periods, device names, literal percent escapes, spaces,
and Unicode are preserved when a suffix is appended. The shared path contract
continues to reject absolute, empty, dot, dot-dot, and NUL-containing paths.
Suffix validation remains ASCII alphanumeric as specified by the policy.
Production policy source and body payload schemas are unchanged by this restack.

Validation on macOS passes all 21 focused body-policy/resource tests and
`scripts/check`, including strict formatting/lint, all 716 host tests, compiler
probes, coverage-export fixtures, release builds, and usage examples.
`git diff --check` passes. No iOS, Linux, or new coverage collection runs.

## Owned-resource review restack — 2026-11-14

The owner approves squashing H07's owned-resource fixup and the dependent H07A
restack. Stem validation now uses `ScenarioResourcePath` directly and preserves
the existing `HTTPMessageError.invalidResource` boundary, instead of constructing
a path-only HTTP resource. Policy tests use owned baseline resources and the
nonthrowing byte accessor. Placement, suffix selection, prepared bytes, and
baseline preservation retain their existing behavior. The first compile identifies
remaining path-only test construction and an obsolete `try`; those are migrated
before the passing focused tests.

Validation on macOS passes all 22 focused body-policy/resource tests and
`scripts/check`, including strict formatting/lint, all 718 host tests, compiler
probes, coverage-export fixtures, release builds, and usage examples.
`git diff --check` passes. No iOS, Linux, or new coverage collection runs.

## Literal extension override review — 2026-11-14

The owner approves replacing numeric ASCII range checks with rejection of `/`
and `\` only. Explicit suffixes retain their exact spelling; the 16-byte limit
and lowercasing are removed. Dot and empty suffixes follow the existing literal
dot-appending behavior. Final resource-path validation still rejects NULs and
escaping components, and filesystem-specific limits fail during publication.
Built-in inferred suffixes, rule precedence, thresholds, and body bytes are
unchanged. This supersedes the earlier ASCII-suffix review evidence.

Configuration tests reject separators through both rule factories, including
separators followed by combining scalars that character-based matching can miss.
The implementation checks literal Unicode scalars rather than whole characters.
Repository tests exercise both factories through publication and loading with empty,
leading-dot, multi-part, uppercase, Unicode, space-containing, percent-escaped,
and longer-than-16-character suffixes. A separate regression verifies NUL rejection
when the final resource path is constructed. The existing override-precedence
assertion now expects its original uppercase suffix.

Validation on macOS passes all 24 focused body-policy/resource tests and
`scripts/check`, including strict formatting/lint, all 720 host tests, compiler
probes, coverage-export fixtures, release builds, and usage examples.
`git diff --check` passes. No iOS, Linux, or new coverage collection runs.
The update is recorded as a separate review fixup.

## Best-effort hints and rule-based extensions review — 2026-11-14

The owner approves using header values only as normalized storage hints and
removing byte-driven extension inference. `BodyStorageMediaType.hint(in:)` keeps
the single-field restriction, truncates at the first semicolon, trims ASCII
spaces/tabs, and lowercases. Header syntax and parameter validation are removed;
configured rule-key validation remains. Matching is best-effort, including family
defaults for malformed strings that have matching prefixes or suffixes.

The selected rule's extension wins, followed by the media-type standard extension,
then `bin`. Standard rule resolution returns the full `Rule` directly. The byte
signature, UTF-8, and Content-Encoding extension guards and metadata wrapper are
removed. Unknown text no longer automatically acquires `.txt`. Placement still
uses byte count; inline encoding still chooses text/base64 without changing bytes.
Standard placement opt-out, explicit extension spelling, prepared-byte ownership,
and baseline preservation remain unchanged. DD17 records this approved revision
to the earlier unknown-text and extension-inference behavior.

Tests cover malformed/unterminated parameters, normalized exact overrides,
best-effort family matches, missing/repeated/unmatched hints, image extensions
for empty/incomplete/arbitrary content, invalid UTF-8 and Content-Encoding with
rule-defined suffixes, and rule-only suffixes with standard placement disabled.
Repository tests publish and reload arbitrary bytes under rule-based names.
The independent body-storage fixture changes only the unknown-text resource's
extension from `.txt` to `.bin`; existing baseline references are not migrated.

Validation on macOS passes all 28 focused body-policy/resource tests and
`scripts/check`, including strict formatting/lint, all 724 host tests, compiler
probes, coverage-export fixtures, release builds, and usage examples.
The initial gate hits the existing retained-report lifetime assertion expecting
two releases but observing one. Its four-test suite passes in isolation, followed
by the passing full gate rerun. No report implementation or tests are changed.
`git diff --check` passes, and the new decision link resolves. No iOS, Linux, or
new coverage collection runs. The update is recorded as a review fixup after
the standard-rule and literal-extension review updates.

## Nonthrowing consumer-owned configuration review — 2026-11-14

The owner approves removing rule-key validation and setup errors. The policy
stores the supplied dictionary directly; keys are not normalized, validated, or
interpreted as wildcard patterns. Lookup uses the lowercased, trimmed header hint
as before. Unusual keys may match literal hints, while differently cased keys
coexist without dictionary-order-dependent resolution. The obsolete token regex,
key parser, and stored whitespace character set are removed; header hint trimming
keeps its local ASCII space/tab set.

`inlineByteLimit` and the stored threshold use `UInt`; zero constructs resource
placement, including for empty content. Byte counts are compared as `UInt`, so
the full limit range is supported without narrowing to `Int`. Explicit extension
construction strips `/` and `\` Unicode scalars and preserves all other spelling.
Final resource-path validation still rejects NULs. Policy initialization and
both rule factories are nonthrowing, and `HTTPBodyStorageError` is removed.
DD17 records the approved changes to earlier key/suffix validation and zero limits.

Tests cover literal malformed and empty keys, differently cased keys, lack of
wildcard/parameter-key interpretation, zero/resource equivalence for empty and
nonempty bodies, and `UInt.max` without overflow. Separator-stripping tests
include combining scalars; repository tests round-trip sanitized and unchanged
extensions through both factories. Callers no longer use `try` for configuration.

Validation on macOS passes all 29 focused body-policy/resource tests and
`scripts/check`, including strict formatting/lint, all 725 host tests, compiler
probes, coverage-export fixtures, release builds, and usage examples. Two initial
test-formatting findings are corrected before the passing gate. `git diff --check`
passes and the new DD17 link resolves. No iOS, Linux, or new coverage collection
runs. The source-breaking error-type removal, unsigned limits, literal keys,
zero-resource behavior, and nonthrowing construction are intentional at this
review stage; the subsequent review below supersedes zero-resource equivalence.
The update is recorded as a review fixup after the preceding H07A updates.

## Standard factory and inclusive zero review — 2026-11-14

The owner refactors `Rule.standard` into `standard(fileExtension:)`, so built-in
text rules use the same public factory with their suffix. The public configuration
example now calls `.standard()`. The owner accepts ordinary inclusive behavior
at zero: empty content remains inline, while all nonempty content becomes a
resource. `.resource` still externalizes empty content. Source documentation,
the public contract, DD17, and boundary tests reflect that distinction.

Final macOS validation passes all 29 focused body-policy/resource tests and
`scripts/check`, including strict formatting/lint, all 725 host tests, public
compiler probes, coverage-export fixtures, release builds, and usage examples.
`git diff --check` passes. No iOS, Linux, or new coverage collection runs for this
review update. Earlier platform/coverage evidence above applies to its recorded
revision rather than being claimed as rerun for this revision.

The owner authorizes this final fixup, squashing all H07A review fixups, pushing
the resulting branch, and opening its PR against master. CI status is not
monitored, as requested. Required PR checks remain the merge gate; no hosted
result is claimed.

## Commit and remaining review

One coherent implementation commit contains the policy, its focused tests and
fixture, the H07 publication integration test, public schema/usage documentation,
this evidence, its documentation-index link, and owning-plan completion status:

`003-H07A: feat(http): select type-aware body storage`

The complete H07A review diff is against H07 at `561ca26`, now on `master`;
it excludes H07. The public
policy API, exact supported mappings, best-effort hint handling, suffix
separator checks, and caller-assigned naming are the explicit owner review points.
All review fixups are approved for squashing into that implementation commit.
Push and PR creation are owner-authorized; merge and H08 implementation require
separate authorization.
