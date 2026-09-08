# 003-B02 prerequisite: macOS 15 and iOS 18 deployment floors

- Date: 2026-09-09
- Authority: The owner's explicit request to raise the deployment targets,
  commit the change as a separate prerequisite, and amend B02 to use `Mutex`
  directly.
- Policy: [2026-09-09 deployment amendment](../quality-gates-and-ci.md#apple-deployment-minima--owner-approved-amendment-2026-09-09).
- Status: Complete locally; final B02 platform gates and hosted integration evidence are recorded separately.

`Package.swift` now declares macOS 15 and iOS/iPadOS 18. The canonical
`scripts/coverage ios` command uses `IPHONEOS_DEPLOYMENT_TARGET=18.0`, so local
and hosted iOS checks compile with the same floor. The supported platforms
remain macOS, iOS, and Linux; the existing Swift/Xcode pins do not change.

The selected SDK declares `Synchronization.Mutex` available from macOS 15,
iOS 18, tvOS 18, watchOS 11, and visionOS 2. The policy records corresponding
availability floors for any separately approved future Apple platforms without
adding them to the support matrix. This permits the B02 implementation commit
to remove its platform-specific `Locked<State>` wrapper and use `Mutex`
directly. No library runtime behavior changes in this prerequisite commit.

Repository guidance, the architecture overview, and remaining plan acceptance
criteria now refer to the new supported floors. The earlier deployment-policy
amendment, completed evidence, and A01 clock probes retain their historical
values. Their successful lower-floor probes are still valid evidence of those
APIs, but do not describe the current package support promise.

## Verification

Using the selected Xcode 27.0 beta 6 / Apple Swift 6.4 toolchain:

- `scripts/check` passes formatting, strict lint, all nine B01 tests, and
  debug/release builds with warnings as errors on this prerequisite alone.
- `swift package dump-package` reports iOS `18.0` and macOS `15.0`.
- A standalone `Mutex(0)` probe mutates and reads its value with `withLock`.
  It compiles, links, and runs targeting `arm64-apple-macosx15.0`, and
  typechecks with the simulator SDK targeting `arm64-apple-ios18.0-simulator`.
  Positive checks use Swift 6 and complete strict concurrency with warnings
  as errors.
- The same probe fails typechecking at macOS 14 and iOS 17 with explicit
  `Mutex` and `withLock` availability diagnostics. These expected failures
  establish the new floor's purpose.
- Bash syntax, local documentation links, and branch whitespace checks pass.

Final B02 platform evidence belongs to the amended implementation commit.
Actual macOS 15/iOS 18 runtime execution is not implied by compilation at
those floors on the installed macOS/iOS 27 runtimes. Hosted checks await the
owner-authorized PR workflow.
