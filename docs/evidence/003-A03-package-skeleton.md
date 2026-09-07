# 003-A03: Minimal package skeleton

- Date: 2026-09-07
- Plan: [003-A03](../plans/003-clean-slate-implementation.md#003-a03--minimal-package-skeleton)
- Status: Complete
- Authority: [003-A01 toolchain evidence](003-A01-toolchain-and-availability.md), [quality gates and CI policy](../quality-gates-and-ci.md), and 003-A03.

## Package boundary

`Package.swift` uses tools version 6.4 and Swift language mode 6. It declares
one `DioramaCore` library product and one `DioramaCoreTests` test target.
The package supports iOS 16 and macOS 13. Both targets enable
nonisolated default isolation, `NonisolatedNonsendingByDefault`, and
`InferIsolatedConformances`; Swift 6 language mode supplies complete strict
concurrency checking.

The core source file deliberately exposes no public declaration. Its only role
is to make the target buildable until 003-B01 defines the first public core
contract. The test target runs one Swift Testing case that proves the target is
compiled and linked. It is a test-only toolchain module, not a Diorama product
dependency.

The existing `.gitignore` already excludes `.build`, `.swiftpm`, and
`Package.resolved`. The skeleton adds no dependency, package resolution file,
tool declaration, formatter/linter configuration, local script, or workflow.

## Verification

| Environment | Command | Result |
| --- | --- | --- |
| macOS arm64, Xcode 27.0 beta 6 (`27A5252f`) | `DEVELOPER_DIR=… swift test` | Pass: debug build and one Swift Testing case. |
| macOS arm64, Xcode 27.0 beta 6 (`27A5252f`) | `DEVELOPER_DIR=… swift build -c release` | Pass. |
| iOS Simulator arm64, iOS deployment target 16.0 | `DEVELOPER_DIR=… xcodebuild -scheme Diorama -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 17,OS=27.0' IPHONEOS_DEPLOYMENT_TARGET=16.0 build` | Pass: `DioramaCore` compiles and links for `arm64-apple-ios16.0-simulator`. |
| Ubuntu 24.04 x86_64 Apple Container, Swift 6.4.2-dev snapshot selected by 003-A01 | `swift test --scratch-path /tmp/diorama-build` | Pass: debug build and one Swift Testing case. |

The Linux check uses the 003-A01 `a01-swift` volume in a local x86_64 guest.
It is local verification only; 003-A04 still owns the hosted Linux job and its
reproducibility controls.

## Deferred 003-A04 gates

003-A04 still adds the approved Mint declarations, SwiftFormat and SwiftLint
configuration, canonical local commands, debug/release gate composition, CI
workflows, coverage collection and upload, action/update automation, and
hosted macOS, iOS, and Linux evidence. No quality gate is yet required by CI.
