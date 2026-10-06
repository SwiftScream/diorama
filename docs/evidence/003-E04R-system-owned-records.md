# 003-E04R: System-owned incremental records

- Recorded: 2026-10-07
- Status: Complete; the owner authorizes a separate E04R PR on 2026-10-07.
- Authority: Accepted DD19 and the owner-requested split from the stacked E05 work.
- Decision: [System-owned records](../design-decisions/19-system-owned-records.md).
- Plan: [E04R](../plans/003-clean-slate-implementation.md#003-e04r--system-owned-incremental-records).
- Base: `master` at `6e1cf4c`; branch `003-e04r-system-owned-records`.

## Delivered boundary

`record(capturing:preparation:)` captures and admits a complete value immediately.
`beginRecord(preparation:capturing:freeze:)` reserves an ordered position and
returns a system-owned `Sendable` accumulator. Core invokes its freeze closure
once at finalization and validates the complete prepared value without repeating
capture transformations. Both paths share ordered track storage.

The change removes Core's generic interaction/subscription models, accumulators,
and model-specific diagnostics. The domain owns strict state transitions,
synchronization, prepared observations, late-call rejection, and resource
release. A nil freeze result or unfinished capture invalidates the candidate;
a valid domain value represents an intentionally open operation.

Construction and freeze run outside the lease state lock. A successful factory
that returns after admission closes is still frozen once for cleanup, while its
record is discarded. The factory owns cleanup if it throws before returning.
The lease no longer retains execution time merely to construct generic helpers;
systems obtain time through their preparation context.

This PR includes the accepted architecture for the complete redesign, but only
implements recording services. `ReplaySelector`, matched claims, `consumeNext`,
`markConsumed`, and claim/consumption evaluation are delivered by E05. This
boundary retains the existing `claimNext` replay API until that stacked change.
The public-consumer recursive capture-and-selection proof also remains in E05.
No production HTTP/location model, adapter, dependency, unsafe isolation,
deployment-floor increase, or persistence-schema change is introduced.

## Verification

`RecordCaptureTests` covers nested registration, ordering alongside immediate
recording, freeze once outside isolation, prepared validation without repeated
transforms, factory/preparation failure, nil freeze, wrong mode, late admission,
finish racing a blocked constructor, callback release, and immutable final reports.
Existing immediate-recording consumers exercise the renamed `record` API.

The rebase onto `6e1cf4c` preserves the reviewed E04R recording refactor and
integrates master's generic random-source implementation and shared-reference
regression test. The plan retains both DD19's Phase E boundary and the new F03A
unit. Verification runs without E05 source or test files.
`scripts/check` passes formatting, strict lint (zero violations across 166 Swift
files), all 267 host tests, warning-as-error debug/release builds, and example
execution on Xcode 27.0 / Swift 6.4. This is the standalone E04R result, not the
280-test combined E04R/E05 result recorded during the earlier review.

Required platform and coverage checks use the repository's canonical PR workflow;
merging still requires passing checks and a separate owner request.

## Review sequence

1. `003-E04R: docs(core): define system-owned record services`: accepted redesign,
   DD19 amendments, domain ownership, and revised delivery plan.
2. `003-E04R: ref(core): let systems own incremental records`: generic-helper
   removal, ordered capture/freeze, the `record` name, and recording tests.
3. `003-E04R: docs(evidence): complete standalone recording refactor`: E04R-only
   completion evidence and an implementation guide matching this branch.

E05 remains a separate stacked PR. Its merge is not implied by E04R approval.
