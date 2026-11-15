# 003-H11 — Response-owned authentication branches

- Status: Complete; owner review and PR creation authorization on 2026-11-20.
- Date: 2026-11-16.
- Base: Merged H10 commit `46c9f91`.
- Authorization: The owner confirms the stated H11 scope and GPT-6 Sol / `high`
  recommendation, then instructs implementation to begin.
- Contract: [Response-owned authentication branches](../http-message-schema-v1.md#response-owned-authentication-branches).
- Sources: [DD09](../design-decisions/09-normalization-and-redaction.md),
  [DD12](../design-decisions/12-urlsession-scope.md#authentication-challenges),
  [DD17](../design-decisions/17-http-lifecycle-composition.md#http-authentication-lifecycle),
  and [D04's native challenge evidence](003-D04-authentication-challenges.md).

## Delivered behavior

A response owns exactly one body, redirect, or authentication continuation.
Authentication requires the existing origin 401 or proxy 407 head; ordinary
responses with those statuses remain valid without a fabricated challenge.
Each phase stores one local presentation delay, prepared Basic/Digest challenge
metadata, and one use-credential/default/reject/cancel/unanswered outcome.
Credential metadata retains optional prepared username, password presence, and
persistence, with no password argument, native credential object, or duplicate
failure response. Host, port, protocol, realm, proxy status, previous failures,
and optional proposed metadata remain explicit semantic values.

Use-credential retries; cancel owns the resulting timed failure once. Default
and reject preserve native-observed retry/body/failure/open continuations rather
than imposing a platform-specific outcome. A retry inherits the current effective
request unless an adapter observes a material change that needs an explicit
prepared edge request. Repeated challenges and mixed redirect/authentication
chains recurse through the existing attempt result without another root.
Unanswered phases and answered-but-open continuations remain distinct.

Pure branch selection compares the current prepared disposition and exact safe
credential shape, including optional username, password presence, and persistence.
It throws safe infrastructure facts for mismatch or answering beyond the recorded
horizon; it does not verify passwords or perform live access. The later delivery
owner reports those facts. Head plus presentation delay is checked within one
anchor; continuation delays start from completion of the current answer and
remain independent of application decision latency. No scheduler changes occur.

Strict Codable shapes reject missing/null/unknown/conflicting fields, unsupported
methods and persistence, invalid origin/proxy heads, duplicate response branches,
and misplaced password/native material. Unknown tag descriptions do not echo
their values. Root validation follows inherited/modified authentication requests
and redirect edges when checking derived Content-Length against HEAD/CONNECT.
Complete exposed challenge bodies support resource edits and derived length;
unexposed bodies cannot supply a length. Existing ordinary and redirect JSON
remain unchanged. These extend the unreleased version-one components; full
registration and capability derivation remain H13.

`DioramaURLSession` now depends on the existing `DioramaHTTP` target for its first
native authentication metadata helpers. Challenge capture accepts only supported
response-backed methods and defaults to typed username preparation, including the
proposed identity. Current decision conversion prepares selected credentials
using explicit recording/replay purpose and never reads password contents.
Failure reports once through the standard safe preparation boundary, preserving
native values and candidate health rules. Authored admission validates without
repeating transforms. Setup owns compatible proposed/selected identity policies;
structural construction alone is not confidentiality preparation.

Following owner review, both native helpers default to `HTTPPreparation`'s
authentication factories. A shared username rule replaces nonempty usernames
with `redacted` by default, or a configured nonempty constant or custom mapping.
Absent and empty usernames remain distinct; other metadata remains exact.
Prepared admission validates the selected rule without reapplying transforms.

There is no new external dependency, product, platform floor, unsafe isolation,
warning suppression, credential store, authentication algorithm, callback wiring,
or network behavior. Native challenge delivery/reconstruction, algorithm and
volatile-field policy, capability admission, and replay timing remain H12B/I06/I07
work. D04's Linux Digest exception and Basic interception requirements remain
unchanged; metadata tests do not establish native authentication conformance.

## Behavioral evidence

Eighteen public-import shared HTTP test functions and seven public-import URLSession
test functions cover:

- An independently authored canonical five-interaction golden: repeated
  Basic/Digest challenges, inherited request, safe proposal, proxy rejection,
  cancellation, unanswered challenge, and answered-open continuation.
- Builder/golden equality; optional versus empty identity/realm/protocol metadata;
  all credential persistence spellings; unknown tags without value disclosure.
- Current disposition selection, changed username presence/value, password presence,
  persistence, and explicit beyond-horizon rejection.
- Default/reject retry, returned body with trailers, partial failed/open body,
  native-observed failure, cancellation's single failure, and mixed redirect edges.
- Original/modified request derivation, recursive HEAD/CONNECT validation, exact
  nested coding paths, resource-backed challenged-body edits, and unavailable
  derived-length rejection.
- Inclusive maximum delay bounds, pre-decision overflow, independent continuation
  bounds, and observed-plus-override normalization without a wall-clock experiment.
- Required/optional fields, explicit nulls, unknown fields, incompatible branches,
  duplicate body/redirect/authentication continuations, wrong status/proxy pairings,
  negative counts/timing, invalid ports, and rejected password/native fields.
- Native Basic/Digest and proxy metadata extraction, explicit redaction before
  normalization, validation-only authored admission, unchanged native objects,
  concrete URLSession failure composition, and serialized secret-marker exclusion.
- All native dispositions, equivalent prepared identities with different transient
  passwords, safe conversion failures for unsupported methods/responses, and one
  retained fact on failed identity preparation. Recording invalidates the candidate;
  replay reports without poisoning recording health. No sender callback is invoked.
- Default and configured constant usernames, absent/empty preservation, shared
  proposed/selected policy, original-input custom mappings, independent setup
  policies, idempotence, validation-only admission, incompatible fixture rejection,
  post-transform validation, empty replacement rejection, and native safe defaults.

## Verification

With repository-selected Xcode 27.2 / Apple Swift 6.4.2 on arm64 macOS:

- `swift test --filter 'HTTPAuthenticationTests|URLSessionAuthenticationTests|HTTPRedirectTests|HTTPContentLengthTests|URLSessionRedirectCompositionTests' -Xswiftc -warnings-as-errors`
  passes all affected suites, including the 17 new test functions and existing
  redirect/content-length/concrete failure composition regressions.
- `scripts/check` passes canonical format/strict lint (zero violations), all nine
  host products (780 reported tests), coverage-export fixtures, public authoring
  compiler probes (one positive/seven negative), public lifecycle compiler probes
  (one positive/eleven negative), release builds, and Random/Date usage examples.
- `git diff --check` passes. All 389 local links in modified documents and the new schema anchor
  resolve in the complete proposed diff.

Initial builds identify a prerequisite H10 assertion using `.code` directly on
H09's `any Error` reconstruction result. An isolated test commit bridges that
value to NSError without changing production behavior. New test compilation
also identifies HTTPFields initializer spelling, segment argument order, and
an internal byte-count assertion; these are corrected to use public APIs.
Strict lint finds line lengths, two multiline trailing commas, a Data-to-String
style rule, and an overcomplex request-context function. Formatting, explicit
commas, failable conversion, and domain-specific private validation helpers
resolve them without weakening checks. Sandboxed tool attempts cannot write
normal caches; passing runs use approved normal tool-cache access.

No new local iOS/Linux, coverage collection, or hosted CI result is claimed.
Required PR platform and coverage gates must pass before merge. Native callback,
network-isolation, and actual post-decision scheduler conformance remain later
units; these tests establish portable composition, pure selection, and metadata
conversion/preparation only.

## Review and commit boundary

One implementation commit above `46c9f91`, including the owner-approved review
fixups:

`003-H11: feat(http): add response-owned authentication branches` contains shared
strict model/codecs and selection, recursive request validation, URLSession
metadata preparation helpers and internal target dependency, public-import
tests/golden, contract/index documentation, evidence, and plan status.

On 2026-11-20, the owner requests squashing the prerequisite native-error
assertion correction directly into H10. H11 is restacked onto that amended
commit, dropping its redundant test correction commit. H11's source and test
content remain unchanged by the restack.

The subsequent H08 construction-fix extraction restacks H11 onto H10 `6c258cf`
and its preparatory fix `cd5bc60`. H11 inherits the new ordinary-construction
regressions without changing its production implementation.
The focused Content-Length, shared authentication, and URLSession authentication
suites pass with warnings treated as errors after this restack. The preparatory
fix and H10 each pass their canonical macOS gate; no additional H11 platform
matrix is run for the restack.

Review the complete diff against H10. The shared
credential/challenge shape, default/reject continuation freedom, request
inheritance, exact prepared credential comparison, explicit identity preparation,
and decision-relative timing are the primary review points. The owner authorizes
PR creation on 2026-11-20; merge and starting H12 require separate authorization.

## Tagged continuation restack — 2026-11-20

H11 follows the owner's H10 schema revision: response nodes persist `head` and
one tagged `next`, with authentication encoded as `kind: authenticate` and its
matching `authenticate` payload. The enum owns that codec case; response decoding
no longer counts top-level body/redirect/authentication fields. The authentication
golden, strict-field regressions, contextual coding paths, and schema contract
adopt the new envelope without retaining the earlier unreleased spelling.

All 67 focused shared authentication, URLSession authentication/redirect,
lifecycle, redirect, Content-Length, and body-profile tests pass with warnings
treated as errors. The final canonical macOS `scripts/check` gate passes strict
format/lint, all nine host products, compiler probes, coverage-export fixtures,
release builds, and usage examples. The authentication golden remains byte-exact
on re-encoding, and semantic comparison preserves its original payloads. Complete
diff whitespace and 381 local documentation file links pass validation. No
additional platform or hosted CI check is run or monitored.

## Password coverage clarification — owner-confirmed 2026-11-20

The owner confirms that password contents remain excluded from recordings and
that testing correct password entry is the consumer's responsibility. Replay
compares only prepared username, password presence, and persistence. Different
passwords with identical prepared metadata select the same continuation,
including recorded success. The metadata preparation hook cannot inspect or
validate password contents. Public API documentation, the schema contract, and
the owning plan now state this coverage boundary explicitly. Runtime behavior
and the persisted schema remain unchanged.

The existing 17 shared/native authentication test functions pass with warnings
treated as errors, including different-password decision equivalence. The
canonical macOS `scripts/check` gate and `git diff --check` pass. An initial
sandboxed test attempt cannot write the normal compiler cache; passing tests
and the gate use approved tool-cache access. No additional platform or hosted
CI check is run. The owner approves squashing this documentation-only review
update into H11 on 2026-11-20.

## Configurable username defaults — owner-confirmed 2026-11-20

The owner approves default redaction with a setup-configurable fixed value
(`redacted` by default), preserving absent and empty usernames. Distinct account
identities can use a custom mapping or separately keyed system instances with
independent setup policies. The owner then instructs implementation.

`HTTPAuthenticationUsernameRule` supplies `.default`, throwing `.constant(_:)`
with a nonempty replacement, and custom redaction/validation closures for
nonempty usernames. `HTTPPreparation(authenticationUsername:)` shares the rule
between `authenticationChallenge()` and `authenticationCredential()`. The native
capture and decision helpers use these factories when no preparation is supplied.
Custom rules receive original usernames instead of a prior default substitute.
Factory-level redaction and normalization receive substituted values; final
validation enforces the selected username rule. `admitPrepared` validates without
rerunning transforms and rejects values incompatible with the configured policy.

Host, port, protocol, realm, password presence, and persistence remain exact by
default. Related challenge headers retain H03's existing behavior; username
redaction does not claim comprehensive protection-space sanitization. Password
contents remain excluded. No dependency, schema, scheduler, or native callback
change is introduced. Generic `ValuePreparation` and structural constructors
retain their existing behavior; supplying an explicit native preparation replaces
the default policy deliberately.

The review update adds two HTTP source files and one public-import preparation
test suite, extends HTTP setup and native helper defaults, updates native tests,
and reconciles the schema contract, architecture/index documentation, and owning
plan. On 2026-11-20, the owner approves squashing both review fixups into the H11
implementation commit. Autosquash preserves the complete source tree exactly;
the final evidence update records the merged H10 base and completed squash.

Verification on the repository-selected macOS toolchain:

- The focused shared/native authentication and HTTP preparation suites pass
  all 32 test functions with warnings treated as errors, including eight new
  functions for username preparation and native defaults.
- `scripts/check` passes format/strict lint (zero violations), all nine host
  products (791 reported tests), coverage-export fixtures, public authoring and
  lifecycle compiler probes, release builds, and both usage examples.
- `git diff --check` passes, and all 381 local file links in modified documents
  resolve. The first gate run finds seven line-length violations; wrapping
  those declarations and expressions resolves them without changing rules.

Passing runs use approved normal tool-cache access. No additional iOS/Linux,
coverage collection, native callback conformance, or hosted CI result is claimed.

## PR handoff — 2026-11-20

The owner requests PR creation and explicitly instructs the agent not to monitor
CI. The owning plan and evidence record the unit's completed, reviewed state.
Only handoff documentation changes after the verified implementation revision;
required hosted checks remain a merge gate, and no hosted result is claimed here.
