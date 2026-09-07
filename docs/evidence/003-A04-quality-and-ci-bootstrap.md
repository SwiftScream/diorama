# 003-A04: Quality and CI bootstrap evidence

- Date: 2026-09-08
- Plan: [003-A04](../plans/003-clean-slate-implementation.md#003-a04--canonical-quality-and-ci-bootstrap)
- Status: Complete; local and hosted gates pass, including authenticated Codecov
  uploads.
- Authority: [Quality gates and CI policy](../quality-gates-and-ci.md),
  [003-A01 toolchain evidence](003-A01-toolchain-and-availability.md), and
  [003-A02 tool adoption](003-A02-quality-tool-adoptions.md).

## Delivered gate

`Mintfile` pins Mint 0.18.0, SwiftFormat 0.63.0, and SwiftLint 0.65.1.
`scripts/format` applies formatting. `scripts/lint`, `scripts/test`, and
`scripts/check` are non-mutating gates for formatting, strict lint, debug tests,
and a warning-as-error release build. The scripts use the currently selected
Xcode and never select an installation themselves. A missing Mint executable
exits 127 with the exact version and installation URL.

The CI workflow exposes independent `Quality`, `macOS`, `iOS`, and `Linux` jobs.
It grants read-only repository permissions, cancels superseded revisions, and
uses only reviewed actions pinned to commit SHAs with release comments.
`irgaly/setup-mint` installs and caches Mint and its tools; `actions/cache` is
used separately only for Diorama's `.build` artifacts with platform,
architecture, toolchain, and manifest identity in each key.

The Quality and Mint-update jobs run on `macos-15`. Mint is a repository tool,
so it does not need to build with Diorama's selected Swift version. This also
keeps `setup-mint` on the SwiftPM output layout it supports. Its parser requires
the lowercase `yonaskolb/mint@0.18.0` form; any other spelling makes the action
fall back to mutable `mint@master`.

The macOS and iOS jobs select the recorded `xcode-27` image and explicit Xcode
path, then assert the Xcode, Swift, SDK, and simulator runtime builds from
003-A01. macOS runs the SwiftPM debug/release gate. iOS performs a release build
and a coverage-enabled debug test against iPhone 17 on iOS 27 while compiling
with `IPHONEOS_DEPLOYMENT_TARGET=16.0`.

The Linux job runs in Swift's
[official Ubuntu 24.04 x86_64 nightly image](https://www.swift.org/install/linux/docker/),
`swiftlang/swift`, pinned to immutable manifest digest
`sha256:15ae709b1d8eb1f8691b300f5721499d007e944694f2c0e9929a55580c9bf1a5`.
The digest resolves to the same Swift compiler revisions as the dated 003-A01
snapshot and contains the approved libcurl package version. The job asserts
those compiler revisions, architecture, and the approved libcurl Debian-version
interval, then repeats the 003-A01 linkage probes and the SwiftPM debug/release
gate. This avoids a custom downloader, system-package setup, and keyring while
preventing the nightly tag from floating between repository revisions. The
[image source](https://github.com/swiftlang/swift-docker) is Apache-2.0
licensed. The Linux workflow installs only the `curl` command required by the
Codecov action; the image already supplies the compiler, SwiftPM, and tested
libcurl development package.

## Coverage and updates

`scripts/coverage` discovers SwiftPM's supported Codecov JSON path instead of
assuming an architecture-specific build directory. The iOS mode creates an
Xcode result bundle and verifies that `xccov` can read its coverage; the Codecov
action's Xcode plugin performs upload conversion from Derived Data.

Each platform uploads independently with the `macos`, `ios`, or `linux` flag.
Uploads set `fail_ci_if_error: true`, and Codecov waits for all three reports
before publishing combined status. Carryforward is disabled, tests and spikes
are excluded, project coverage compares with the base using the reviewed 1%
tolerance, and patch coverage is reported against its automatic baseline. No
fixed coverage target is introduced before 003-B10.

Dependabot checks the root Swift package and GitHub Actions every Monday.
Because Dependabot does not support Mintfile, a separate weekly and manually
dispatchable workflow runs `mint outdated` through the approved setup action.

## Local verification

The following checks pass on the selected Xcode 27.0 beta 6 installation and,
where stated, the digest-pinned Linux image:

- `scripts/check`: SwiftFormat reports no drift; SwiftLint reports no
  violations; the Swift Testing test passes; debug and release compile with
  warnings as errors.
- `scripts/coverage swiftpm macos`: the test and release gate passes and copies
  SwiftPM's discovered JSON report to `.build/coverage/macos.json`.
- `scripts/coverage ios`: the iOS 16 release compile and iOS 27 simulator test
  pass; `xccov` reads the resulting bundle and reports the test source.
- `scripts/verify-apple-toolchain`: all recorded Apple toolchain, SDK, and
  runtime values match.
- Apple Container runs the digest-pinned Linux image as x86_64 and reports the
  selected Swift compiler revisions, Ubuntu 24.04.4, and
  `libcurl4-openssl-dev:amd64 8.5.0-2ubuntu10.13`; the availability/linkage
  probe and SwiftPM debug, release, test, and coverage gates pass inside it.
- The official Codecov validation endpoint accepts `.codecov.yml`.
- Bash parses every repository script, Ruby's YAML parser accepts all workflow
  and configuration files, and every action reference is a 40-character SHA.
- With Mint absent from `PATH`, `scripts/lint` exits 127 and prints installation
  guidance without downloading an executable.
- In an isolated copy, malformed spacing makes the formatter stage exit 1, a
  force cast makes strict SwiftLint exit 1, an unused value becomes a compiler
  error, and a failed Swift Testing expectation stops `scripts/test` before its
  release-build stage. The initial formatting run also rewrites the existing
  Swift sources, confirming that `scripts/format` applies fixes.

The selected Xcode's Swift Testing and XCTest support libraries declare iOS 17
even when Diorama compiles at the iOS 16 deployment floor. The test therefore
runs with an iOS 17 test-bundle target on the iOS 27 simulator; the DioramaCore
compile command itself targets `arm64-apple-ios16.0-simulator`. This is a test
toolchain limitation rather than a package deployment increase.

## Hosted verification

PR #5's first hosted run confirms the selected `xcode-27` image and every
recorded Apple toolchain value. The macOS, iOS, and Linux jobs pass their build,
test, coverage-generation, and platform-verification stages. Codecov 7.0.0 and
its embedded GitHub Script v8 step run successfully on both hosted platforms;
the iOS plugin finds the generated profile and exports the test bundle report.
All three uploads then fail as intended with `Token required because branch is
protected` because `CODECOV_TOKEN` is empty.

That run also shows `setup-mint` falling back to `mint@master` when the Mintfile
uses an uppercase repository component, followed by a SwiftPM-layout failure
while building Mint on Xcode 27. The follow-up revision uses the action's exact
lowercase spelling and moves tooling-only jobs to `macos-15`. A second hosted
run verifies that correction: `setup-mint` builds the exact Mint pin and both
quality checks pass. That run's Linux archive installer encountered an invalid
response from Swift's aggregate signing-key endpoint. The follow-up revision
uses the digest-pinned official Swift image described above instead.

[Hosted run 34220251841](https://github.com/SwiftScream/diorama/actions/runs/34220251841)
verifies the resulting configuration after `CODECOV_TOKEN` is configured.
Quality passes with the exact Mint and tool pins. The Linux container
initializes and passes checkout, toolchain, architecture, libcurl,
availability/linkage, debug/release, test, cache, coverage generation, and
Codecov upload stages. macOS and iOS pass their Xcode, build, test, coverage,
and Codecov upload stages. All required A04 gates pass.
