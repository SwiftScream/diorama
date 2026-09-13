# 003-B04: Atomic public sequential record and replay operations

- Date: 2026-09-12
- Authority: Owner confirmation of 003-B04's scope and commencement from
  `master`, following the plan's GPT-5.6 Sol at `high` reasoning recommendation.
- Status: Complete; owner accepted the review unit on 2026-09-13.
- Prerequisites: [B03 evidence](003-B03-execution-and-lease-lifetime.md),
  [DD04](../design-decisions/04-replay-selection.md),
  [DD05](../design-decisions/05-consumption-and-verification.md),
  [DD06](../design-decisions/06-runtime-to-snapshot-conversion.md), and
  [DD13](../design-decisions/13-random-proving-system.md).

## Review boundary

This unit makes the B03 sequential lease operational. It adds a typed public
record append that reserves stable order before capture and preparation, plus a
typed public replay operation that atomically claims the next baseline record
once. It also adds structured operation failures for wrong-mode use and replay
exhaustion while retaining B03's closed-lease fact.

The record accumulator is deliberately separate from its prepared baseline.
New record-mode observations start at sequence zero and form the next working
track; they do not append their identities after baseline records. This keeps
the in-memory boundary compatible with DD07's later complete candidate
replacement and override merge without implementing persistence in B04.

## Public boundary

- `SequentialTrackLease.append(capturing:preparation:fieldPath:rule:)` reserves
  a `RecordIdentity` under the lease lock before calling consumer capture or
  the immutable preparation policy. It returns that identity only after the
  prepared stable value is admitted.
- A failed capture or preparation retains B02's safe diagnostic at the reserved
  record identity, invalidates recording health, and never reuses the position.
  Later successfully prepared observations retain their originally reserved
  order even when preparation completes in a different order.
- `SequentialTrackLease.claimNext()` atomically advances an execution-local
  cursor and returns one `SequentialRecord`. Concurrent callers cannot receive
  the same record, and a claim never returns to availability.
- `SequentialOperationFailure` exposes only the diagnostic already retained by
  the execution reporter. `SequentialOperationIssue.wrongMode` records the
  expected and actual attachment modes. `replayExhausted` records the immutable
  available count while its diagnostic context identifies the distinct stable
  requested position.
- Record operations are unavailable in replay and passthrough; replay claims
  are unavailable in record and passthrough. Wrong-mode calls do not invoke a
  record capture, reserve a position, advance a replay cursor, or touch track
  content. Closed calls retain a lifecycle diagnostic in the applicable active
  or post-finish log.
- Replay exhaustion never contacts a live dependency. B04 returns typed failure
  evidence; B07 will map that fact to Random's nonthrowing zero continuation.

## Synchronization and ordering

Each fresh lease owns one standard-library `Mutex` protecting its prepared
baseline, record reservation slots, replay cursor, and closed state. Separate
attachments and separate scenario starts therefore have independent locks and
cursors. No system-wide or random-source lock is introduced.

Record reservation appends an empty slot while holding the lock. Capture,
conversion, transformation, and validation then run synchronously on the caller
outside the lock. Successful admission fills exactly that slot. A failed slot
remains unavailable, preserving both its diagnostic identity and all later
observation positions. Candidate finalization will reject the already unhealthy
recording in its later owning units.

Replay position assignment and baseline lookup occur in one lock acquisition.
Exhausted requests also advance the cursor, so concurrent unexpected operations
receive distinct requested positions rather than collapsing onto the first
missing index. The diagnostic is retained and the optional sink is notified
only after the lease lock is released; a focused test reenters lease inspection
from that sink.

The implementation uses only checked `Sendable` types and `Synchronization`.
It adds no unsafe sendability or isolation annotation, detached task, broad
availability exception, dependency, or manifest change.

## Verification

- The focused `SequentialTrackOperationTests` suite passes seven tests covering
  reversed preparation completion, failed admission, 100 racing replay claims,
  20 concurrent exhaustion requests, reentrant diagnostic notification, mode
  and closure behavior, passthrough isolation, and independent attachments.
- `scripts/check` passes formatting, strict lint, all 45 host tests, and
  warning-free debug and release builds under the selected Apple toolchain.
- `swift test -c release -Xswiftc -warnings-as-errors` passes all 45 tests under
  optimization.
- `scripts/coverage swiftpm macos` passes all 45 tests, its release build, and
  writes `.build/coverage/macos.json`.
- `scripts/coverage ios` passes the release build and all 45 tests (62
  invocations including parameterized cases) on the selected iPhone 17 / iOS
  27.0 simulator at the iOS 18 deployment floor. The result bundle contains no
  failures, skips, expected failures, or runtime warnings. `xccov` reports
  98.85% line coverage for `DioramaCore` and 98.47% for the expanded
  `SequentialTrackLease`.
- The Linux gate passes `Spikes/ToolchainAvailability/run linux`, all 45 tests,
  the warnings-as-errors release build, and coverage export through
  `scripts/coverage swiftpm linux` in an Apple Container x86_64 guest limited
  to two CPUs and 4 GB. The guest uses the
  digest-pinned `swiftlang/swift` image
  `sha256:15ae709b1d8eb1f8691b300f5721499d007e944694f2c0e9929a55580c9bf1a5`,
  Swift 6.4.2-dev (LLVM `15622a86b1749a9`, Swift `d2e983b81b18217`), and
  `libcurl4-openssl-dev` 8.5.0-2ubuntu10.13. The repository is mounted read-only
  and copied to an isolated directory inside the ephemeral guest before the
  gate runs.
- Local Markdown targets exist and the complete B04 diff passes
  `git diff --check` against `master`.

The B04 pull request passes the required hosted Quality, macOS, iOS, Linux, and
Codecov checks. Local simulator and host executions do not establish runtime
behavior on actual macOS 15 or iOS 18 installations.

[PR #10](https://github.com/SwiftScream/diorama/pull/10)'s first two iOS runs
exposed test-worker starvation. The first run timed out both the B04 ordering
test and B02's blocked-sink handshake while they competed for shared dispatch
and cooperative workers. The B04 test now drives reversed preparation completion
through a synchronous reentrant append, proving the same reservation invariant
without occupying a blocked worker. The second run passed the complete B04
suite but showed that the older sink test's global dispatch work could still
start after its five-second deadline. A test-only prerequisite commit gives that
deliberately blocked callback a dedicated thread instead. The unchanged
production implementation and both revised tests pass the subsequent hosted
run.

The focused tests use `@testable` only to inspect the separation and ordering
of baseline and working-record storage. Every operation and failure type under
B04 review is public. B05 remains responsible for proving that a separate
consumer module can build a complete synchronous system through public API
alone.

## Exclusions and next boundary

B05 supplies the external-module consumer-system proof and may request only
narrow corrections demonstrated by that proof. Domain matching, grouped
lifecycle trees, timing, reusable or cardinality policies, Random's live source
and nonthrowing continuation, unused-record evaluation, persistence, and native
adapters remain in their owning units. No later unit is started by completion
of B04.
