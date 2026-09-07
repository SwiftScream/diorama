# 003-A01: Toolchain and deployment feasibility

- Date: 2026-09-07
- Plan: [003-A01](../plans/003-clean-slate-implementation.md#003-a01--toolchain-and-deployment-feasibility-record)
- Status: Complete; local Apple and x86_64 Linux evidence passed; hosted execution is deferred to 003-A04.
- Authority: [Quality policy and beta amendment](../quality-gates-and-ci.md#toolchain-policy), Q2/Q5, DD14–DD16.
- Experiment: [Spikes/ToolchainAvailability](../../Spikes/ToolchainAvailability/)

## Finding and approval boundary

The installed Xcode 27.0 beta 6 and Apple Swift 6.4 support the probed clock,
Foundation time, and concurrency primitives at iOS 16 and macOS 13. The probes
execute successfully on the current macOS host and iOS simulator. They do not
prove execution on an actual installation of either minimum OS version.

On 2026-09-07 the owner confirmed 003-A01's scope and explicitly authorized targeting
the Xcode/Swift beta on this machine, with an update when it becomes stable.
The quality-policy amendment records this exception to the original stable-only
bootstrap requirement. The expected stable release date is not a verified pin.

This unit adds isolated evidence, not a production package or Diorama runtime.
There are no adopted Swift package dependencies, tool installations, CI workflows,
or changes to the accepted runtime minima. 003-A02–003-A04 retain their own scope and
approval boundaries. The local Linux experiment and all in-scope availability
probes passed. Hosted execution and CI enforcement are deferred to 003-A04.

## Selected tools and platform matrix

| Item | Selection | Evidence/status |
| --- | --- | --- |
| Xcode | 27.0 beta 6, build `27A5252f` | Installed and used. |
| Apple Swift | 6.4, `swiftlang-6.4.0.33.1`, `clang-2100.3.33.1`; driver `1.168.6` | Installed compiler output. |
| SwiftPM / intended tools version | SwiftPM `Swift 6.4.0-dev`; `swift-tools-version: 6.4` for 003-A03 | Tool inspected; no production manifest created. |
| Language and isolation | Swift 6; complete strict concurrency; nonisolated default; `NonisolatedNonsendingByDefault` and `InferIsolatedConformances` enabled | Positive and negative executable compilation probes. |
| Local macOS host | macOS 27.0 build `26A5421a`, arm64 | Executed debug and release probes targeting macOS 13. |
| macOS SDK | 27.0 build `26A5419a` | Installed SDK queried with `xcrun`. |
| iOS device/simulator SDKs | 27.0 build `24A5422a` | Device compile and simulator compile/link at iOS 16. |
| iOS execution destination | iPhone 17, arm64, iOS 27.0 build `24A5423a` | Both probe executables ran with `simctl spawn`. |
| Apple hosted runner | GitHub Actions `xcode-27`, arm64; explicit Xcode build `27A5252f` | Published inventory supports selection; no hosted run performed. |
| Linux host | GitHub Actions `ubuntu-24.04`, x86_64, Ubuntu 24.04 LTS | Also verified locally in an Apple Container x86_64 guest. |
| Linux toolchain | Official `swift-6.4.x-DEVELOPMENT-SNAPSHOT-2026-09-04-a`, Ubuntu 24.04 x86_64 | Installed in the named Apple Container volume and executed successfully; Swift reported `6.4.2-dev (LLVM 15622a86b1749a9, Swift d2e983b81b18217)`. |
| Linux libcurl baseline | Ubuntu OpenSSL-flavour `libcurl4-openssl-dev`, package `8.5.0-2ubuntu10.13` | Installed locally; FoundationNetworking resolves `libcurl.so.4`. |

The Apple compiler is selected through `DEVELOPER_DIR`, not the machine's
global `xcode-select` setting, which points to Command Line Tools. Its local
directory is `/Applications/Xcode-27.0.0-Beta.6.app/Contents/Developer`.

The selected [GitHub runner inventory](https://github.com/actions/runner-images/blob/1dd1f01356ba3386b5a039b17901ecc5e34f9960/images/macos/xcode-27-arm64-Readme.md)
records image `20260901.0153.1`, macOS 26.5.2 (`25F84`), and Xcode `27A5252f`
at `/Applications/Xcode_27_beta_6.app`. GitHub documents the arm64
[`xcode-27` runner label](https://github.blog/changelog/2026-07-16-xcode-27-runner-image-now-in-public-preview/).
The image label is a host selection, not an immutable toolchain pin. 003-A04 must
select and assert the exact Xcode/Swift builds and log its actual image, host,
SDK, and simulator runtime. A missing or changed toolchain must fail visibly
until the pins are deliberately updated. The published inventory does not give
the simulator's build number; matching `24A5423a` remains a hosted evidence gate.

For Xcode tests in 003-A04 the selected destination is
`platform=iOS Simulator,name=iPhone 17,OS=27.0`, with the resolved runtime build
checked and `IPHONEOS_DEPLOYMENT_TARGET=16.0`. 003-A01 uses standalone simulator
executables and makes no claim to have established the future `xcodebuild test`
or coverage jobs.

## Linux selection and libcurl bounds

The [official Ubuntu 24.04 download index](https://www.swift.org/install/linux/ubuntu/24_04/)
publishes the selected Swift 6.4 release-branch snapshot. This matches the Apple
compiler's release line, not its exact vendor build. Use the dated
[x86_64 tarball](https://download.swift.org/swift-6.4.x-branch/ubuntu2404/swift-6.4.x-DEVELOPMENT-SNAPSHOT-2026-09-04-a/swift-6.4.x-DEVELOPMENT-SNAPSHOT-2026-09-04-a-ubuntu24.04.tar.gz)
and its [detached signature](https://download.swift.org/swift-6.4.x-branch/ubuntu2404/swift-6.4.x-DEVELOPMENT-SNAPSHOT-2026-09-04-a/swift-6.4.x-DEVELOPMENT-SNAPSHOT-2026-09-04-a-ubuntu24.04.tar.gz.sig),
not a floating nightly image. The tarball returned HTTP 200 and a content length
of `1275787555` bytes on 2026-09-07. The local container used the same dated
snapshot and passed both probes. Signature verification and archive digest
recording remain follow-up reproducibility checks for 003-A04. The Swift project
describes snapshots as prereleases with
less release validation than official releases.

[Ubuntu's package record](https://packages.ubuntu.com/noble-updates/libcurl4t64)
identifies the Ubuntu 24.04 `libcurl4t64` runtime baseline as upstream 8.5.0;
the local image exposes the development package as
`libcurl4-openssl-dev 8.5.0-2ubuntu10.13`, which supplies the same system
`libcurl.so.4` family used by FoundationNetworking. Bound the initial matrix to
Ubuntu 24.04's OpenSSL-flavour libcurl packages with Debian versions
`>= 8.5.0-2ubuntu10.13` and `< 8.5.0-2ubuntu11`. This admits security revisions
within the same Ubuntu package series while preventing a silent upstream or
distribution change. Every Linux job must log the resolved package version and
revalidate it through the complete applicable test gate. An upstream/version
series change requires updating this record and rerunning the platform and,
once present, URLSession capability tests.

The Linux probe imports FoundationNetworking and constructs a URLRequest without
performing network I/O. In the local guest, `ldd` showed
`libFoundationNetworking.so` and `libcurl.so.4` from the Ubuntu system library
set. The package was resolved as `libcurl4-openssl-dev:amd64 8.5.0-2ubuntu10.13`.
The system `curl --version` command is not sufficient evidence of
FoundationNetworking's dependency; the `ldd` result is the relevant check.

Apple Container is installed locally as `container` 1.3.1. Its system service
was initially stopped and was started with `container system start`. The
documented Alpine smoke test passed, Ubuntu 24.04 arm64 passed, and an explicit
`--platform linux/amd64` Ubuntu 24.04 guest reported `x86_64`. The dated Swift
archive was retained in named volume `a01-swift` so dependency corrections did
not redownload it. This local guest is an x86_64 virtual machine, not a CI host;
the hosted job still has to reproduce the selected image, package, compiler, and
linkage checks.

## Probe design and observed results

All positive compilation uses these explicit flags:

```text
-swift-version 6
-strict-concurrency=complete
-warnings-as-errors
-default-isolation nonisolated
-enable-upcoming-feature NonisolatedNonsendingByDefault
-enable-upcoming-feature InferIsolatedConformances
```

[ClockProbe.swift](../../Spikes/ToolchainAvailability/ClockProbe.swift) proves
an ordinary forwarding `Clock` conformance, `Duration` arithmetic, and sendability
of the clock, instant, duration, and `Date`. It checks a 20 ms monotonic sleep
does not finish before its deadline, and that an immediately canceled 60-second
sleep throws `CancellationError`. It imposes no upper elapsed-time bound or task
ordering assumption. A fixed `Date` round-trips through Foundation's ISO 8601
formatter at millisecond precision with an explicit `+11:00` timezone. This is
primitive feasibility, not the complete DD15 scalar codec or scheduler suite.

[ConcurrencyProbe.swift](../../Spikes/ToolchainAvailability/ConcurrencyProbe.swift)
uses a non-Sendable value retained by a main-actor owner across an ordinary async
call; a main-actor class conforming to a synchronous protocol without an explicit
conformance annotation; an `@concurrent` function; and ordinary class access from
a nonisolated function. It uses no unsafe isolation or sendability annotations.
Omitting each upcoming feature separately must fail for the expected diagnostic.
The caller-isolation negative control emits SIL: type checking alone does not
run the region-isolation diagnostic and is insufficient for this check.

| Check | Result |
| --- | --- |
| macOS arm64, deployment 13.0, `-Onone` and `-O`, both executables | Pass: compile, link, run; all preconditions hold. |
| macOS x86_64, deployment 13.0 | Pass: both sources compile to objects; no x86_64 execution. |
| iOS arm64, deployment 16.0 | Pass: both sources compile to objects. |
| iOS Simulator arm64, deployment 16.0 | Pass: both sources compile/link and execute on iOS 27.0 (`24A5423a`). |
| Mac Catalyst arm64, deployment 16.0 | Pass: both sources compile to objects. |
| tvOS arm64 16.0, watchOS arm64_32 9.0, visionOS arm64 1.0 | Pass: both sources compile to objects; no execution or added support promise. |
| macOS 12.0 and iOS 15.0 clock negative controls | Pass: rejected for unavailable `Clock` / `ContinuousClock`. |
| Caller-isolation feature omitted | Pass: rejected for sending `self.value` across isolation and risking data races. |
| Isolated-conformance feature omitted | Pass: rejected for a conformance crossing into main-actor code. |
| Linux local x86_64 guest | Pass: dated Swift snapshot compiled and ran both probes; FoundationNetworking linked to system libcurl. |
| GitHub-hosted jobs | Unverified: no authorized PR/CI run. |
| Actual iOS 16 / macOS 13 runtime installations | Unverified: execution used current OS versions. |

The equivalent-platform checks establish availability feasibility only. They
do not advertise additional products or Core Location/URLSession adapters.
`vtool -show-build` also confirms `minos 13.0` in the macOS clock executable
and `minos 16.0` in the simulator clock executable.

## SDK declaration evidence

In the selected macOS SDK's
`usr/lib/swift/_Concurrency.swiftmodule/arm64e-apple-macos.swiftinterface`,
the declarations for `Clock` (line 1723) and `ContinuousClock` (line 1763) carry
macOS 13, iOS 16, watchOS 9, and tvOS 16 availability. The negative controls
confirm the compiler enforces that boundary. The compiler's
`swiftc -print-supported-features` lists both requested upcoming features as
supported and enabled by default in Swift language mode 7; they remain explicit
opt-ins for this Swift 6 configuration.

For DD16, the installed iOS SDK's
`System/Library/Frameworks/_LocationEssentials.framework/Headers/CLLocationEssentials.h`
declares ellipsoidal altitude (line 345) and source information (line 422) from
iOS 15/macOS 12, course accuracy (line 380) from iOS 13.4/macOS 10.15.4, speed
accuracy (line 396) from iOS 10/macOS 10.15, and floor (line 414) from
iOS 8/macOS 10.15. These property declarations do not demand a higher minimum.
This is header inspection, not a live Core Location test or proof of the entire
future facade; 003-G07–003-G09 still own that evidence.

## Reproduction

From the repository root on the selected Mac:

```sh
export DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.6.app/Contents/Developer
xcodebuild -version
xcrun swift --version
xcrun swift package --version
sw_vers
xcrun --sdk macosx --show-sdk-build-version
xcrun --sdk iphoneos --show-sdk-build-version
xcrun --sdk iphonesimulator --show-sdk-build-version
Spikes/ToolchainAvailability/run apple
xcrun vtool -show-build Spikes/ToolchainAvailability/.build/apple/ClockProbe-Onone
xcrun vtool -show-build Spikes/ToolchainAvailability/.build/apple/ClockProbe-ios
```

The harness prints exact compiler invocations, stops at the first unexpected
failure, and keeps binaries, module caches, and expected-error logs under the
ignored `Spikes/ToolchainAvailability/.build/apple/` directory. `PROBE_OUTPUT`
can select a different output directory. It prints tool versions for comparison
with this record; 003-A04 owns automatic enforcement of the CI environment pins.

The following commands were used for simulator execution. The device UUID is a
local observation, not a portable CI pin; resolve the named destination on a
new host. Boot it only if shut down, and restore that state after the experiment.

```sh
xcrun simctl list devices available
xcrun simctl boot B73A199A-3BFB-4EEC-AC19-2353463AD929
xcrun simctl bootstatus B73A199A-3BFB-4EEC-AC19-2353463AD929 -b
xcrun simctl getenv B73A199A-3BFB-4EEC-AC19-2353463AD929 SIMULATOR_VERSION_INFO
xcrun simctl spawn B73A199A-3BFB-4EEC-AC19-2353463AD929 \
  "$PWD/Spikes/ToolchainAvailability/.build/apple/ClockProbe-ios"
xcrun simctl spawn B73A199A-3BFB-4EEC-AC19-2353463AD929 \
  "$PWD/Spikes/ToolchainAvailability/.build/apple/ConcurrencyProbe-ios"
xcrun simctl shutdown B73A199A-3BFB-4EEC-AC19-2353463AD929
```

Each executable exited 0 and printed its `PASS` line. The selected simulator
reported `CoreSimulator 1171.6` and iOS 27.0 (`24A5423a`). An initial sandboxed
`simctl` query failed to reach CoreSimulator; simulator commands succeeded after
permission to access the service outside the sandbox. Xcode also emitted
sandbox cache/event-stream messages during some metadata queries; these were
environment messages, not source compiler warnings.

On the selected Ubuntu host, or the equivalent Apple Container x86_64 guest,
after explicitly installing and verifying the dated official toolchain and its
documented system prerequisites:

```sh
SWIFTC=/path/to/swift-6.4.x-DEVELOPMENT-SNAPSHOT-2026-09-04-a-ubuntu24.04/usr/bin/swiftc \
  Spikes/ToolchainAvailability/run linux
```

The command was run locally in the x86_64 guest. It reported Swift
`6.4.2-dev (LLVM 15622a86b1749a9, Swift d2e983b81b18217)`, Ubuntu 24.04,
`libcurl4-openssl-dev:amd64 8.5.0-2ubuntu10.13`, and a successful `ldd` lookup
of `libcurl.so.4`. It also printed both probe `PASS` lines. A future Linux host
must record the same fields and may not silently substitute a different package
series or architecture.

## Deferred gates and release update

1. In 003-A04, verify the tarball signature/digest, repeat the package/linkage
   check on the hosted Linux job, and enforce the reviewed tool/runtime
   selections, and establish the actual iOS `xcodebuild test` and coverage jobs.
2. When stable Xcode/Swift is selected, update the exact Apple and Linux pins,
   SDK/runtime inventory, and this exception's status in one reviewed maintenance
   change. Rerun these probes and the complete 003-A04 matrix once it exists.

No newly discovered clock availability conflict requires changing Q2. Q5's tool
and platform choices are recorded, while Linux/hosted verification and the later
003-A02, 003-A04 Codecov, 003-H01, and 003-B10 selections remain at their named checkpoints.
