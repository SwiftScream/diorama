# 003-D04: Authentication challenges

- Date: 2026-09-26.
- Owning unit: [003-D04](../plans/003-clean-slate-implementation.md#003-d04--basic-and-digest-challenge-spike).
- Approved scope/model: GPT-6 Astra, `xhigh`; owner confirmation precedes work.
- Base: D03 commit `7cd15aa591c3c5867be9f042f269e2bcf7368637`.
- Contracts: [DD12 authentication](../design-decisions/12-urlsession-scope.md#authentication-challenges)
  and [DD17 authentication lifecycle](../design-decisions/17-http-lifecycle-composition.md#http-authentication-lifecycle).
- Status: Complete as an isolated investigation, ready for owner review.
  All implementation remains in the spike; no production target, dependency,
  or persisted schema changes.

## Findings

The tested Apple bridge can present native Basic/Digest challenges and observe
the consumer's ordinary URLSession completion decision in an internal delegate
proxy. That decision resumes either the private native request or the selected
offline continuation. Consumer code needs no Diorama API or sender calls.

Relying on Foundation to call a supplied `URLAuthenticationChallengeSender`
is unsuccessful in these experiments. This applies both to a newly constructed
challenge and to a challenge copied from a real private request with a replacement
sender. The consumer receives the challenge and answers normally, but the
sender sees no answer. Use/default/reject reach the 30-second watchdog without
a completion; cancel produces the native cancellation error. The watchdog
establishes a bounded failure observation, not a proof of permanent deadlock.
The failing approach remains an explicit opt-in experiment.

The working delegate proxy captures the particular pending continuation before
calling Foundation's completion handler, then resolves it with the same native
disposition and transient credential. A once-only guard prevents the optional
sender path and the proxy from resolving the same continuation twice. These
fixtures establish the decision bridge, not D05's complete lifetime proof.

Apple documents [construction of custom protocol challenges](https://developer.apple.com/documentation/foundation/urlauthenticationchallenge/init(protectionspace:proposedcredential:previousfailurecount:failureresponse:error:sender:))
and [replacement of a challenge sender](https://developer.apple.com/documentation/foundation/urlauthenticationchallenge/init(authenticationchallenge:sender:)).
Its [URLSession challenge guidance](https://developer.apple.com/documentation/foundation/handling-an-authentication-challenge)
requires consumer replies through completion handlers. The spike follows that
consumer API. The unsuccessful automatic sender result is runtime evidence;
it is not a claim about every Apple release or the private cause of the failure.

### Linux findings and owner decision

The [upstream handoff](003-D02-foundationnetworking-handoff.md#d04-fix-priorities--2026-09-26)
records reproductions and pinned source references:

| Finding | Consequence |
| --- | --- |
| FN-15: a custom Basic credential decision replaces the custom protocol with native HTTP | **Required repair.** The loopback replay probe makes a real request and returns the live body. A delegate observer cannot undo the network request started inside Foundation's completion handler. |
| FN-16: native Digest is unimplemented | **Owner-approved native exception.** The native control returns the 401 body without a challenge. Preserve that outcome and reject replay requiring unsupported Digest capability. |
| FN-17: configured HTTP/HTTPS proxy is not reached | **Recommended native repair.** The failure exists without interception. This runtime does not establish native proxy authentication capability. |
| FN-18: untrusted certificates produce `URLError.unknown` | **Nice to have.** Native validation still rejects the certificate; Diorama preserves the native error. |

The owner explicitly approves the narrow Digest exception on 2026-09-26.
The [DD12 amendment](../design-decisions/12-urlsession-scope.md#foundationnetworking-digest-exception--2026-09-26)
and [DD17 amendment](../design-decisions/17-http-lifecycle-composition.md#foundationnetworking-digest-exception--2026-09-26)
record it. Raw credentials, live replay fallback, and silently fabricated
challenge phases remain prohibited. Continue planned implementation assuming
required FoundationNetworking fixes will arrive, without advertising working
Linux authentication interception before conformance passes.

## Executable matrix

| Fixtures | Evidence |
| --- | --- |
| [Native controls](../../Spikes/URLSessionInterception/Tests/URLSessionInterceptionTests/D04NativeChallengeTests.swift) | Basic/Digest × use/default/reject/cancel/repeat, actual HTTP responses and retry requests. |
| [Challenge experiments](../../Spikes/URLSessionInterception/Tests/URLSessionInterceptionTests/D04ChallengeTests.swift) | Copied native challenges, synthetic challenges, the rejected automatic sender approach, and the delegate bridge. |
| [Replay cases](../../Spikes/URLSessionInterception/Tests/URLSessionInterceptionTests/D04ReplayTests.swift) | Repeated failures, safe proposed credentials, body/failure branches, branch mismatch, four consumer presentations, pending decisions, caller cancellation, and post-decision delay. |
| [Forwarding cases](../../Spikes/URLSessionInterception/Tests/URLSessionInterceptionTests/D04ForwardingTests.swift) | Real private Basic/Digest retries and all four answered dispositions; native/forwarded pending decisions; opt-in HTTPS controls. |
| [Proxy cases](../../Spikes/URLSessionInterception/Tests/URLSessionInterceptionTests/D04ProxyChallengeTests.swift) | Real configured proxy; HTTP 407 baseline and HTTPS CONNECT challenge/failure continuation, native and forwarded. |
| [Unsupported challenges](../../Spikes/URLSessionInterception/Tests/URLSessionInterceptionTests/D04UnsupportedChallengeTests.swift) | A preserved consumer protocol injects an unsupported method or a response-less Basic challenge; both fail explicitly before outer presentation, with zero live connections. |
| [Linux reproducer](../../Spikes/URLSessionInterception/Tests/URLSessionInterceptionTests/D04LinuxChallengeTests.swift) | Controlled proof of the FN-15 live request; no external endpoint. |
| [Delegate proxy](../../Spikes/URLSessionInterception/Tests/URLSessionInterceptionTests/D04DelegateProxy.swift) | Consumer completion interception and Apple creation-hook wrapping of the explicit async delegate. |

The test server accepts the presence of a native Authorization or
Proxy-Authorization value with the selected scheme. It does not implement
Basic/Digest on the client, compute a Digest response, or validate Digest
cryptography. The fixed nonce and MD5/qop fixture select a reproducible native
challenge path; they do not establish support for every Digest algorithm.

### Origin challenges and continuations

On Apple, Basic and Digest use-credential paths make two requests and complete
with the authorized body. Default/reject complete with the challenged 401 body.
Cancel completes once with `NSURLErrorDomain/-999`. Repeated rejection by the
server presents failure counts `[0, 1, 2]` before default handling returns the
401 body. Private forwarding preserves these observable outcomes. Native
request counts can include an additional unauthenticated retry on Apple.

Native Linux Basic succeeds with a credential. Default returns the 401 body;
reject and cancel fail with `-999`. Repeated attempts present `[0, 1, 2]`.
That native reject failure is a valid native continuation, not an invented
successful refusal. Native Digest returns one 401 response without a challenge
under the approved exception. These working native controls do not establish
working custom-protocol authentication on Linux.

Offline replay exercises Basic and Digest use/default/reject/cancel/repeat,
an authored failure continuation, and a decision mismatch. The listener
observes zero connections in every passing Apple case. Proposed credential
metadata preserves synthetic username, password-presence flag, and persistence
policy; encoding the selected metadata excludes the synthetic password.
Native credentials and authorization headers are never rendered in evidence
or assertion diagnostics. This is a conversion-boundary experiment, not a
production persistence schema or a replacement for DD09 preparation.

An unanswered native, forwarded, or synthetic challenge gates completion in
the observed interval. Answering starts the synthetic 30 ms continuation delay;
the preceding 60 ms of consumer latency does not consume that delay. Explicit
task cancellation completes the pending replay without recording a challenge
answer. These are bounded behavior checks, not a quiescence or leak proof.

### Proxy challenges

Apple bypasses the tested legacy proxy settings for a loopback destination, so
the actual proxy experiment uses a reserved `.invalid` origin and a local
proxy that never contacts that origin. For plain HTTP, Apple returns the 407
body without a task or session challenge. Preserve that observed response;
do not manufacture a phase from the status alone.

For HTTPS CONNECT, Apple presents a task-level challenge with the 407 failure
response and proxy host/port/type. Basic and Digest both produce a native
credential-bearing CONNECT retry. The fixture deliberately answers that retry
with 502, producing a CFNetwork failure continuation without implementing a
TLS tunnel. Private forwarding copies the proxy configuration and preserves
the challenge and failure. Separate synthetic 407 cases prove offline native
presentation through delegate, completion, async, and explicit-async-delegate
consumers. Successful end-to-end TLS through an authenticated proxy is not
claimed by this fixture.

### Ordinary HTTPS and unsupported security challenges

Private forwarding must answer default TLS handling internally, including
when Foundation falls back to the task-level challenge callback. It must not
copy server-trust objects into an outer recordable challenge. The forwarding
fixture filters Basic/Digest before constructing its challenge bridge. Other
methods and challenges without an HTTP failure response fail with an explicit
infrastructure error, before reaching the consumer. The protocol-injection
controls exercise that rejection without constructing Security objects.

An opt-in smoke requests `https://example.com/` and
`https://self-signed.badssl.com/`, natively and through forwarding. It checks a
successful trusted response and native rejection of the untrusted certificate,
with zero outer authentication challenges. No trust override or certificate
installation is used. These external probes are separate from the deterministic
default gate; endpoint availability is an environmental prerequisite. The
fixture does not virtualize custom trust or client-certificate handling. Apple
reports `-1202` for this rejection; Linux reports `-1`, with a certificate-related
native description classified to a Boolean without storing or printing it.
FN-18 records the missing native error mapping.

## Verification and reproduction

Use the same Xcode 27.0 / Swift 6.4, macOS 27.0, iPhone 17 / iOS Simulator 27.0,
and x86_64 Ubuntu Noble profiles recorded in [D03](003-D03-redirect-correlation.md#verification).
The iOS deployment target remains 18 and the macOS target remains 15.

```sh
scripts/lint
Spikes/URLSessionInterception/run swiftpm
Spikes/URLSessionInterception/run ios
```

Focused deterministic run:

```sh
swift test --package-path Spikes/URLSessionInterception \
  --scratch-path .build/urlsession-spike -Xswiftc -warnings-as-errors --filter D04
```

The final runs enable the four external HTTPS cases explicitly:

```sh
DIORAMA_D04_HTTPS=1 Spikes/URLSessionInterception/run swiftpm
TEST_RUNNER_DIORAMA_D04_HTTPS=1 Spikes/URLSessionInterception/run ios
```

For Linux, use the [D03 container invocation](003-D03-redirect-correlation.md#verification)
with `DIORAMA_D04_HTTPS=1` before the canonical spike command inside the
container. Both `swift:6.4.0-noble` and the pinned
`swiftlang/swift@sha256:15ae709b1d8eb1f8691b300f5721499d007e944694f2c0e9929a55580c9bf1a5`
image are verified. Each uses two CPUs and 4 GiB; the snapshot reports
Swift 6.4.2-dev, Swift revision `d2e983b81b18217`.

Set `DIORAMA_D04_PROBE_SENDER=1` for the rejected automatic sender experiments;
these intentionally retain their unmet assertions and may take 120 seconds.
They are not part of the selected delegate-proxy implementation path.

Linux retains three FN-15 known assertions and fourteen FN-17 known assertions.
Digest native controls assert the accepted native outcome directly. Custom
forwarding/replay cases that may escape to HTTP or trap are disabled on stock
Linux. `DIORAMA_VERIFY_FOUNDATION_FIXES=1` restores their intended assertions;
use a focused filter when verifying one repair because unrelated optional
native capabilities may still be absent. FN-15 requires preserving the custom
protocol's pending continuation. An upstream fix need not add automatic sender
callbacks if the delegate-completion bridge passes; the separate raw sender
reproducer retains that fuller API expectation. No known issue permits an actual
production replay to use networking.

| Gate | Result |
| --- | --- |
| `scripts/lint` | Pass; zero violations in 126 Swift files. |
| Canonical macOS spike gate, HTTPS enabled | Pass; 265 expanded cases, zero failures. |
| Canonical iOS Simulator spike gate, HTTPS enabled | Pass; 265 expanded cases, zero failures. |
| Canonical stable Linux spike gate, HTTPS enabled | Pass with 61 known assertions; 171 executed cases. |
| Canonical pinned-snapshot Linux spike gate, HTTPS enabled | Same result as stable Linux. |
| Complete branch whitespace and local documentation file links | Pass. |

Apple runs 57 deterministic D04 cases plus four optional HTTPS cases alongside
204 D01–D03 cases. Its 66 test declarations include one skipped declaration for
the unsuccessful automatic sender experiment. Linux runs 18 deterministic D04
cases plus four HTTPS cases alongside 149 earlier cases. Its 63 declarations
include the earlier disabled redirect cases, six disabled D04 declarations
(35 cases), and the opt-in sender experiment. Five additional forwarding
variants are not instantiated on stock Linux. The 61 known assertions comprise
44 earlier assertions plus D04's three FN-15 and fourteen FN-17 assertions.
Default gates omit the four external HTTPS cases on each platform.

These passing gates are not Linux authentication conformance. Hosted Quality,
macOS, iOS, Linux, and coverage checks belong to the owner's authorized PR
workflow; no hosted D04 result is claimed by this local review.

The pinned Swift 6.4.2-dev compiler initially traps in its `SendNonSendable`
pass when the fixture returns `Any?` from `Mutex.withLock { $0?.copy() }` and
casts outside the closure. Moving the cast inside returns a typed
`URLSessionConfiguration?` instead. This preserves the configuration copy and
synchronization; no unsafe annotation or warning suppression is added. The
stable compiler accepts the original expression. This is a snapshot compiler
finding, separate from the FoundationNetworking handoff.

## Production boundary

D04 selects the delegate completion observer as the demonstrated Apple
challenge decision mechanism; automatic custom-sender callbacks are not a
usable assumption on the tested runtime. This fits DD12's previously undecided
internal sender/proxy boundary. The only approved semantic amendment in this
unit is the native Linux Digest exception.

Production still needs per-task continuation ownership, prepared credential
matching, setup capability rejection, optional delegate forwarding, recorded
tree validation, and error/diagnostic integration in the planned H/I units.
The spike's serialized, single-operation state is not production routing.
D05 must prove pending native callbacks, cancellation races, sender/closure
retention, late answers, private forwarding tails, and finalization without
scenario mutation. No new unsafe isolation or sendability annotation is added;
the existing synchronized D02 delivery bridge gains one challenge callback.
