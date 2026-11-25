# 003-I03A — Shared URLSession recording transport

The owner confirms this unit stacked on
[I03](003-I03-native-urlsession-failures.md).

## Ownership and shutdown

Each recording attachment creates one private forwarding `URLSession` during
activation. It retains the private configuration used in I03, including native
timeouts, disabled caching, and consumer protocol classes in their original
order. Replay allocates no private transport. Passthrough uses its native
session.

The attachment's serial forwarding queue orders task creation, cancellation,
and graceful invalidation. A task has a route before it resumes. The private
session's serial delegate queue uses native task identity to select the
aggregate response, recording observation, and live delivery for each
callback. Terminal delivery removes that task's route.

Finish removes execution routing and explicitly detaches weak recording
observations before gracefully invalidating the private session. Finalization
can return while a live task is still pending. Its route holds the state needed
to deliver the native result. It no longer refers to the recorder or its
capture handle. Startup rollback follows the same shutdown path.

## Native conformance cases

- Hold three requests concurrently and observe all three native tasks in one
  private session. Cancel one, then release the other two one at a time and
  check that each caller receives its own bytes. The canceled record freezes
  open.
- Start two independently keyed attachments in each of two successive
  executions of the same setup and observe four distinct private sessions.
- Hold a live response across finish and observe that the owner drops the
  private session while the request is still waiting for the origin. Release the
  response, verify its bytes, and observe private session deallocation. The
  recording stays open at the horizon. The late failure case verifies native
  error delivery at the same boundary.
- Fail a later attachment's factory, then verify that rollback removes the
  earlier attachment's outer routing and releases its private session.

## Verification

The macOS gate passes 884 tests, strict formatting and lint, compiler probes,
release builds, and the Random and Date examples. The iPhone 17 Simulator
passes 883 tests and its lifecycle compiler probes. Mac Catalyst passes all 65
URLSession tests. Both Xcode coverage gates complete their release builds and
export LCOV. The native HTTPS trust check passes on all three platforms.

The four focused ownership cases also pass 25 repetitions each on macOS. The
runs use Xcode 27.2 (27B52), Swift 6.4.2, macOS 27.2.1, and the iOS 27.2
simulator runtime. Both Xcode gates compile at deployment target 18.0.

```sh
swift test -Xswiftc -warnings-as-errors --filter SessionBridgeTests
DIORAMA_I02_HTTPS=1 scripts/check
TEST_RUNNER_DIORAMA_I02_HTTPS=1 scripts/coverage ios
TEST_RUNNER_DIORAMA_I02_HTTPS=1 scripts/coverage catalyst
swift test --skip-build --filter 'SessionBridgeTests.*(overlapping|successive|releases|rolls)' \
  --maximum-repetitions 25 --repeat-until fail
```
