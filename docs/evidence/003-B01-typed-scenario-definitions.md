# 003-B01: Typed scenario definitions and track identity

- Date: 2026-09-09
- Plan: [003-B01](../plans/003-clean-slate-implementation.md#003-b01--typed-scenario-definitions-and-track-identity)
- Status: Complete; local and hosted quality and platform gates pass.
- Authority: [DD01](../design-decisions/01-common-abstraction.md),
  [DD02](../design-decisions/02-shared-vs-system-semantics.md),
  [DD03](../design-decisions/03-recorded-behaviors.md),
  [DD04](../design-decisions/04-replay-selection.md),
  [DD10](../design-decisions/10-lifecycle-and-ownership.md),
  [DD13](../design-decisions/13-random-proving-system.md), and 003-B01.

## Delivered boundary

`DioramaCore` now exposes distinct stable values for scenario identity, system
type, attachment key and identity, track key and identity, and complete record
identity. A record identity combines its track identity with a zero-based
`UInt64` sequence. The sequence is not wrapped in another identifier type.

`ScenarioMode` supplies the common record, replay, and passthrough vocabulary.
An immutable `ScenarioDefinition` retains the default mode and deterministic
attachment declaration order. Each immutable `ScenarioAttachment` may override
the mode for all its tracks; individual tracks cannot select another mode.

`SequentialTrack<Value>` retains typed, sendable values in deterministic order
and assigns their stable sequences from zero. `Value` does not require
`Codable`. An attachment can own multiple tracks with different value types.
Private type erasure permits heterogeneous storage while typed lookup restores
the declared value type.

Definition construction rejects duplicate attachment identity and reuse of one
attachment key for different system types. Attachment construction rejects a
track belonging to another attachment, duplicate track identity, and reuse of
one track identity for different value types. Empty definitions, attachments,
and tracks remain valid.

The unit adds no mutable execution, replay claim, scheduler, diagnostic,
persistence, JSON, HTTP-specific value, dependency, generic metadata bag, or
unsafe concurrency exception.

## Verification

The final implementation behavior passes these local checks with Xcode 27.0
beta 6 and its selected Swift 6.4 toolchain:

- `scripts/check`: SwiftFormat and strict SwiftLint pass; all nine Swift Testing
  cases pass with warnings as errors; the release build passes.
- `scripts/coverage swiftpm macos`: the same tests and release build pass and
  produce the discovered macOS coverage report.
- `scripts/coverage ios`: `DioramaCore` compiles for the iOS 16 simulator
  deployment target; all nine tests pass on the iOS 27 simulator; `xccov` reads
  the result bundle.
- The digest-pinned Swift 6.4 Linux image selected by 003-A01 passes all nine
  tests and the release build on x86_64 with warnings as errors.
- `git diff --check` reports no whitespace errors across the complete branch
  diff.

The first local emulated Linux attempt used the container runtime's default
1 GB memory allocation and failed to emit one object file without a Swift
source diagnostic. Repeating the same digest-pinned image with 4 GB and two
build jobs passed. The hosted Linux job subsequently passed without this local
resource constraint.

[Hosted run 34239286873](https://github.com/SwiftScream/diorama/actions/runs/34239286873)
for PR #6 passes Quality, macOS, iOS, and Linux, including all three required
coverage uploads to Codecov. No required check is skipped, and no unresolved
design or dependency gate remains for 003-B01.
