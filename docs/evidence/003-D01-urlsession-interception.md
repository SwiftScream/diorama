# 003-D01: Bodyless GET interception and routing spike

- Date: 2026-09-23
- Owning unit: [003-D01](../plans/003-clean-slate-implementation.md#003-d01--bodyless-get-interception-and-routing-spike)
- Status: Complete. On 2026-09-24 the owner selects task ownership as the
  production routing method and approves continuation to D02. The original
  header and forwarding-property controls remain documented Linux defects,
  represented as known issues in the merge gate since 2026-09-26.
- Authority: [DD12](../design-decisions/12-urlsession-scope.md), [DD17](../design-decisions/17-http-lifecycle-composition.md), and Plan 003 Q1.
- Experiment: [isolated SwiftPM package](../../Spikes/URLSessionInterception/)

## Review boundary

### Merge preparation — 2026-09-26

The owner authorizes PR preparation and Linux-specific expected failures while
FoundationNetworking repairs proceed upstream. Task ownership remains the
production choice even if the original controls become available. It avoids
caller routing-header collisions and internal HTTP metadata. Its asynchronous
lookup cost, lease revalidation, redirects, and shutdown still need later gates.

The owner reports local fixes for the request-property and configuration-header
issues and is preparing upstream contributions. This branch does not contain
those patches or claim results from the patched runtime. The original runtime
results below remain historical evidence.

The affected assertions now execute inside Linux-only `withKnownIssue` scopes,
identified as FN-03 and FN-04. All task-ownership assertions and unrelated
checks remain ordinary requirements. A scope that no longer reproduces its
defect fails as an unexpected pass, prompting removal of the expectation.
Set `DIORAMA_VERIFY_FOUNDATION_FIXES=1` to run the original assertions without
known-issue handling when verifying repaired FoundationNetworking builds.

Local and hosted checks use `Spikes/URLSessionInterception/run swiftpm` on
macOS/Linux and `Spikes/URLSessionInterception/run ios` on iOS Simulator.
The experiment remains isolated from production products and coverage.

### Original investigation

The owner asked to run D01 alongside C07 on 2026-09-23. C07 remains an explicit
plan prerequisite, but this isolated native experiment does not import or depend
on C07's persistence code. The experiment starts at the C06 baseline; merge
preparation rebases it onto completed C07. It changes no production target,
root package manifest, or dependency. The owner-approved DD12 amendment records
the production routing choice.

The experiment uses a custom `URLProtocol` only in individual session
configurations. A second controlled protocol stands in for the live origin. The
request is a bodyless HTTP GET to `d01.invalid`; no remote service is needed.
The test route field and route values exist only in this spike. They do not
select a production field name or routing design.

## Platform and result matrix

| Case | macOS 27.0 | iOS 27.0 Simulator | Ubuntu 24.04 Linux |
| --- | --- | --- | --- |
| Two sessions route from configuration headers | Pass | Pass | **Fail**: interceptor receives no route field. |
| Copied configuration and consumer protocol order, using an explicit request field | Pass | Pass | Pass |
| Two sessions route from explicit request fields | Pass | Pass | Pass |
| Caller request field selects another route | Overrides configured value | Overrides configured value | Request value works; configured value is absent. |
| Missing, unknown, and expired routes fail before controlled origin | Pass | Pass | Pass |
| Case-insensitive configuration-field collision rejected by the spike setup | Pass | Pass | Pass |
| Cache disabled on copied session; two GETs intercept | Pass | Pass | Pass |
| `URLProtocol` request property prevents re-entry in a forwarding session | Pass | Pass | **Fail**: property is absent at interception. |
| Forwarding session without the interceptor reaches origin with route removed | Pass | Pass | Pass |
| Uninstrumented session reaches origin outside routing | Pass | Pass | Pass |

The table covers the original ten cases. A later task-ownership follow-up adds
five cases, documented below. With those cases, the macOS and iPhone 17
simulator suites each pass **15/15** tests with zero skipped or expected
failures. The pinned Linux suite compiles without warnings and passes **13/15**;
only the two original failures remain. Those failures remain executable, so
the overall Linux test command exits 1. The controlled origin counter remains
zero for rejected replay routes. No global `URLProtocol.registerClass` call is
used.

The request-field override is an observed native result, not an accepted
collision policy. On Apple Foundation, a caller-supplied request field with the
reserved name takes precedence over the configuration field and can select
another registered route in this spike. On Linux, the request field also selects
that route, while the configuration field is absent at interception. The setup
check rejects a collision in
`httpAdditionalHeaders` before creating a session, but the returned session's
ordinary request APIs cannot use that check. Any production routing scheme must
also satisfy DD12's requirement to reject a caller collision rather than silently
replace it or route to a different execution.

## Exact environment and commands

The macOS host reports macOS 27.0 build `26A428`, arm64. Xcode 27.0 build
`27A266a` supplies Apple Swift 6.4 (`swiftlang-6.4.0.34.1`,
`clang-2100.3.34.1`). The iOS destination is iPhone 17, iOS 27.0 Simulator
build `24A434`; the package deployment minimum is iOS 18. Linux runs in the
selected x86_64 Ubuntu 24.04 image at digest
`sha256:15ae709b1d8eb1f8691b300f5721499d007e944694f2c0e9929a55580c9bf1a5`.
It reports Swift `6.4.2-dev (LLVM 15622a86b1749a9, Swift d2e983b81b18217)`
and `libcurl4-openssl-dev:amd64 8.5.0-2ubuntu10.13`.

From the repository root, the focused macOS command is:

```sh
swift test --package-path Spikes/URLSessionInterception --scratch-path .build/d01-spike -Xswiftc -warnings-as-errors
```

From the isolated package directory, the iOS command is:

```sh
xcodebuild test -quiet -scheme URLSessionInterception-Package \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=27.0' \
  -derivedDataPath ../../.build/d01-ios-derived \
  -resultBundlePath ../../.build/d01-ios-final.xcresult \
  IPHONEOS_DEPLOYMENT_TARGET=18.0 SWIFT_TREAT_WARNINGS_AS_ERRORS=YES
```

From the repository root, the Linux command is:

```sh
container run --rm --arch x86_64 --cpus 2 --memory 4G \
  --mount type=bind,source="$PWD",target=/source,readonly --workdir /work \
  swiftlang/swift@sha256:15ae709b1d8eb1f8691b300f5721499d007e944694f2c0e9929a55580c9bf1a5 \
  bash -lc 'cp -R /source/Spikes/URLSessionInterception /work/ && cd /work/URLSessionInterception && swift test -Xswiftc -warnings-as-errors'
```

The root `scripts/lint` gate passes with zero formatting changes and zero
SwiftLint violations. SwiftPM build products and the simulator result bundle
are local generated files, not part of the review diff. The iOS result bundle
reports the exact simulator build and ten passed tests through
`xcrun xcresulttool get test-results summary`.

## Stable Swift 6.4.0 release comparison

Swift [released 6.4.0 on September 15, 2026](https://www.swift.org/blog/swift-6.4-released/)
and lists an [official Ubuntu 24.04 container](https://www.swift.org/install/linux/ubuntu/24_04/)
tagged `swift:6.4.0-noble`. On 2026-09-23, the same isolated package ran in
`docker.io/library/swift:6.4.0-noble`, resolved locally to OCI index digest
`sha256:64bab762bc73a3fda6d9ebc559258bd6d7660c10a705bb25ecacad2f99d066f9`.
The selected `linux/amd64` image digest is
`sha256:3fd7537e088df14007e5c9dd71a1b4d91b19067df727b17294ae0f6ea79f6423`.
The container reports `Swift version 6.4 (swift-6.4-RELEASE)`, target
`x86_64-unknown-linux-gnu`, and the same
`libcurl4-openssl-dev:amd64 8.5.0-2ubuntu10.13` package as the pinned snapshot.

```sh
container run --rm --arch x86_64 --cpus 2 --memory 4G \
  --mount type=bind,source="$PWD",target=/source,readonly --workdir /work \
  swift:6.4.0-noble \
  bash -lc 'cp -R /source/Spikes/URLSessionInterception /work/ && cd /work/URLSessionInterception && swift --version && dpkg-query -W libcurl4-openssl-dev && swift test -Xswiftc -warnings-as-errors'
```

The package compiles with warnings treated as errors. After the ownership
follow-up, the result is **13 passed, 2 failed**: configuration-header routing
and request-property forwarding still fail with the same observations as the
snapshot. The five ownership cases pass. This narrows the finding to the tested
FoundationNetworking bridge and runtime behavior. No CI toolchain or
dependency pin changes in this review update.

## FoundationNetworking source diagnosis

The [Swift 6.4.0 release source](https://github.com/swiftlang/swift-corelibs-foundation/tree/swift-6.4.0-RELEASE/Sources/FoundationNetworking)
explains both Linux failures:

1. `URLSession` [configures the request](https://github.com/swiftlang/swift-corelibs-foundation/blob/swift-6.4.0-RELEASE/Sources/FoundationNetworking/URLSession/URLSession.swift#L538-L540)
   before choosing a protocol, but that
   [configuration step](https://github.com/swiftlang/swift-corelibs-foundation/blob/swift-6.4.0-RELEASE/Sources/FoundationNetworking/URLSession/Configuration.swift#L107-L125)
   only adds cookies. `URLSessionTask` then
   [chooses and creates a custom protocol](https://github.com/swiftlang/swift-corelibs-foundation/blob/swift-6.4.0-RELEASE/Sources/FoundationNetworking/URLSession/URLSessionTask.swift#L129-L167)
   using that request. The built-in HTTP protocol merges
   [`httpAdditionalHeaders` with request headers](https://github.com/swiftlang/swift-corelibs-foundation/blob/swift-6.4.0-RELEASE/Sources/FoundationNetworking/URLSession/HTTP/HTTPURLProtocol.swift#L361-L390)
   later, when preparing libcurl headers. A custom `URLProtocol` therefore
   sees the explicit request headers but not the session configuration headers.
   This is the source path's ordering; the spike does not show that outgoing
   built-in HTTP requests omit those headers.
2. `URLProtocol.setProperty` [stores the marker](https://github.com/swiftlang/swift-corelibs-foundation/blob/swift-6.4.0-RELEASE/Sources/FoundationNetworking/URLProtocol.swift#L323-L339)
   in `NSMutableURLRequest.protocolProperties`. The
   [`NSMutableURLRequest` to `URLRequest` bridge](https://github.com/swiftlang/swift-corelibs-foundation/blob/swift-6.4.0-RELEASE/Sources/FoundationNetworking/URLRequest.swift#L286-L302)
   makes a mutable copy, whose
   [field-copy list](https://github.com/swiftlang/swift-corelibs-foundation/blob/swift-6.4.0-RELEASE/Sources/FoundationNetworking/NSURLRequest.swift#L149-L170)
   omits `protocolProperties`. The forwarding test performs this bridge when
   passing its marked request to `URLSession`. A direct check in the official
   `swift:6.4.0-noble` image returns `nil` even before creating a session:

   ```swift
   let mutable = NSMutableURLRequest(url: URL(string: "http://example.invalid")!)
   URLProtocol.setProperty(true, forKey: "probe", in: mutable)
   print(URLProtocol.property(forKey: "probe", in: mutable as URLRequest) as Any)
   // nil on Linux; Optional(1) on the tested macOS host
   ```

The corresponding source in the repository's `main` branch still has these
request-configuration and copy paths as of 2026-09-23. This source inspection
narrows the second failure to a request-copy omission, while the first is a
limitation of where the Linux implementation adds configuration headers.

## Task-ownership routing follow-up

The [isolated ownership tests](../../Spikes/URLSessionInterception/Tests/URLSessionInterceptionTests/TaskOwnershipTests.swift)
try the narrower route permitted by DD12. Each returned session registers with
the spike's active-session registry. In `URLProtocol.startLoading`, the
interceptor obtains its [task](https://developer.apple.com/documentation/foundation/urlprotocol/task)
and asynchronously asks each registered session for its
[outstanding tasks](https://developer.apple.com/documentation/foundation/urlsession/getalltasks%28completionhandler%3A%29).
Exactly one session must contain the same task object; a task identifier alone
is insufficient because its uniqueness is only within a session. A missing or
ambiguous match rejects the request. No routing field or request property is
needed, and a caller header with the old reserved name cannot select another
execution.

| Ownership case | macOS | iOS Simulator | Pinned Linux | Stable Swift 6.4 Linux |
| --- | --- | --- | --- | --- |
| Two concurrent sessions, no routing metadata | Pass | Pass | Pass | Pass |
| Overlapping tasks and conflicting caller header | Pass | Pass | Pass | Pass |
| Expired registration yields no match | Pass | Pass | Pass | Pass |
| Two sessions return their own bodyless GET responses | Pass | Pass | Pass | Pass |
| Expired registration returns an error without origin access | Pass | Pass | Pass | Pass |

The first three cases hold tasks open while inspecting ownership and cancel
them afterward. The final two complete or reject the actual URLSession load.
The latter require a private, test-only `@unchecked Sendable` callback bridge:
`URLProtocol` is not `Sendable`, while `getAllTasks` invokes a `@Sendable`
completion. Its mutable callback ownership is protected by a `Mutex`, and the
bridge releases its protocol reference after one terminal transfer or stop.
This annotation is justified only for the isolated experiment; it is not an
accepted production concurrency design. Cancellation during callback delivery,
quiescence, redirects, and broader task forms remain unproved.

The focused macOS, iOS Simulator, pinned Linux snapshot, and official Swift
6.4.0 Linux checks all pass these five cases. The complete macOS and iOS suites
pass 15/15; the complete official Linux suite passes 13/15 with only the two
previous failures. `scripts/lint` passes with zero violations. This supports
task ownership as a replacement for the header route for the tested bodyless
GET. On 2026-09-24 the owner approves this as the production routing choice,
recorded in [DD12's amendment](../design-decisions/12-urlsession-scope.md#task-ownership-routing-amendment--2026-09-24).
The callback bridge remains experiment-only, and later spikes retain their
capability and lifecycle gates.

## Interpretation and next checkpoint

The Linux request-header control passes, so the failed configuration-header
case specifically shows that this FoundationNetworking `URLProtocol` callback
does not receive `URLSessionConfiguration.httpAdditionalHeaders` for a bodyless
GET. The forwarding-property control fails because the `URLProtocol` property
set on the request is not visible to the interceptor after the request enters a
Linux `URLSession`. These are observations on the pinned runtime, not claims
about every FoundationNetworking release.

Omitting the interceptor from a private forwarding session works in the
controlled origin test on all three platforms. That case prepares the forwarded
request outside `startLoading`; it does not prove a complete nested forwarding
task, callback relay, cancellation path, or quiescent tail. D02–D05 retain
their separate evidence scopes.

D01 does **not** establish the original configuration-header route on Linux.
The task-ownership follow-up establishes a narrower bodyless GET route on the
tested bridges, without caller cooperation or request metadata. The accepted
one-system Apple-and-Linux contract cannot depend on the failed header or
request-property mechanisms. The owner approves continuing D02 with task
ownership on 2026-09-24. A successful bodyless GET does not yet
prove lifecycle safety for the later task, redirect, and finalization scopes.
