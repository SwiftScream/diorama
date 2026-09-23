# 003-C07: Persisted consumer-system and random conformance

- Scope and model confirmed: 2026-09-23
- Model: GPT-6 Sol, `high` reasoning
- Status: Complete locally; owner review is the next checkpoint
- Owning unit: [003-C07](../plans/003-clean-slate-implementation.md#003-c07--persisted-consumer-system-and-random-conformance)
- Governing decisions: [DD07](../design-decisions/07-persistence-boundary.md),
  [DD08](../design-decisions/08-schema-compatibility.md),
  [DD13](../design-decisions/13-random-proving-system.md), and
  [DD18](../design-decisions/18-diorama-setup-and-scenario-data.md)

## Consumer extension proof

The separate `DioramaConsumerTestSupport` target defines a persistable
consumer system entirely through public `DioramaCore` and
`DioramaPersistence` APIs. Its shared `ScenarioSystemType` carries one
version-one `PersistentSystemRegistration`; file setup discovers that
capability from the configured system. The test target has no `@testable`
import or internal access to the library.

The semantic `ConsumerStableValue` remains non-`Codable`. A private deliberate
`Codable` payload stores its integers, and its reader validates and admits each
value as already-prepared content into the typed track. The writer checks the
one-track layout. This demonstrates that persistable systems may use a schema
separate from their in-memory value type, while the existing nonpersistable
consumer system still runs in memory without a persistence capability.

The committed `consumer-three-track.json` fixture records two keyed random
systems and one consumer system. A live recording is compared byte-for-byte
with that fixture. Unknown consumer payload fields and unsupported consumer
schema versions are rejected through the public codec path.

## Integration and example boundary

The consumer conformance tests cover:

- Concurrent recording from separate random sources with distinct sequences,
  deterministic repeated publication, and complete semantic decode/encode.
- Fresh file-backed replay executions that consume independent cursors, never
  create live sources, and never write the file.
- Mixed replay, record, and passthrough modes, preserving untouched baseline
  values and replacing only the newly recorded random domain.
- Passthrough-only file execution with live values and unchanged bytes.
- Unused positions from both random and consumer tracks, random exhaustion's
  zero continuation and structured diagnostic, and read-only replay.

The existing [random usage executable](../../Examples/Sources/DioramaRandomUsage/main.swift)
keeps the beginner workflow to one random system. It now asserts equality for
both in-memory and file-backed replay and checks that replay does not publish.
The canonical `scripts/test` builds and runs it on macOS and Linux. The
[Examples guide](../../Examples/README.md) points system authors to the
compiled consumer registration and its fuller tests without putting the test
matrix in the executable.

## Verification

| Gate | Local result |
| --- | --- |
| Focused C07 tests | Six tests pass on macOS. |
| `scripts/check` | Pass: strict formatting and linting, all host tests, release library build, release example build and execution. |
| `scripts/coverage swiftpm macos` | Pass: host tests, both release builds, example execution, and LCOV export; 2,562/2,613 product lines (98.05%). |
| `scripts/coverage ios` | Pass: iPhone 17 / iOS 27 Simulator build and test, plus LCOV export; 2,562/2,613 product lines (98.05%). |
| Pinned Linux container running `scripts/coverage swiftpm linux` | Pass: tests, both release builds, example execution, and LCOV export. |

The Linux run uses the policy's pinned x86_64 Swift 6.4 image, two CPUs, 4 GiB
memory, and a read-only source mount. Its LCOV output is not retained on the
host. SwiftPM emitted two nonfatal `safeExec` signal warnings while launching
the Linux example; the executable completed its assertions. The iOS job runs
the library and test targets, not the command-line example.

## Review boundary

C07 adds no library production behavior, package dependency, public persistence
schema, or unsafe concurrency annotation. The consumer payload and fixture
are test-only. The only tooling change runs the already built example in the
canonical macOS and Linux quality paths.
