# Design decision index

This index tracks decisions produced through the completed
[design decision process](../plans/001-design-decision-process.md) and
[follow-up process](../plans/002-follow-up-design-decisions.md). No decision is
accepted without explicit owner approval. Each decision may contain smaller
review questions resolved during its discussion.

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

The initial twelve decisions and their combined
[design overview](../design-overview.md) establish the architecture and
URLSession direction. Follow-up decisions 13 through 17 resolve the proving
system, scheduler, clock, location, and concrete HTTP lifecycle needed before
synthesis of the clean-slate implementation plan.
