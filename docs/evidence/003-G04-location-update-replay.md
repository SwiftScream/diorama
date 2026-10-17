# 003-G04 — Main-actor sequential update replay

- Date: 2026-10-18
- Status: Complete. Canonical lint and macOS, iOS, and pinned Linux gates pass.
  The owner authorizes a stacked PR on 2026-10-18.
- Scope/model: The owner authorizes G04 after opening the documentation PR and
  stacked G03B PR, using GPT-6.1 Sol at `high` reasoning. G04 has no public async
  interface. The owner also authorizes the stacked G04 PR; merging and starting
  G05 remain separate owner checkpoints.
- Base: `master` at `94d18ae`, including native materialization (PR #104) and
  the delegate-first documentation (PR #103).

## Result

`LocationUpdateReplay` is an internal MainActor update service for one
attachment. G07 will connect its synchronous delivery closures directly to the
manager's weak delegate. It has no AsyncSequence, iterator, stream buffer,
unstructured delivery task, live manager, or public attachment constructor.
`LocationUpdateReplayState` keeps the typed session lease and prepared stable
header in Core-owned state. The service obtains a claim through a protected Core
operation and runs native materialization and callbacks outside protection.

Inactive start captures a fresh logical anchor and selects the next session
with Core's sequential selector. Active start is idempotent. A failed selection
retains Core's diagnostic and becomes inert until stop; it emits neither native
failure nor synthetic completion. Stop drops pending delivery and permits a
fresh start without rolling back the prior claim. Current-location reads do not
consume anything. Several named attachments remain independent.

Only the next event is registered. Each deadline adds cumulative recorded delay
to the original start anchor. The next registration occurs after the previous
callback returns, preserving batch/failure order even when multiple deadlines
are already past. Callback lateness adds no timing drift, and zero-delay work is
never invoked inline by registration. Record identity plus event position
rejects an obsolete handoff after stop/restart; no random generation identifier
or executor-order assumption is needed.

Native locations reuse G03B and the shared normalized measurement interpreter.
Initial cache timestamps use their initial snapshot origin; session timestamps
use the persisted session-start origin plus scheduled cumulative delay minus
latency, independently of actual host delivery time. The complete batch is
materialized before delivery, and its final location becomes current before
the callback. Empty batches stay observable and leave current unchanged.
Reconstructed NSError failures are nonterminal and leave the cache unchanged.
Infrastructure diagnostics never become dependency failures.

Claims begin unconsumed. Each delivered event advances progress. Reaching the
last recorded event acknowledges consumption but leaves the open session active
and silent, without a completion callback. An empty session acknowledges its
zero-event horizon at start. Stopping before all events preserves partial
progress and an unconsumed claim. Stop within the final callback still
acknowledges the behavior just delivered; reentrant restart cannot schedule the
old session into its successor.

## Lifecycle and ownership

The selected replay mode's requestStop hook must invoke `close()` on MainActor
before Core joins scheduler delivery. The controlled test definition exercises
this production SystemModeDefinition contract. Close removes runtime ownership
before canceling pending work or releasing callback captures. Current native
location and safe diagnostic routing survive; execution services, the header,
active record, and consumer closures do not. Repeated close/stop are harmless.
Late starts diagnose closed use; installing replacement delivery after close
cannot invoke callbacks or retain an active consumer.

Scheduler closures await actor delivery within their Core-owned scope. They
capture the service weakly. A claimed handoff still waiting for MainActor checks
closed admission and does not call the consumer. A callback already executing
finishes before scheduler drainage and report freeze. Canceling a finish waiter
does not cancel that callback or return a partial report. No locks span native
consumer calls, actor hops, or capture destruction. No unsafe isolation or new
unchecked Sendable conformance is introduced by G04.

## Verification

- The behavior-preserving preparatory extraction of measurement reconstruction
  onto `LocationRecordedLocation`, with explicit spatial origins and timing
  inputs, passes all seventeen Location codec tests.
- Focused `swift test -Xswiftc -warnings-as-errors --filter
  LocationUpdateReplayTests` passes fourteen tests. Controlled time covers late
  wakeups, batch order, duplicate/cached/future measurement timestamps, initial
  state, error/recovery, empty batches/sessions, idempotent operations, fresh
  restart anchors, reentrant stop/restart, independent attachments, exhaustion,
  pending shutdown, callback capture release, and extreme pending delays.
- A real ContinuousClock case verifies that the recorded twenty-millisecond
  delay is not deliberately delivered early, without an executor-order or exact
  latency assertion.
- A controlled scheduler probe establishes a claimed handoff while MainActor is
  occupied, then closes admission before actor entry; no consumer callback runs.
  A separate gated synchronous callback keeps finish/report freeze unavailable
  until callback release, including concurrent and canceled finish waiters.
  Semaphore timeouts are failure safeguards, not elapsed-time synchronization.

### Apple verification — initial implementation

- `scripts/lint` passes repository-wide SwiftFormat and strict SwiftLint.
- `scripts/coverage swiftpm macos` passes all 549 tests, coverage fixture checks,
  public authoring/lifecycle compiler probes, warnings-as-errors Release builds,
  and examples, exporting `.build/coverage/macos.lcov`.
- `scripts/coverage ios` passes its Release build, all 548 iPhone 17 / iOS 27.0
  Simulator tests, lifecycle compiler probes, and `.build/coverage/ios.lcov`.
- Both reports cover 152/163 executable replay-engine lines (93.25%) and all
  33 executable lines in the extracted measurement reconstruction helper.
  Uncovered replay paths are defensive failures that valid prepared recordings
  exclude and the scheduler-registration failure continuation. No coverage
  threshold or test job is weakened.
- Apple toolchain: Xcode 27.0 (`27A266a`), Apple Swift 6.4
  (`swiftlang-6.4.0.34.1`, `clang-2100.3.34.1`), as verified during G03B.

### Linux verification — initial implementation

The approved Swift image runs locally through Apple Container with the same
x86_64 architecture, two CPUs, and 4 GB memory as the quality-policy command.
The repository mount is read-only; only package inputs are copied to disposable
container storage:

```bash
container run --rm --arch x86_64 --cpus 2 --memory 4G \
  --mount type=bind,source="$PWD",target=/source,readonly --workdir /work \
  swift@sha256:64bab762bc73a3fda6d9ebc559258bd6d7660c10a705bb25ecacad2f99d066f9 \
  bash -lc 'mkdir -p /work && cp -R /source/Package.swift /source/Sources /source/Tests /source/scripts /source/Examples /work/ && scripts/coverage swiftpm linux'
```

The gate passes all 487 applicable tests, coverage fixtures, public compiler
probes, strict Release builds, both examples, and LCOV export inside the
container. Location is absent from the Linux build graph. The emulated example
launcher emits the previously recorded `safeExec` signal 32/33 notices; both
examples exit successfully. No compiler/linter warning exception is added.

### Review verification — 2026-10-30

The unsquashed reconstruction fixup passes all 34 codec/capture tests at its
own revision. The restacked replay passes all fourteen update replay tests,
strict lint, and the canonical macOS coverage gate with all 549 tests, compiler
probes, Release builds, and examples. The current macOS report covers 155/166
replay-engine lines (93.37%) and all 33 shared reconstruction lines.
The pinned local Linux coverage gate also passes all 487 applicable tests,
compiler probes, Release builds, examples, and coverage export. The emulator
retains the previously documented `safeExec` signal notices.

The local iOS Release build passes. Its test run is interrupted before test
execution after the runner remains stopped waiting for debugger attachment;
this attempt does not establish an iOS test pass for the review revision.
The owner stops the retry and requests macOS-only local validation for review
fixups, leaving the full matrix to CI on push. The required PR matrix verifies
iOS and applicable Linux behavior for the integration revision. Location remains
absent from the Linux package graph.

## Review boundary

The preparatory reconstruction extraction is a behavior-preserving commit;
the 2026-10-30 review adds an adjacent, unsquashed `fixup!` that places conversion
on the recorded sample instead of the sessions track header. The fixup passes
all 34 codec/capture tests and strict lint at its own revision. Recording delegates
to the sample with its origins; replay supplies the track's spatial origins and
the selected session's timing inputs directly. Callback replay and its proving
tests form the next commit, followed by this plan/evidence update.
The complete review diff is against `master`,
including any uncommitted changes. There are no remaining uncommitted changes
at handoff. The G03/G03B implementation remains unchanged. Local links and heading
anchors plus `git diff master --check`
pass. Required PR checks are Quality, macOS, iOS, and Linux with platform
Codecov uploads. Merge requires passing checks for the PR revision and a
separate explicit owner request.

This is an internal replay capability. Public manager/delegate adoption remains
G07, access requests and notifications remain G05, origin policy/merge remains
G06, and native construction/record/passthrough evidence remains G08/G09. Tests
use real Core claims, scheduling, lifecycle, and final reports, with the existing
internal clock hook for deterministic time. They do not establish live Core
Location behavior, arbitrary Apple-framework interoperability, or behavior on
an actual iOS 18 device. No dependency, schema, deployment-floor, or production
Core API change is part of G04.
