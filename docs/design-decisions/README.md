# Design decision index

- Status: Accepted
- Consolidated design approved by owner: 2026-09-07

This index tracks decisions produced through the completed
[design decision process](../plans/001-design-decision-process.md) and
[follow-up process](../plans/002-follow-up-design-decisions.md). No decision is
accepted without explicit owner approval. Each decision may contain smaller
review questions resolved during its discussion.

The owner reaffirmed approval of all seventeen decisions and their recorded
amendments on 2026-09-07, together with the consolidated
[design overview](../design-overview.md). Individual decision dates remain
historical records; no architectural contract changes with this status update.

On 2026-09-19, the owner approved Decision 18 during the C04/C04A API review.
It separates reusable `Diorama` setup from immutable `ScenarioDefinition` data
and makes persistence operate directly on that shared in-memory model. Its
explicit reconciliation supersedes the earlier configuration meaning of
"scenario definition" in Decision 10; other earlier records retain their history.

On 2026-09-20, the owner approved Decision 18's amendment introducing shared
system-type capabilities and registry-based unknown-payload omission at startup.
Complete standalone decoding remains strict; see the amendment for its explicit
reconciliation with the earlier registration and validation rules.

On 2026-09-21, the owner approved Decision 18's consumer-module amendment:
`Diorama` owns setup and run orchestration above core and persistence, with
concrete load outcomes and one scoped result API.
The same review later narrowed the consumer import boundary, replacing
whole-module re-exports with explicit setup arguments and inferred system values.

On 2026-09-24, the owner approved [Decision 12's routing amendment](12-urlsession-scope.md#task-ownership-routing-amendment--2026-09-24):
the production URLSession adapter identifies execution ownership through native
task identity and the adapter-owned session lease, without HTTP routing fields.

The owner also approved [Decision 12's native rejection amendment](12-urlsession-scope.md#native-rejection-errors-amendment--2026-09-24)
on 2026-09-24: Apple stream and WebSocket rejection pairs an adapter diagnostic
with native cancellation, and pre-interception Linux WebSocket refusal may
retain its native error on a tested profile with no network access.

On the same date, the owner approved the FoundationNetworking
response-disposition exception in [Decision 12](12-urlsession-scope.md#foundationnetworking-response-disposition-exception--2026-09-24)
and [Decision 17](17-http-lifecycle-composition.md#foundationnetworking-response-disposition-exception--2026-09-24).
Diorama may preserve the demonstrated native live limitation without requiring
an upstream repair, while keeping recordings truthful and rejecting replay
that requires unsupported response decisions.

On 2026-09-26 the owner approved the FoundationNetworking Digest exception in
[Decision 12](12-urlsession-scope.md#foundationnetworking-digest-exception--2026-09-26)
and [Decision 17](17-http-lifecycle-composition.md#foundationnetworking-digest-exception--2026-09-26).
Preserve the demonstrated native 401 response without manufacturing a Digest
challenge. Reject replay requiring unsupported Digest capability at setup;
custom Basic challenge decisions and offline replay still require conformance.

On 2026-09-26 the owner approves the native session invalidation amendment in
[Decision 12](12-urlsession-scope.md#session-invalidation-amendment--2026-09-26)
and [Decision 17](17-http-lifecycle-composition.md#session-invalidation-amendment--2026-09-26),
reconciled with [Decision 10](10-lifecycle-and-ownership.md#native-urlsession-lifetime-exception--2026-09-26).
The returned URLSession is usable only during scenario execution; creating new
tasks afterward crashes on the tested native runtimes. No recoverable error or
diagnostic is promised before interception can run. Existing live tasks may
finish through detached forwarding; replay still requires native quiescence.

| Number | Decision | Planned file | Status |
| --- | --- | --- | --- |
| 1 | [Common abstraction](01-common-abstraction.md) | `01-common-abstraction.md` | Accepted |
| 2 | [Shared and system-specific semantics](02-shared-vs-system-semantics.md) | `02-shared-vs-system-semantics.md` | Accepted |
| 3 | [Recorded behaviors](03-recorded-behaviors.md) | `03-recorded-behaviors.md` | Accepted |
| 4 | [Replay selection](04-replay-selection.md) | `04-replay-selection.md` | Accepted |
| 5 | [Consumption and verification](05-consumption-and-verification.md) | `05-consumption-and-verification.md` | Accepted |
| 6 | [Runtime-to-snapshot conversion](06-runtime-to-snapshot-conversion.md) | `06-runtime-to-snapshot-conversion.md` | Accepted |
| 7 | [Persistence boundary](07-persistence-boundary.md) | `07-persistence-boundary.md` | Accepted |
| 8 | [Schema compatibility](08-schema-compatibility.md) | `08-schema-compatibility.md` | Accepted |
| 9 | [Normalization and redaction](09-normalization-and-redaction.md) | `09-normalization-and-redaction.md` | Accepted |
| 10 | [Lifecycle and ownership](10-lifecycle-and-ownership.md) | `10-lifecycle-and-ownership.md` | Accepted |
| 11 | [HTTP model strategy](11-http-model-strategy.md) | `11-http-model-strategy.md` | Accepted |
| 12 | [URLSession scope](12-urlsession-scope.md) | `12-urlsession-scope.md` | Accepted |
| 13 | [Random proving system and extension boundary](13-random-proving-system.md) | `13-random-proving-system.md` | Accepted |
| 14 | [Initial real-time replay scheduler](14-real-time-replay-scheduler.md) | `14-real-time-replay-scheduler.md` | Accepted |
| 15 | [Initial clock system](15-clock-system.md) | `15-clock-system.md` | Accepted |
| 16 | [Initial location system](16-location-system.md) | `16-location-system.md` | Accepted |
| 17 | [HTTP lifecycle composition](17-http-lifecycle-composition.md) | `17-http-lifecycle-composition.md` | Accepted |
| 18 | [Diorama setup and immutable scenario data](18-diorama-setup-and-scenario-data.md) | `18-diorama-setup-and-scenario-data.md` | Accepted |

The initial twelve decisions and their combined
[design overview](../design-overview.md) establish the architecture and
URLSession direction. Follow-up decisions 13 through 17 resolve the proving
system, scheduler, clock, location, and concrete HTTP lifecycle needed before
synthesis of the clean-slate implementation plan.
