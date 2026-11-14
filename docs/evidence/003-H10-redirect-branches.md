# 003-H10 — Response-owned redirect branches

- Status: Complete; the owner approves stacked PR creation on 2026-11-20.
- Date: 2026-11-15.
- Base: Preparatory construction fix `cd5bc60`, above merged H09 `0130b70`.
- Scope/model: The owner approves the stated H10 scope and GPT-6 Sol / `high`
  recommendation, then authorizes commencement while reviewing H09 concurrently.
- Contract: [Response-owned redirect branches](../http-message-schema-v1.md#response-owned-redirect-branches).
- Design/evidence: [DD17](../design-decisions/17-http-lifecycle-composition.md#redirect-lifecycle)
  and [D03](003-D03-redirect-correlation.md).

## Delivered behavior

A response owns exactly one `HTTPAfterResponseHead`: ordinary body delivery or
one redirect phase. The phase stores its proposal, presentation delay, and one
follow-proposed, follow-modified, refused, or explicitly unanswered outcome.
Recursive attempt results represent multi-hop chains. Unchanged follow derives
its effective request from the proposal; modified follow stores it at the edge.
There is no second interaction root or duplicate response head at a continuation.
Refusal owns the existing response's content/prefix and returned/failed/open
conclusion. Followed and unanswered branches have no delivered redirect body.

The strict runtime branch is `HTTPResponseNode.next`. Its optional `body`
accessor returns direct or refused delivery; nil denotes no exposed body for
followed/unanswered redirects. The existing body initializer remains supported.
Every response persists `head` and a required tagged `next` value, with either
`kind: deliverBody` and `body`, or `kind: redirect` and `redirect`.
`HTTPAfterResponseHead` owns strict, branch-specific fields. Missing/null/unknown/conflicting fields
and incompatible nesting fail decoding. This extends unreleased version-one
components; H13 still owns full system registration and version dispatch.

`continuation(for:requestsMatch:)` accepts the current prepared follow/refuse
choice and setup's pure request-equivalence rule. It selects only the single
recorded compatible branch. Changed choices or nonequivalent effective requests
throw a safe infrastructure error, distinct from recorded adapter failures;
answering an open decision has its own safe fact. The later delivery owner must
report these facts. Selection performs no live access or scheduling and does not
replay a recorded choice in place of the application's current choice.

Presentation delay is head-relative. Head plus presentation delay is checked
within one anchor. The next attempt's head/failure delay or refused body's first
event starts from completion of the current decision. Validation never adds
across that decision boundary or persists application decision latency. Body
segment/trailer/conclusion timing retains H06's existing bounds and overrides.
The structural tests establish these anchors and preserve delayed continuations;
actual scheduler/native callback timing remains H12B/I05 work, informed by D03's
native timing evidence.

Derived Content-Length can use complete refused content, including edited
resource bytes. Followed/unanswered heads cannot derive lengths from unavailable
content. The preparatory fix makes `HTTPInteraction` construction throwing and
validates ordinary responses against their request method. H10 extends that
validation to the effective HEAD/CONNECT method at every recursive redirect edge.
Decoding uses that same initializer. Ordinary responses and redirect responses share the same explicit continuation
boundary. Existing fixtures and tests adopt the tagged spelling, optional body
accessor, and throwing root initializer.

All redirect structure here is portable shared HTTP composition. No additional
URLSession-specific native metadata is required by this unit, so no empty native
supplement or new target is introduced. A public-import URLSession test composes
H09's concrete failure with a followed branch and reconstructs its NSError code.
Native proposals, method/body rewrites, relative targets, cross-origin credential
policy, task correlation, callbacks, interception, and forwarding remain adapter
responsibilities. No dependency, manifest, platform-floor, unsafe-concurrency,
warning-suppression, or scheduler change is made.

## Behavioral evidence

Eleven public-import HTTP test functions and one URLSession composition test cover:

- An independently authored, canonical seven-interaction fixture, including a
  two-hop follow/modified chain, refusal, unanswered decision, followed-open
  attempt, followed pre-head failure, and refused failed/open prefixes.
- Public builder equality with the golden, effective method/body/request
  derivation, and structural assertions proving no competing body, repeated root,
  or duplicate response/request storage.
- Current compatible choices, incompatible follow/refuse/request choices, no
  comparison on refusal, explicit beyond-horizon rejection, and setup matching
  across inline/resource storage without changing logical bytes.
- Refusal body segments, trailers, exact partial binary/UTF-8 prefixes, retained
  resource bytes, edited resource lengths, and derived-length rejection when a
  head's body is unavailable.
- Inclusive `Int64.max` timing bounds, overflow before a decision, independent
  post-decision delay bounds, and normalized observed-plus-override editing.
- Recursive effective-method validation for proposed and modified HEAD/CONNECT
  requests, root builder rejection, and malformed persisted method contexts.
- Every new phase/outcome's missing/null/unknown fields; conflicting body/redirect
  continuations; misplaced requests/results/failures, decision latency, and
  version fields; unknown tags; negative timing; and exact nested coding paths
  with safe structural error descriptions.
- Concrete URLSession failure round-trip/reconstruction after a followed
  redirect, without native object graphs or live traffic.

## Verification

With repository-selected Xcode 27.2 / Apple Swift 6.4.2 on arm64 macOS:

- `swift test --filter 'HTTPRedirectTests|HTTPLifecycleTests|HTTPContentLengthTests|URLSessionFailureCodingTests' -Xswiftc -warnings-as-errors`
  passes the focused lifecycle, redirect, Content-Length, and failure coding tests.
- `swift test --filter 'HTTPRedirectTests|URLSessionRedirectCompositionTests' -Xswiftc -warnings-as-errors`
  passes all eleven redirect tests and the concrete URLSession composition test,
  including the self-review decoding-path improvement.
- Final `scripts/check` passes format/lint, all nine host test products (759
  reported tests), coverage-export fixture checks, public system-authoring
  compiler probes (one positive/seven negative), public lifecycle compiler probes
  (one positive/eleven negative), release builds, and compiled Random/Date usage
  examples. No compiler or lint warning is accepted.
- The complete proposed diff passes `git diff --check`; all 368 local file links
  in the modified documentation resolve. The new redirect section anchor is
  checked against its target heading.

The first sandboxed Swift invocation cannot write the normal compiler cache;
passing runs use approved normal cache access. Initial new test compilation
finds missing `try` annotations and an HTTPFields literal error. Golden comparison
finds JSON empty-array whitespace differing from Foundation's canonical spelling.
The first canonical gate finds five test line-length violations. Self-review
adds exact nested coding paths for contextual method errors and their regression
assertion; lint then identifies two required trailing commas in those paths.
These are corrected without changing production semantics or weakening checks.

No new local iOS, Linux, coverage collection, or hosted CI result is claimed.
Required PR platform and coverage checks must pass before merge. D03's documented
Linux native redirect limitations are unchanged; shared component tests do not
establish native callback conformance on any platform.

## Review and commit boundary

One coherent implementation commit contains the recursive branch model and pure
selection, strict codecs, contextual Content-Length extension, public-import
tests and golden, necessary existing test migrations, public contract/index
updates, this evidence, and owning-plan completion:

`003-H10: feat(http): add response-owned redirect branches`

Review the complete diff against `cd5bc60`, excluding the preparatory fix, H09,
and the earlier stack. The response ownership shape, optional body accessor, recursive validation,
single-branch equivalence rule, and decision-relative timing are the primary
review points. The owner approves a stacked PR targeting the preparatory fix
branch on 2026-11-20. Merge requires passing required checks and a separate
explicit owner request; hosted platform and coverage evidence is retained with
the PR.

## H08 review restack — 2026-11-15

The branch is restacked after H08's approved review squashes and the separate
H12A plan clarification. The Content-Length selector retains H10's response
continuation while constructing the immutable response head through H08's
internal initializer. No redirect or length-proof semantics change.

All 19 focused Content-Length/redirect tests pass. The canonical macOS
`scripts/check` gate passes all nine host test products (760 tests), strict
format/lint, compiler probes, release builds, coverage-export fixtures, and
usage examples. No PR CI monitoring or new local platform matrix is performed.

## H09 native error assertion correction — 2026-11-20

The owner requests moving the prerequisite assertion correction from H11 directly
into the H10 implementation commit. The URLSession composition test bridges
`makeError()`'s `any Error` result to NSError before checking its code, preserving
the existing assertion and production behavior. H11's separate test correction
commit becomes redundant when restacked.

All 12 focused redirect and URLSession composition tests pass with warnings
treated as errors. The canonical macOS `scripts/check` gate passes strict
format/lint, all nine host test products, coverage-export fixtures, public
authoring/lifecycle compiler probes, release builds, and Random/Date examples.
The initial sandboxed gate reports zero lint violations but cannot save the lint
cache; the passing run uses approved normal cache access. `git diff --check`
passes. No new local iOS/Linux or hosted verification is claimed.

## Extract ordinary construction validation — 2026-11-20

The owner requests a separate preparatory H08 fix for the missing ordinary
construction check. Commit `cd5bc60` owns the throwing initializer, ordinary
method validation, redundant codec-check removal, existing caller migrations,
and regression tests; see [its evidence](003-H08-interaction-construction.md).
H10 replaces the root-only check with recursive effective-method validation and
contextual decoding paths. The inherited edited-method decoding regression now
expects `DecodingError` because H10 adds a precise coding path for that failure.

After extraction, all 40 focused Content-Length, lifecycle, redirect, and
URLSession failure/redirect composition tests pass with warnings treated as
errors. The canonical macOS `scripts/check` gate passes strict format/lint, all
nine host products, compiler probes, coverage-export fixtures, release builds,
and usage examples. `git diff --check` passes. Compared with the prior H10 tip,
production implementation changes only in the constructor's documentation;
runtime behavior is preserved. No additional platform or hosted check is claimed.

## Tagged persisted response continuation — 2026-11-20

The owner requests persisting the strict runtime `next` enum as an explicit tagged
union and squashing the update directly into H10. Every response now requires
`head` and `next`; `HTTPAfterResponseHead` owns Codable with `deliverBody`/`body`
and `redirect`/`redirect` cases. No top-level branch-presence counting or earlier
response spelling remains. The unreleased schema is replaced without a reader
for the earlier form. Lifecycle and redirect goldens, Content-Length/body-profile
regressions, exact nested coding paths, and the public contract are updated.

All 55 focused lifecycle, redirect, Content-Length, body-profile, and URLSession
failure/redirect composition tests pass with warnings treated as errors. Both
goldens re-encode byte-exactly, and a separate semantic comparison confirms that
only the continuation envelope changes. The canonical macOS `scripts/check`
gate passes strict format/lint, all nine host products, compiler probes,
coverage-export fixtures, release builds, and usage examples. One extended path
assertion is wrapped to satisfy the existing line-length limit. Complete-diff
whitespace validation passes. No iOS/Linux or hosted CI is run or monitored.
