# 003-H12 — Optional response-disposition supplement

- Date: 2026-11-20.
- Status: Complete. The owner approves squashing and PR creation on 2026-11-22.
- Review base: `master` at `c2d3124`, which includes H11.
- Authorization: The owner confirms the outlined H12 scope and GPT-6 Sol /
  `medium` recommendation, then instructs implementation.
- Contract: [Optional response disposition](../http-message-schema-v1.md#optional-response-disposition).
- Sources: [DD12](../design-decisions/12-urlsession-scope.md#foundationnetworking-response-disposition-exception--2026-09-24),
  [DD17](../design-decisions/17-http-lifecycle-composition.md#urlsession-response-disposition),
  and [D02 evidence](003-D02-task-rejection-and-response-presentation.md).

## Delivered behavior

An observed consumer response-delegate decision is an explicit response-owned
`disposition` continuation. Its phase stores a head-to-presentation delay and
one allow/body, cancel/timed-failure, or unanswered-open outcome. Cancellation
cannot also own body success. Allow retains ordinary returned, failed, and open
body conclusions, including resources and derived Content-Length semantics.
The existing response head is never duplicated.

Ordinary body responses retain their existing representation, with no implicit
allow, callback, or delegate requirement. Completion/async and private-forwarding
implementation callbacks do not manufacture consumer decisions. Pure selection
uses the current answer and throws safe infrastructure facts for mismatch or an
answer beyond an unanswered horizon. The eventual delivery owner reports them.
Head plus presentation delay is bounded together; body/failure timing starts
after the current answer and does not include application decision latency.

Replay setup requires proven consumer decision gating and, for cancel,
effective cancellation. H13 checks those requirements against the native
bridge's capability profile. I04 verifies native delivery.
Under the DD12/DD17 Linux exception, capture refuses publication when a
recorded cancel is followed by success. Incremental transition validation
remains H12A.

`DioramaURLSession` adds
`HTTPResponseDispositionDecision.init(urlSessionDisposition:)`. The initializer
converts observed native allow/cancel answers and rejects download/stream
transitions and unknown values. The portable model uses the adapter's generic
failure type.

Strict codecs extend the unreleased version-one tagged continuation envelope.
Missing/null/unknown/conflicting fields and unsupported outcomes fail decoding;
unknown outcome descriptions do not echo supplied values. A canonical fixture
independently authors allow/body encoding and re-encodes byte exactly.

## Initial verification

Six public-import shared test functions and one native conversion test cover
current-answer selection, cancellation ownership, unanswered horizons, absent
supplement encoding, capability combinations, independent maximum timing anchors,
all body conclusions, resource edits, effective HEAD/CONNECT constraints, and
eleven malformed-schema cases. Native tests cover allow/cancel conversion and
unsupported task transitions without invoking callbacks.

The canonical macOS `scripts/check` gate passes with the repository-selected
Xcode 27.2 / Swift 6.4.2: zero format/strict-lint violations, all nine host
products (798 reported tests), coverage-export fixtures, public authoring and
lifecycle compiler probes, release builds, and both usage examples. Initial lint
finds two multiline collections without mandatory trailing commas; explicit
multiline formatting resolves these without weakening policy. Runs use approved
normal tool-cache access. Diff whitespace and local documentation links are
checked before commit: `git diff --check` passes and all 383 local file links
in modified documents resolve. The final focused suites pass all seven test
functions with warnings treated as errors.

No additional local iOS/Linux, coverage collection, hosted CI, native callback,
or wall-clock scheduling result is claimed. H11 CI is not monitored, as requested.

## Review boundary

The H12 implementation commit contains the shared phase/codecs, lifecycle
integration, native decision converter, public-import tests/fixture, and contract,
orientation, plan, and evidence updates. Review against `master`. Full
capture/replay, native callback composition and timing, and recursive capability
admission remain separate review units. Merge requires passing required checks
and a separate owner request.

## Redirect refusal review update

The [D03 native data-delegate probe](../../Spikes/URLSessionInterception/Tests/URLSessionInterceptionTests/D03NativeRedirectTests.swift)
receives the response-disposition callback for the same 302 after refusing its
redirect. A refusal now owns one tagged `next`: direct body delivery or a
disposition under the original head. The refusal answer anchors the delay to
disposition presentation, and the disposition answer anchors subsequent body or
failure timing. Direct delivery encodes its body in `next.body`.

A 24-case native origin-authentication probe on macOS 27.2.1 uses the D04
Basic/Digest challenge and the D03 loopback fixture. Each response carries a
distinct fixture header and body. Default handling and protection-space
rejection each send a second request without Authorization, even when the
server offers keep-alive. The challenge references the first 401 and the
disposition references the second response, which can be a 401 or 403. Allow
delivers the second body. Response cancel completes with
`NSURLErrorDomain/-999` before body delivery. Challenge cancel completes after
one request, before a response disposition.

The [redirect fixture](../../Tests/DioramaHTTPTests/Fixtures/redirects.json)
shows refusal with direct delivery and with a same-head disposition. The
[authentication fixture](../../Tests/DioramaHTTPTests/Fixtures/authentication.json)
shows default handling selecting an inherited retry whose separate 401 owns
the disposition through its ordinary response continuation.

For the review fixup, all 34 focused tests and the canonical macOS
`scripts/check` gate pass. The gate reports 801 tests across nine host products,
zero lint violations, and passing compiler probes, release builds, and usage
examples. The regression cases check the separate timing anchors, strict
refusal decoding, and resource-derived Content-Length after allow.

## Capability API review update

The shared disposition model exposes its recorded outcome and selects a
continuation from the current answer. URLSession replay admission checks the
bridge's typed capabilities as part of H13. The ordinary-body encoding test
continues to cover the absence of a recorded disposition.

All 34 focused tests and the canonical macOS gate pass for this fixup,
including 801 tests across nine host products.

## Native initializer review update

The URLSession adapter supplies the native conversion initializer on the shared
decision type. The native conversion tests exercise allow and cancel on Apple
Foundation and FoundationNetworking. Apple tests also check unsupported
download and stream transitions. The FoundationNetworking compile path avoids
its deprecated download case, which the warnings-as-errors gate previously
rejected.

All 34 focused tests and the canonical macOS gate pass on the PR revision,
including 801 tests across nine host products.
