# Interaction primitives and first-party HTTP requirements

- Status: Resolved by DD19, accepted by the owner on 2026-10-06.
- Recorded: 2026-10-06, during review of 003-E05.
- Review gate: Resolved by DD19 acceptance alongside the revised E05 implementation.
- Scope: The purpose of the shared interaction model, its relationship to HTTP,
  and the evidence needed to justify core primitives.

## Accepted resolution — 2026-10-06

[Decision 19](design-decisions/19-system-owned-records.md) compares the concrete
HTTP representations, recommends system-owned records over shared execution
services, and reconciles the earlier decisions. The owner subsequently requests
that recommendation, delivery-plan revisions, and the corresponding refactor
before discussion, superseding this note's earlier stop-before-implementation
checkpoint for that review work. The original investigation below remains its
historical brief. The owner accepts DD19 and authorizes PR creation on
2026-10-06, closing this investigation gate.

## Question and recommendation

Should HTTP use the existing `InteractionRecording` model, a revised shared
interaction model, or a domain-specific recording backed by shared core services?

Use HTTP as the proving case before extending the interaction APIs. Compare
concrete representations of the first-party HTTP lifecycle, derive the required
primitives from those examples, and retain `InteractionRecording` only if HTTP
meaningfully uses it. A synthetic consumer system can prove that a public API is
usable, but does not establish a first-party need for that abstraction.

The owner wants primitives that support the first-party systems. Consumer
systems should be able to reuse the resulting public infrastructure; hypothetical
consumer behavior should not independently drive additional abstractions.

This note records the consideration and recommended investigation. The accepted
decisions continue to govern implementation until the owner explicitly approves
any amendment and corresponding plan changes.

## Architectural sources

- [Decision 2](design-decisions/02-shared-vs-system-semantics.md) separates shared
  invariants, reusable capabilities, domain models, and native adapters.
- [Decision 3](design-decisions/03-recorded-behaviors.md) requires correlated
  interactions and subscriptions with one explicit recording conclusion.
- [Decision 4](design-decisions/04-replay-selection.md) assigns matching to the
  system and prohibits live replay fallback.
- [Decision 5](design-decisions/05-consumption-and-verification.md) distinguishes
  whole-recording use from internal lifecycle progress and completion.
- [Decision 14](design-decisions/14-real-time-replay-scheduler.md) provides
  execution-owned scheduling, prerequisites, cancellation, and quiescence.
- [Decisions 15](design-decisions/15-clock-system.md) and
  [16](design-decisions/16-location-system.md) define the clock and location needs.
- [Decision 17](design-decisions/17-http-lifecycle-composition.md) requires a
  strict recursive HTTP lifecycle, message ownership, partial bodies, and local
  timing that excludes application decision latency.
- [Plan 003](plans/003-clean-slate-implementation.md) sequences accumulation,
  selection, delivery, and first-party domain implementation.

## First-party requirements

These requirements come from the accepted designs; the table does not imply
that all of the listed systems and capabilities are implemented.

| System | Required core behavior | Recording shape |
| --- | --- | --- |
| Random | Atomic append, sequential single-use claims, mode handling, finalization, and unused-value reporting. | Sequential values. |
| Wall clock | Sequential observation claims and a shared scheduler for the separate monotonic clock facet. | Wall origin and successive observations; monotonic reads and sleeps are not persisted interactions. |
| Location | Claim an update session, deliver ordered batches and nonterminal errors, preserve an open horizon, and cancel delivery safely. Access state also needs ordered authorization-request barriers. | Update subscriptions and a separate access lifecycle. |
| HTTP/URLSession | Match and claim one operation, correlate responses and decisions, schedule reachable continuations, deliver bodies, preserve failed/open progress, and finalize safely. | One observed HTTP interaction, potentially containing several phases. |

HTTP is the first-party system that should establish the purpose and shape of
interaction infrastructure. The current `InteractionRecording` is exercised by
core tests and a synthetic public consumer test, rather than an implemented
first-party system. Random and wall observations use sequential claims; the
planned location update model uses subscriptions.

## One observed interaction, not alternative possible histories

The accepted recursive HTTP model stores the path actually observed. An enum
declares possible forms, but an individual recording contains only its selected
form and observed continuation. It does not store all possible challenge or
redirect responses.

For example, one recording could contain:

```text
initial request
  -> 401 response and authentication challenge
  -> recorded credential decision
  -> retry
  -> 302 response and redirect
  -> recorded follow decision
  -> final response head and body deliveries
  -> completion
```

The whole operation is selected and claimed once. An incompatible current
decision produces a replay infrastructure diagnostic; it does not choose an
unrecorded alternative or contact the live dependency.

Both nested continuations and an ordered phase representation could describe
this particular history. Their comparison should focus on ownership, valid
states, timing, authoring, and replay behavior.

## Gaps in the current interaction primitive

### HTTP timing

The existing `InteractionAccumulator` (the historical E04 implementation)
captures observations, decisions, and conclusions at offsets from invocation.
HTTP requires successive local delays and starts delivery after a decision
from completion of the current replay decision. Application decision latency
is not persisted.

```text
Recording:
  challenge delivered at 100 ms
  application answers at 600 ms
  next response arrives at 650 ms

Relevant continuation delay:
  answer -> next response = 50 ms

Replay:
  application answers at 2 seconds
  next response arrives at 2.05 seconds
```

Retaining a 650 ms invocation deadline and merely waiting for the late decision
would make the continuation immediately eligible after the answer. That loses
the recorded 50 ms delay. A representation and its capture/delivery helpers
must preserve the decision-relative timing required by DD17.

### Domain relationships and valid states

The current `InteractionRecording` (the historical E04 implementation)
contains an input, phases pairing an observation with an optional decision,
and a returned/failed/open conclusion. Its validation checks timing order.

HTTP additionally needs to associate each challenge or redirect with the
response that caused it, validate the compatible decision and continuation,
retain a partial body on failure or an open horizon, and own each message and
body exactly once. Instantiating the generic observation and decision types
with HTTP enums does not by itself enforce those relationships.

This does not prove that a phase model is unsuitable. It identifies the domain
rules and strict construction boundary that such a model must provide. The
current generic initializer does not provide that HTTP boundary.

### Shared recording lifetime

The [track lease](../Sources/DioramaCore/SequentialTrackLease.swift) already has
a private mechanism to reserve an ordered position at invocation and freeze a
domain accumulator at finalization. Its public accumulation methods construct
the current interaction and subscription models.

If HTTP keeps a domain-specific recording, it needs a supported way to reuse
the reservation, preparation, freeze, health, and detachment guarantees. This
is a concrete first-party requirement for shared infrastructure. The exact
public boundary remains to be designed and proved with HTTP.

## Representations to compare

### Accepted recursive HTTP model

Responses own their body, redirect, or authentication continuation. Typed
mutually exclusive cases express the legal lifecycle, and the final leaf owns
the returned, failed, or open state. There is no competing top-level conclusion.

This is the current DD17 requirement. Reuse of shared claim, capture, scheduling,
and reporting services can be assessed without changing that recording shape.

### Candidate ordered HTTP phases

Explore one initial request, an ordered sequence of continuing HTTP phases,
and the current attempt's outcome. Each phase must own its response, observed
decision, and relevant timing without duplicating messages.

The distinction between continuing and concluding behavior matters. Following
a redirect permits another attempt. Refusing it delivers that response's body.
An unanswered redirect leaves the interaction open at that phase. A strict
phase representation must express those cases and prevent incompatible later
phases from being constructed or admitted.

This is a candidate for comparison, not an approved schema or proposed final
Swift API. Whether it can use a revised `InteractionRecording` meaningfully is
part of the investigation. Adding a generic wrapper around an otherwise
complete HTTP model is insufficient evidence of useful reuse.

## Concrete comparison cases

| Recorded case | Required evidence |
| --- | --- |
| Successful response without decisions | One initial request, response head, exact body, delivery profile, and completion, with no duplicated authoritative content. |
| Authentication challenge, redirect, and successful response | Correct response/decision association, request derivation, phase order, and local continuation delays. |
| Refused redirect | The redirect response becomes the delivered response, including its body; no subsequent attempt follows. |
| Canceled authentication challenge | The challenge disposition and resulting dependency failure remain recorded once. Caller task cancellation remains separate runtime control. |
| Failure before a response | One timed failure, with no invented head or body. |
| Failure during body delivery | The response head, exact delivered prefix, segmentation profile, and one failure remain available. |
| Unanswered challenge or redirect | The observed response and phase remain intact, with a pending decision and explicit open horizon. |
| Open body delivery | The head and observed prefix remain intact, without a manufactured completion. |
| Early or late replay decision | Subsequent delivery respects the current decision anchor, avoids reentrant delivery, and excludes recorded application latency. |
| Edited body or delay and re-recording | Weighted segmentation, deliberate timing overrides, and compatible-path override retention remain deterministic. |

Include the native response-disposition phase where observed. Its allow,
cancel, and unanswered cases must preserve the same ownership and timing rules,
and setup must reject recordings requiring unsupported bridge capabilities.

For each representation, show the stable values and construction/validation
rules, how recording freezes partial work, and how replay advances through the
observed path. A simple successful GET alone cannot establish suitability.

## Recommended approach and E05 review gate

1. Compare the two concrete HTTP representations against the cases above and
   the accepted body, timing, capability, and override contracts.
2. Identify every shared primitive's first-party consumer and the invariant it
   enforces. Preserve the public system extension boundary by proving those
   same services usable from a consumer module.
3. Decide whether to revise `InteractionRecording` for demonstrated HTTP reuse
   or retain an HTTP-specific recording and share its infrastructure. Identify
   any existing helpers that should be revised or deferred.
4. Resolve public terminology after establishing those boundaries. Semantic
   names such as interaction and subscription can help, but should not make
   an interaction API accidentally exclusive to one concrete recording struct.
5. Record owner-approved architectural changes as a DD17 amendment or a new
   accepted decision, with explicit reconciliation of affected earlier
   decisions. Update the owning plan and affected evidence accordingly.
6. Confirm any revised implementation slices, then complete E05 review against
   the resolved requirements. Do not silently implement a new architecture
   inside the existing selection review.

E05's system selection and atomic claim machinery has direct first-party
motivation: HTTP matches operations and location selects update sessions. The
already merged claim-bookkeeping prerequisite remains useful. This review
gate concerns the remaining public contract and its relationship to lifecycle
models; it does not conclude that the common claim machinery should be removed.

## Decisions still required

- Which concrete recording representation best satisfies the HTTP cases and
  existing architectural invariants?
- Does HTTP use `InteractionRecording` sufficiently to justify that public
  type, and what changes to it and its accumulator would be required?
- Which capture, freeze, timing, and decision services belong in core, and
  which remain HTTP-specific?
- What public claim and progress terminology describes the first-party use
  clearly while preserving the accepted extension boundary?
- Which accepted decisions, evidence documents, and E04-E08/H-phase plan units
  need reconciliation before E05 review can conclude?

Resolution requires an explicit owner-approved answer to these questions and
an agreed breakdown of any resulting work. This document does not authorize
production changes or assert that either candidate has been implemented or
verified.
