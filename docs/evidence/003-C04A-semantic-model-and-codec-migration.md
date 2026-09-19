# 003-C04A: Semantic model and codec migration

- Plan: [003-C04A](../plans/003-clean-slate-implementation.md#003-c04a--semantic-model-and-persistence-migration)
- Design: [DD18](../design-decisions/18-diorama-setup-and-scenario-data.md)
- Scope confirmed by owner: 2026-09-19
- Status: Implementation and local platform verification complete on 2026-09-20;
  owner review is the next checkpoint.
- Model: GPT-6 Astra, `high` reasoning

## Ownership and API

`ScenarioDefinition` contains only immutable ordered attachments and prepared
tracks. `ScenarioAttachment` no longer carries a mode. Diagnostic identity,
default mode, whole-attachment overrides, and ignored-key verification policy
live in `ScenarioConfiguration`. System preparation closures and live factories
remain on runtime system declarations; neither semantic model stores them.

The existing low-level execution APIs now take configuration explicitly:

```swift
let configuration = ScenarioConfiguration(
    id: ScenarioID(rawValue: "fixture"),
    defaultMode: .replay,
    modeOverrides: [recordingKey: .record],
    ignoredAttachments: [optionalKey])
let definition = try codec.decode(bytes)
let execution = try ScenarioExecution.start(
    definition: definition,
    configuration: configuration,
    systems: systems)
let result = await execution.finish()
```

For scoped execution, use
`definition.execute(configuration: configuration, with: system) { dependency in ... }`.
Its body outcome, caller isolation, cancellation, and finalization behavior are
unchanged. `DiagnosticReporter` takes `scenarioID` separately from the definition
whose attachment/track identities determine ordering. It still retains no values.

Configuration validates ignored keys and override keys against the active
layout, in lexical order within each policy category. Invalid policy stops
startup before preparation or activation. Repository startup also validates
policy before reading storage and retains its exact configuration error.

The low-level repository entry point is now
`repository.start(configuredBy: configuration, layout: layout, systems: systems)`.
The explicit layout and one-to-one runtime registrations remain separate inputs
in this slice. Its content is never a fallback for missing or unusable storage.
Loaded content is authoritative, unmatched attachments are diagnosed/discarded,
and absent nonreplay attachments receive empty typed layouts. Any required replay
still refuses missing, invalid, incompatible, or otherwise unusable input before
activation. Startup never publishes.

`removingRecords()` and `replacingBaseline(with:)` derive new semantic values
without modifying their inputs. Baseline reconciliation takes an already
validated `ScenarioDefinition`; repository policy separately checks replay
membership and diagnoses omissions.

## Persistence boundary

The public `PersistedScenario` wrapper is removed. `JSONScenarioCodec.encode`,
`decode`, repository load results, and repository `publish` all use
`ScenarioDefinition` directly. The codec's `schemaVersion` is the public envelope
version constant. The deliberate `Codable` envelope remains internal to
`DioramaPersistence`; `ScenarioDefinition` has no `Codable` requirement.

The JSON v1 bytes and registration/version rules are unchanged. Existing
canonical fixtures are untouched. Decoding still validates prepared values
without rerunning capture transformations. Every loaded payload, including
unmatched and ignored systems, still requires its registered schema reader.
Nonpersistable consumer values remain valid for in-memory execution; encoding
without a required registration still fails at the persistence boundary.

## Evidence

The migration updates the existing core, random, consumer-module, persistence,
and compiled-example callers to pass explicit policy. Existing tests retain
their mode, lifecycle, ordering, concurrency, ownership, validation, and byte
assertions. New focused tests prove:

- A decoded definition starts directly under independent record/replay policies
  and diagnostic identities, with an attachment override and ignored usage.
- Recording and replay leave the input's canonical bytes unchanged. A later
  replay starts again at the first value.
- Unknown ignored/override keys refuse core startup before system callbacks.
- Repository policy errors refuse startup before storage reads or writes.
- Unknown overrides are selected deterministically in lexical order.

## Verification

All local required gates pass:

| Command | Result |
| --- | --- |
| `swift test -Xswiftc -warnings-as-errors` | All 152 test functions pass, including parameterized cases. |
| `scripts/check` | SwiftFormat, strict SwiftLint, debug tests, library release build, and example release build pass. |
| `scripts/verify-apple-toolchain` | Installed Xcode 27.0 build `27A266a`, Apple Swift 6.4 `swiftlang-6.4.0.34.1`, and required SDK/simulator versions match the pin. |
| `scripts/coverage swiftpm macos` | 152 tests pass; library/example release builds and LCOV export pass. |
| `scripts/coverage ios` | iPhone 17 / iOS 27.0 Simulator release build, 152 tests, and LCOV export pass with iOS 18 deployment target. |
| Pinned Apple Container command below | Linux x86_64 debug tests (152), library/example release builds, and LCOV export pass. |
| `swift run --package-path Examples -c release DioramaRandomUsage` | Printed recorded and replayed sequences match exactly. |
| `scripts/lint` after final API-comment edits | Zero violations across 71 Swift files. |
| Local Markdown links and `git diff --check master` | All 96 checked local link targets exist; complete branch whitespace check passes. |

macOS and iOS each cover 2,236 of 2,284 executable source lines (97.90%).
The local macOS LCOV comparison against added executable source lines in the
complete branch diff covers 104 of 104 lines (100%). This is local evidence,
not a hosted Codecov status. Linux generated LCOV inside its disposable container;
that artifact was not copied back to the host.

The Linux run uses the exact policy image, architecture, and resource limits:

```sh
container run --rm --arch x86_64 --cpus 2 --memory 4G \
  --mount type=bind,source="$PWD",target=/source,readonly \
  --workdir /work \
  swiftlang/swift@sha256:15ae709b1d8eb1f8691b300f5721499d007e944694f2c0e9929a55580c9bf1a5 \
  bash -lc 'mkdir -p /work && cp -R /source/Package.swift /source/Sources /source/Tests /source/scripts /source/Examples /work/ && scripts/coverage swiftpm linux'
```

Compiler/Mint caches, CoreSimulator, and Apple Container require execution
outside the workspace sandbox; the successful commands use the normal local
environment after sandbox permission failures. No tool pin, warning rule,
availability floor, or concurrency setting changed. iOS results prove deployment
target compilation and current Simulator behavior, not an iOS 18 device run.
Hosted CI and Codecov upload evidence require the separately authorized PR
workflow; no remote write is part of this implementation review.

## Review boundary

The owner confirmed C04B as the separate reusable typed `Diorama` setup unit.
It will make systems authoritative for layout, retain typed declarations once,
and provide the distinct baseline constructors. This migration preserves
explicit low-level composition without implementing that convenience early.
C05 owns complete resulting definitions and finalization-driven publication;
the existing explicit repository `publish` operation merely accepts the shared
semantic model here. No production dependency, native system, result builder,
or concurrency exception is introduced.

The feature branch is based on `master` at `a69768f`. Its existing `2963b38`
commit records the accepted DD18 design. The implementation, proving tests,
example, schema/API documentation, and final plan/evidence updates form one
coherent migration commit on top. Full review includes both commits and any
uncommitted changes via `git diff master`.
