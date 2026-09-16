# 003-B11: In-memory random usage example

- Date: 2026-09-16
- Plan: [003-B11](../plans/003-clean-slate-implementation.md#003-b11--in-memory-random-usage-example)
- Status: Complete locally; owner review is the next checkpoint.
- Authority: [Decision 10](../design-decisions/10-lifecycle-and-ownership.md),
  [Decision 13](../design-decisions/13-random-proving-system.md), the
  [quality gates and CI policy](../quality-gates-and-ci.md), and the owner's
  2026-09-16 scope confirmation.

## Delivered example

`DioramaRandomUsage` is an executable product in the separate examples package,
with source at `Examples/Sources/DioramaRandomUsage/main.swift`. Its
`Examples/Package.swift` depends on its parent Diorama package by an explicitly
named relative path.
Diorama's main `Package.swift` therefore retains only library products.

The example imports only `DioramaCore` and `DioramaRandom`. It creates one
named random system with its default live source, records five values through
the variadic scoped-execution API, explicitly prepares those stable values into
a fresh in-memory replay definition, then replays the same sequence. Both
scoped executions finalize before the result is printed.

The example does not represent a record-to-replay transfer API. Phase B has no
persistence or public candidate export; Phase C owns that vertical path. The
explicit preparation step is therefore both a valid in-memory replay input and
a visible boundary rather than a persistence substitute.

## Verification

- `swift build --package-path Examples -c release -Xswiftc -warnings-as-errors`
  passes.
- `swift run --package-path Examples DioramaRandomUsage` prints identical
  recorded and replayed sequences.
- `scripts/test` compiles the examples package with warnings as errors after its
  normal test and release-build gate, so the macOS and Linux coverage paths
  build it through the same canonical entry point.
- `scripts/coverage ios` remains the main library package's iOS 18 release
  build, simulator test, and LCOV gate; it passes. The standalone command-line
  example is not an iOS executable product.
- The canonical Apple Container Linux reproduction copies `Examples` alongside
  the root package inputs so its `scripts/test` stage builds the examples
  package; the final Linux run passes all 85 tests, both release builds, and
  LCOV export.

No test-framework integration, persistence behavior, third-party dependency,
or executable product in Diorama's main package is introduced.
