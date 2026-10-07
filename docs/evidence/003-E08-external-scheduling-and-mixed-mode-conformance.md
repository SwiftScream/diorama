# 003-E08: External scheduling and mixed-mode conformance

- Recorded: 2026-10-07
- Status: Complete. The owner authorizes PR creation into `master` on 2026-10-07.
- Authority: The owner confirms E08's scope and requests implementation on
  2026-10-07 after reviewing its purpose and documented GPT-6 Sol, `high`
  recommendation.
- Plan: [E08](../plans/003-clean-slate-implementation.md#003-e08--external-scheduling-and-mixed-mode-conformance).
- Review base: `master` at `8458a79`, containing merged F04. The owner requests
  the initial rebase onto F04 at `6e5a9fe` on 2026-10-07; E08 is subsequently
  restacked onto its merged revision with both commit patches preserved.
- Branch: `003-e08-consumer-conformance`.
- Decisions: [DD02](../design-decisions/02-shared-vs-system-semantics.md),
  [DD06](../design-decisions/06-runtime-to-snapshot-conversion.md),
  [DD10](../design-decisions/10-lifecycle-and-ownership.md),
  [DD14](../design-decisions/14-real-time-replay-scheduler.md), and
  [DD19](../design-decisions/19-system-owned-records.md).

## Delivered proof

The separately compiled `DioramaConsumerTestSupport` target gains a test-only
timed system built entirely from public Core imports. Its open domain records
contain successive local delays, update batches, nonterminal failures, and
decision-relative responses. The domain accumulator reserves observation
time before conversion, commits only prepared values, restores observation
order when conversion completes out of order, and detaches runtime references
at freeze. An unfinished observed conversion supplies no record and invalidates
the candidate. A fully prepared open record remains valid.

The public consumer suite composes those records with capture/freeze, typed
selection, progress, consumption acknowledgement, and scheduling. It proves:

- Mixed record/replay attachments share the same time service while a
  heterogeneous passthrough attachment forwards its live value. Replay delivery
  continues while the first live conversion is suspended; the second observation
  finishes conversion first. Recorded delays lie between readings taken around
  the original observation boundaries, excluding conversion latency.
- Captured batches and a nonterminal failure freeze into a candidate, then replay
  from its actual recorded successive delays. Reaching the open horizon reports
  consumption without inventing a terminal observation.
- Finalization does not wait for consumer-owned unfinished conversion. The
  candidate is unhealthy, the draft freezes once, and its late completion is
  rejected without changing the report.
- An immediate application answer and an answer delayed by 60 ms each anchor the
  response's 25 ms delay to the current answer. Recorded application wait is not
  added to the continuation delay. Existing controlled-clock E05 cases retain
  exact early/late deadline evidence.
- Equal deadlines deliver once through an ordinary actor and the main actor.
  Tests assert isolation and consumption, without asserting executor arrival
  order. A separate awaited domain traversal establishes causal observation
  order across actor hops.
- Two executions of one setup have independent time services and claim ledgers.
  Finishing one cancels its pending work and leaves its claim unconsumed while
  the other continues delivery and consumption. Foreign captures are rejected.
- Sixteen fresh execution/teardown cycles release pending callback captures,
  preserve frozen reports, reject escaped scheduling, and retain late misuse
  diagnostics separately. Weak references prove receiver release after finish.

An internal controlled-clock integration test combines live incremental capture
and two equally due replay claims. One delivery remains suspended while the
other consumes its record. Timer cancellation establishes that finish has
closed admission; neither live freeze nor result return can occur before the
suspended delivery advances and acknowledges consumption. Pending work is
canceled, both claims appear consumed in the frozen report, and an old wake
cannot change the result or deliver another callback.

The [record-services ownership guide](../record-services.md#composing-public-services-in-a-consumer-system)
documents this composition, including domain ordering, preparation, current
anchors, actor delivery, consumption, freeze, and escaped-handle obligations.

## Verification

The table records verification before the rebase onto F04. After the
owner-requested rebase on 2026-10-07, `scripts/check` passes again: formatting,
strict lint, all 328 host tests, warning-as-error debug/release builds, and the
release example build and execution. The rebase preserves both E08 commit
patches without conflicts; `git diff --check` against F04 passes. iOS Simulator,
Linux, and coverage exports are not rerun for this rebase.

The initial PR's iOS spike gate exposes an intermittent completion failure in
the existing D02 unsupported-conversion fixture before E08's package tests run.
The [D02 CI stabilization record](003-D02-delivery-and-delegate-boundaries.md#ci-response-decision-stabilization--2026-10-07)
documents the callback-order correction and repeated Simulator verification.

| Gate | Result |
| --- | --- |
| Focused temporal consumer and Core integration suites | All nine tests pass, including both current-answer timing cases. |
| `scripts/check` | Pinned formatting and strict lint pass; all 304 host tests, warning-as-error debug/release builds, and the release example build and execution pass. |
| `scripts/coverage swiftpm macos` | All 304 tests, release builds, and example execution pass; LCOV exported. |
| `scripts/coverage ios` | Release build and all 304 tests pass on iPhone 17 / iOS 27.0 Simulator with the iOS 18 deployment floor; LCOV exported. |
| Pinned Linux reproduction | All 304 tests, warning-as-error debug/release builds, and example execution pass; LCOV exported in the container. |
| `scripts/verify-apple-toolchain` | All Xcode, Swift, SDK, and Simulator runtime pins pass. |
| Documentation and complete branch diff | Local links and anchors resolve; `git diff --check master` passes across the full proposed change. |

Apple verification uses Xcode 27.0 (`27A266a`) and Apple Swift 6.4
(`swiftlang-6.4.0.34.1`, `clang-2100.3.34.1`) on macOS 27.0 (`26A428`).
iOS execution exercises the installed iOS 27.0 runtime (`24A434`), with the
iOS 18 compile-time deployment floor. It does not claim execution on iOS 18.
Real-clock response tests require at least the recorded 25 ms delay and allow
up to three seconds of elapsed time or lateness, as appropriate to the assertion.
They do not compare exact task execution order or demand exact timer precision.

Linux uses the canonical
[Apple Container reproduction](../quality-gates-and-ci.md#local-entry-points),
with image
`swift@sha256:64bab762bc73a3fda6d9ebc559258bd6d7660c10a705bb25ecacad2f99d066f9`,
`x86_64`, two CPUs, and 4 GB memory. This is the selected Swift 6.4 / Ubuntu 24.04
CI profile. The repository is mounted read-only and package inputs are copied
into `/work`. Coverage is generated inside the ephemeral container; its LCOV
is not retained locally after the canonical `--rm` run.

Compiler and linter warnings remain errors. Xcode emits its existing metadata
extraction notice for test bundles without App Intents; the Linux example
launcher emits the previously observed `safeExec` signal 32/33 notices. No warning
exception is added. Production `Sources` do not change, so this unit has no changed production
executable lines for patch coverage; the normal platform coverage exports remain
part of the gate. Hosted required CI and Codecov evidence are obtained through
the owner's authorized PR workflow.

## Review boundary

1. `003-E08: test(core): prove external scheduling and mixed modes`: the
   external fixture, consumer conformance tests, controlled-clock integration
   test, and ownership guide.
2. `003-E08: docs(evidence): record shared service conformance`: this evidence,
   the owning plan's completed-unit status, and the documentation index link.

This unit proves composition of existing shared capabilities. Production source,
package manifests, dependencies, persistence schemas, deployment floors, and
task-ordering guarantees do not change. The test-domain records are deliberately
small ownership fixtures, not production HTTP or location models. They do not
establish native callback behavior, URLSession or Core Location conformance,
or a reusable generic behavior engine. G09, I09, and J03 retain the full
first-party integration gates.

Real-clock bounds allow normal executor lateness and do not promise hard
real-time precision. Actor arrival order remains unspecified for independent
deliveries. Finalization joins awaited delivery scopes; arbitrary application
tasks remain outside that scope. No new unsafe concurrency annotation or
warning exception is introduced. The owner authorizes PR creation on 2026-10-07.
Merge requires passing required CI for the final revision and a separate
explicit owner request.
