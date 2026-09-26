# 003-D03: Redirect correlation

- Date: 2026-09-26.
- Owning unit: [003-D03](../plans/003-clean-slate-implementation.md#003-d03--redirect-correlation-spike).
- Approved scope/model: The owner authorizes this investigation while D01/D02
  remain under review, using GPT-6 Astra with `xhigh` reasoning.
- Status: Complete as an isolated investigation. The owner authorizes PR
  preparation on 2026-09-26, stacked on D02 while D01/D02 remain under review.
  Linux redirect conformance remains blocked by the documented runtime defects.
- Base: D02 commit `7fb3558aa04a1a420afea4447b1913b281be9db5`.
- Contracts: [DD12 redirects](../design-decisions/12-urlsession-scope.md#redirects),
  [DD17 redirect lifecycle](../design-decisions/17-http-lifecycle-composition.md#redirect-lifecycle).

## Result

Task ownership remains suitable for redirect correlation on tested Apple
runtimes. A followed redirect creates another protocol instance, with the same
outer native task. Asynchronous session enumeration resolves every instance
to its owning session. A group keyed by that task survives the entire chain;
two sessions requesting the same URLs concurrently retain separate groups.
The fixtures use no routing headers, request properties, or persisted native
identities.

Linux custom redirect notification traps inside FoundationNetworking. Ordinary
HTTP redirects use a separate implementation and do not exercise that callback.
[FN-11](003-D02-foundationnetworking-handoff.md#fn-11--custom-protocol-redirect-notification-traps)
is therefore an additional **required upstream repair** for the accepted
URLProtocol boundary. The existing owner-approved continuation policy permits
implementation while this repair is outstanding; it does not establish Linux
redirect support or authorize live replay fallback.

## Executable coverage

All code remains in `Spikes/URLSessionInterception`; no production target,
manifest, dependency, public API, or persistence schema changes.

| Fixture | Purpose |
| --- | --- |
| [Native controls](../../Spikes/URLSessionInterception/Tests/URLSessionInterceptionTests/D03NativeRedirectTests.swift) | 21 cases exercise ordinary Foundation HTTP without custom interception. |
| [Replay/correlation probes](../../Spikes/URLSessionInterception/Tests/URLSessionInterceptionTests/D03RedirectTests.swift) | 15 cases prove task/group identity, current decisions, native limits, timing, cancellation, consumer presentations, and no network access. |
| [Forwarding probes](../../Spikes/URLSessionInterception/Tests/URLSessionInterceptionTests/D03ForwardingTests.swift) | 30 cases bridge native proposals into the outer task and verify wire requests, refusal bodies, credential handling, and pending decisions. |
| [Protocol and consumer fixtures](../../Spikes/URLSessionInterception/Tests/URLSessionInterceptionTests/D03RedirectFixtures.swift) | Session ownership lookup, task-owned group, controlled redirect delivery, and decision observation. |
| [Forwarding fixture](../../Spikes/URLSessionInterception/Tests/URLSessionInterceptionTests/D03ForwardingFixtures.swift) | One private data-delegate hop per protocol instance on an independent executor. |
| [Loopback server](../../Spikes/URLSessionInterception/Tests/URLSessionInterceptionTests/D03HTTPServer.swift) | Actual request targets, methods, headers, and Content-Length bodies; no external service. |

The existing synchronized `D02ControlledDelivery` gains a redirect callback
under its documented recursive-lock invariant. No new unsafe sendability or
isolation annotation is introduced. Suite serialization covers the shared D03
registries, including forwarding tests declared in the same suite extension.
Other suites retain independent state.

## Apple findings

### Identity and decisions

- Automatic following, session-delegate follow/refuse/modify, assigned task
  delegates, completion handlers, async requests, and explicit async delegates
  all reach the expected redirect behavior.
- A two-hop chain retains one native task and one group through three distinct
  protocol instances. Instance serials distinguish instances without assuming
  allocator addresses cannot be reused.
- Refusal retains the original redirect response and delivers its body. The
  old protocol remains usable for that continuation. A followed branch stops
  the old protocol and starts another; its redirect body is not delivered.
- Native HTTP and custom-protocol loops both fail with
  `URLError.httpTooManyRedirects` after 21 attempts and 20 delegate decisions.
  The probe has a separate 25-visit safety bound, which is never reached on
  Apple. Diorama need not replace Apple's loop policy in these experiments.
- Identical concurrent async chains resolve to different session owners and
  group objects. Synthetic replay makes zero loopback connections, including
  an unrecorded destination that terminates with an infrastructure error.

### Request derivation and forwarding

Private forwarding supplies Foundation's proposed URL, method, and headers to
the outer task through `wasRedirectedTo`. The outer task performs the current
consumer decision. On follow, the next protocol starts a fresh private hop;
the previous hop does not independently follow. On refusal, the observer
answers the private redirect with `nil` and forwards its response/body.

POST changes to bodyless GET for 301/302/303. POST and its seven-byte body
survive 307/308. Delegate changes to the destination and to an in-memory body
reach the actual wire. The observer captures effective body context before
invoking the native redirect completion handler, avoiding a race with creation
of the next protocol instance.

Apple can expose a previously in-memory body as `httpBodyStream` in protocol
requests and native redirect proposals. The spike recovers only the body it
already owns, then stores the consumer's effective in-memory body before the
next hop. It does not adopt original caller streams. Production must preserve
the distinction between a framework-generated stream and a newly supplied,
unsupported consumer stream; this fixture is evidence for the tested
in-memory paths, not an implementation of all rejection guards.

Relative `Location: next` from `/directory/start` becomes `/directory/next`.
Multi-hop private forwarding retains all proposals. A redirect from the
loopback IP host to `localhost` removes explicit Authorization in the native
proposal and on the wire; the forwarding fixture preserves that preparation.
Native controls also observe an explicitly supplied Cookie header surviving
that redirect on both platforms. This is not a claim that Foundation removes
every sensitive caller header; DD09 preparation/redaction remains necessary.

### Pending decisions, cancellation, and timing

Native, replay, and forwarded operations remain pending with no next attempt
while the consumer holds the redirect completion handler. Explicit task
cancellation terminates with native cancellation and makes no next request.
The probes do not invoke a retained decision after cancellation; late-decision
and native callback lifetime races remain D05 work.

The replay timing probe holds a decision for 250 ms, verifies no continuation
has started, then answers it. The next instance schedules its 150 ms delivery
delay from that continuation, with a 120 ms lower-bound assertion. Caller
decision latency is not stored. This establishes the post-decision scheduling
boundary, without asserting a strict upper bound on executor scheduling time.

## Linux findings and test disposition

| Finding | Observed result | Disposition |
| --- | --- | --- |
| FN-11 custom redirect callback | Process traps instead of presenting a redirect | Required upstream repair. Disable the 45 custom/forwarding cases on stock Linux because executing them is unsafe. |
| FN-01 additional native control | Refused body reaches a data delegate, but completion result is empty | Existing required aggregation repair; add this native regression to its scope. |
| FN-12 relative target | `next` resolves to `/next` instead of `/directory/next` | Upstream repair recommended; already incorrect without Diorama. |
| FN-13 307/308 request body | Proposed POST retains body data, but next wire request has zero bytes | Upstream repair recommended; already incorrect without Diorama. |
| FN-14 cross-host Authorization | Explicit header remains in proposal and next wire request | Security-sensitive upstream repair recommended; native behavior, not caused by interception. |

The [handoff](003-D02-foundationnetworking-handoff.md) records reproductions,
source paths, and priority reasoning. FN-12–FN-14 are not silently added as
mandatory Diorama-specific interception repairs. No native redirect policy is
reimplemented to work around them. The owner can prioritize those repairs
separately; their fixes are needed before claiming the corresponding portable
redirect semantics. Patched-runtime forwarding still needs verification.

The 21 native Linux cases execute normally, with seven exact known-issue
assertions: one FN-01, one FN-12, four FN-13, and one FN-14. All other assertions
remain mandatory. Unexpected passes fail the known-issue gate.

`D03RedirectTests` contains the 45 unsafe cases, across eight test declarations.
Its Linux-only enable condition documents FN-11. Set
`DIORAMA_VERIFY_FOUNDATION_FIXES=1` on a repaired runtime to enable all original
assertions, or `DIORAMA_D03_UNSAFE_REDIRECT=1` to deliberately reproduce the
crash in an isolated process. The latter does not suppress other assertions.
Apple runs have no disabled tests or known failures.

## Verification

Toolchains: Xcode 27.0 `27A266a`, Apple Swift 6.4
`swiftlang-6.4.0.34.1`; macOS 27.0; iPhone 17 / iOS Simulator 27.0 with an
iOS 18 deployment target. Linux uses x86_64, two CPUs, 4 GiB, Ubuntu Noble,
stable `swift:6.4.0-noble` and the CI snapshot digest below. The snapshot reports
Swift 6.4.2-dev, Swift revision `d2e983b81b18217`.

| Gate | Result |
| --- | --- |
| `scripts/lint` | Pass; zero violations in 115 Swift files. |
| `Spikes/URLSessionInterception/run swiftpm` on macOS | Pass; all 66 D03 cases and 138 D01/D02 cases. |
| `Spikes/URLSessionInterception/run ios` | Pass; 54 test declarations / 204 expanded cases, zero skips or expected failures. |
| Canonical spike gate on stable Linux | Pass with known issues; 149 executed cases, including 21 D03 cases. 45 D03 cases disabled for FN-11. |
| Canonical spike gate on pinned Linux snapshot | Same disposition as stable Linux. |
| Full branch whitespace and local documentation links | Pass. |

Each Linux run reports 44 known assertion failures: D01/D02's existing 37 plus
D03's seven. These passing gates do not establish Linux redirect conformance.
The full package includes 54 Apple / 50 Linux test declarations; parameterized
cases and disabled test declarations must not be confused with those counts.
PR integration requires the hosted Quality, macOS, iOS, and Linux jobs and
Codecov checks. Those jobs run the isolated spike through its canonical entry
point; passing with the documented Linux dispositions does not establish
Linux redirect conformance. Merge order is D01, D02, then D03, with the
remaining branches restacked and required checks rerun as their bases change.

Reproduce a focused run:

```sh
swift test --package-path Spikes/URLSessionInterception \
  --scratch-path .build/urlsession-spike -Xswiftc -warnings-as-errors --filter D03
```

Reproduce either full Linux profile from the repository root with Apple
Container, substituting `swift:6.4.0-noble` for the image to test stable:

```sh
container run --rm --arch x86_64 --cpus 2 --memory 4G \
  --mount type=bind,source="$PWD",target=/source,readonly --workdir /work \
  swiftlang/swift@sha256:15ae709b1d8eb1f8691b300f5721499d007e944694f2c0e9929a55580c9bf1a5 \
  bash -lc 'mkdir -p /work/Spikes && cp -R /source/Spikes/URLSessionInterception /work/Spikes/ && cp -R /source/scripts /work/ && swift --version && Spikes/URLSessionInterception/run swiftpm'
```

## Review boundary

No DD12/DD17 semantic amendment is needed for the tested Apple approach.
Task ownership remains selected; Linux needs FN-11 in addition to the earlier
required repairs. D04 investigates authentication. D05 must prove cancellation
races, late callbacks, routing removal, and private-hop lifetime without
retaining or mutating a finished scenario. Fixture cleanup and these bounded
tests do not establish native quiescence or production readiness.
