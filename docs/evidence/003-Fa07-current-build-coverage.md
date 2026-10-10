# 003-Fa07: Coverage from current build products

- Date: 2026-10-11
- Status: Complete.
- Plan: [003-Fa07](../plans/003-clean-slate-implementation.md#003-fa07--coverage-export-from-current-build-products)
- Authority: The owner approves this unit in the ordered Fa stack and selects
  the active session's model/settings for all seven units.

## Change

`scripts/coverage` creates a fresh private directory for each invocation under
`.build/coverage`. SwiftPM tests and the coverage-path query share its scratch
path. iOS uses its own derived data and result bundle. Discovery includes only
that invocation's products, sorted by byte order, and iOS requires exactly one
profile. Exit cleanup removes only the invocation's private directory.

The canonical commands and `.build/coverage/{macos,ios,linux}.lcov` outputs
remain unchanged. Linux exports include both Swift Testing runners and shared
test libraries; Apple exports include test bundles. Paths remain repository
relative. Ordinary `.build` output, including obsolete test binaries, is neither
read for coverage nor deleted. Coverage builds intentionally forgo incremental
compilation; coverage thresholds and upload requirements do not change.

## Regression proof

`scripts/tests/coverage` executes the actual exporter in an isolated repository
with controlled tool outputs. It retains an obsolete executable, then adds a
renamed shared library between runs. Clean and incremental invocations produce
identical LCOV, omit both stale products, and preserve both files. Assertions
check deterministic object order, all supported object layouts, relative paths,
private-directory cleanup, and failures for missing profiles and products.
The canonical `scripts/test` runs this fixture on both host platforms.

## Verification

The selected host is Xcode 27.0 (`27A266a`), Apple Swift 6.4
(`swiftlang-6.4.0.34.1`), arm64 macOS. `scripts/check` passes formatting,
strict lint, 375 tests, warning-as-error release builds, and both examples.
The initial sandboxed check cannot write SwiftLint's external cache; repeating
the same command with cache access passes.

Two consecutive `scripts/coverage swiftpm macos` invocations each pass 375
tests and export 4,698 covered / 4,789 executable lines across 56 source files.
The executable and covered line sets match, as do LCOV's `LF`/`LH` totals;
execution hit counts are not a reproducibility promise. Existing obsolete
`DioramaClockTests` artifacts remain in ordinary `.build` output and do not
enter either export. Both exports contain repository-relative source paths.

The first iOS invocation is interrupted during test startup when concurrent
platform builds put the host under memory pressure. It is not passing evidence;
platform runs are then sequenced to reduce the load.

The canonical Apple Container command in the quality policy passes with the
pinned Swift 6.4 Ubuntu image, x86_64, two CPUs, and 4 GB. All 375 tests,
warning-as-error release/example builds, both examples, and Linux LCOV export
pass. The exporter selects all six `*-test-runner` and matching `*Tests.so`
products from the isolated build.

`scripts/coverage ios` passes its standalone retry: iOS 18 deployment-target
release compilation, 374 tests on iPhone 17 / iOS 27.0, and repository-relative
LCOV export from the six current test bundles. Bash syntax and the complete
branch whitespace check pass.

Required PR checks cover formatting/lint, macOS/iOS/Linux execution, and
Codecov uploads. The local runs above do not establish minimum-platform runtime
coverage.
