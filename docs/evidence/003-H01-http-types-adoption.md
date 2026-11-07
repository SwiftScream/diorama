# 003-H01 — Swift HTTP Types adoption evaluation

- Date: 2026-11-07
- Status: Complete; the owner approves adoption on 2026-11-07.
- Owning unit: [003-H01](../plans/003-clean-slate-implementation.md#003-h01--swift-http-types-adoption-record)
- Adoption record: [Dependency policy](../dependency-policy.md#approved-http-package-adoption--003-h01)

## Recommendation and authority

The owner approves `apple/swift-http-types` release **1.8.0**, with the SwiftPM
rule `from: "1.8.0"` (`1.8.0..<2.0.0`), for the two products and owning targets
in the adoption record.
The exact tag resolves to `bff4b6903cdc99dda49649dd52f46c11cfd3ed50`.
This is the latest stable release observed during evaluation, rather than an
arbitrary main-branch revision. Future updates still require owner instruction
under the dependency policy.

The owner confirms this unit's scope and recommended GPT-6 Sol / `medium`
setting on 2026-11-07. This document does not claim to change session settings.
A01's toolchain foundation, C07's persisted extension proof, and D05's reviewed
production breakdown are present in the baseline. D05 requires H01's separate
adoption checkpoint, now satisfied by the owner approval. Its Linux native defects remain constraints on later
URLSession work, independently of this message-currency dependency.

## Upstream review

- [Release 1.8.0](https://github.com/apple/swift-http-types/releases/tag/1.8.0),
  dated 2026-09-07, includes an HTTP/3 error addition and field-name regression
  fixes. Recent releases and active Apple-hosted CI indicate ongoing maintenance;
  this is an observation, not a future support guarantee.
- [Tagged manifest](https://github.com/apple/swift-http-types/blob/1.8.0/Package.swift)
  declares only `HTTPTypes` and `HTTPTypesFoundation`, with no external package
  dependencies. The latter depends on the former. Swift tools 6.1 and default
  `FoundationURL` conveniences fit the selected Swift 6.4.2 toolchain.
- [Tagged README](https://github.com/apple/swift-http-types/blob/1.8.0/README.md)
  describes client/server currency and Foundation conversions. NIO integration
  lives in a separate repository and is outside this proposal.
- [License](https://github.com/apple/swift-http-types/blob/1.8.0/LICENSE.txt)
  is Apache-2.0. Preserve the upstream license and
  [notices](https://github.com/apple/swift-http-types/blob/1.8.0/NOTICE.txt)
  when distributing upstream material. The notice mentions derived SwiftNIO
  scripts; that does not introduce a runtime package dependency.
- [CI configuration](https://github.com/apple/swift-http-types/blob/1.8.0/.github/workflows/main.yml)
  covers Linux toolchains and macOS through shared upstream workflows. This is
  evidence of intended support, not proof of Diorama's pinned Linux matrix.

`HTTPRequest`, `HTTPResponse`, and `HTTPFields` expose Sendable currency values.
Upstream uses copy-on-write internals including unchecked Sendable storage;
this adoption does not authorize equivalent annotations in Diorama. Diorama's
Swift 6 consumer boundary is separately checked below.

## Semantic and platform constraints

The shared model preserves repeated fields. However,
[request conversion](https://github.com/apple/swift-http-types/blob/1.8.0/Sources/HTTPTypesFoundation/URLRequest%2BHTTPTypes.swift)
and [response conversion](https://github.com/apple/swift-http-types/blob/1.8.0/Sources/HTTPTypesFoundation/URLResponse%2BHTTPTypes.swift)
combine fields into native dictionaries; response conversion also supplies
HTTP/1.1 to the native initializer. These helpers cannot prove lossless native
round trips or recorded wire-version fidelity. The later adapter must constrain
and test its observed semantics, including repeated Set-Cookie behavior, rather
than treating conversion success as conformance. No architecture change is
needed for this adoption: DD11 already assigns native fidelity to adapters.

The source imports FoundationNetworking conditionally. Its reviewed Foundation
API availability is below Diorama's macOS 15 / iOS 18 floors. The H01 plan's
historical iOS 16 / macOS 13 wording is reconciled to the current policy; no
support floor changes here. Linux remains intended and source-supported, with
actual pinned Linux compilation deferred to integration verification. No live
network requests, adapter interception, or native lifecycle claims are made.
Diorama continues to own bodies, preparation, matching, and its Codable schema.

## Isolated checks and reproduction

All upstream source and build outputs remain in `/tmp`; nothing is vendored,
added to a production manifest, or accepted as a production implementation.
Observed host: arm64 macOS 27.2; Apple Swift 6.4.2
(`swiftlang-6.4.2.1.9`), Xcode 27.2 (`27B52`).

```sh
git clone --depth 1 --branch 1.8.0 https://github.com/apple/swift-http-types.git /tmp/diorama-h01-http-types-1.8.0
cd /tmp/diorama-h01-http-types-1.8.0
git rev-parse HEAD
swift test -Xswiftc -warnings-as-errors
swift build -c release -Xswiftc -warnings-as-errors
swift build --scratch-path /tmp/diorama-h01-ios-build \
  --triple arm64-apple-ios18.0-simulator \
  --sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" \
  -Xswiftc -warnings-as-errors
```

Results: all commands pass. The two upstream test runs pass 45 HTTPTypes tests
and 5 Foundation tests. Release compilation passes for both products. iOS
compilation passes for both products at deployment target 18; this is compile
evidence, not Simulator execution or an iOS 18 runtime test.

Initial sandbox attempts fail before compilation because Swift cannot write its
default compiler caches. Retrying the same builds with cache access succeeds.
An initial consumer invocation uses an obsolete SwiftPM module path and fails
to import the module; using the observed product path below succeeds.

Save the following as `/tmp/diorama-h01-consumer.swift`:

```swift
import Foundation
import HTTPTypes
import HTTPTypesFoundation

func requireSendable<T: Sendable>(_: T.Type) {}
func checkCurrency() {
    requireSendable(HTTPRequest.self)
    requireSendable(HTTPResponse.self)
    requireSendable(HTTPFields.self)
    var fields = HTTPFields()
    fields.append(HTTPField(name: .setCookie, value: "first=1"))
    fields.append(HTTPField(name: .setCookie, value: "second=2"))
    let response = HTTPResponse(status: .ok, headerFields: fields)
    let request = HTTPRequest(method: .get, scheme: "https", authority: "example.invalid", path: "/")
    _ = URLRequest(httpRequest: request)?.httpRequest
    _ = HTTPURLResponse(httpResponse: response, url: URL(string: "https://example.invalid/")!)?.httpResponse
}
```

Typecheck with Diorama's Swift 6 concurrency settings and macOS 15 target:

```sh
swiftc -typecheck -target arm64-apple-macos15.0 \
  -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
  -enable-upcoming-feature NonisolatedNonsendingByDefault \
  -enable-upcoming-feature InferIsolatedConformances \
  -module-cache-path /tmp/diorama-h01-module-cache \
  -I /tmp/diorama-h01-http-types-1.8.0/.build/out/Products/Debug \
  /tmp/diorama-h01-consumer.swift
```

This passes without warnings. The probe verifies public imports, Sendable
constraints, repeated-field construction, and conversion API use; it does not
assert lossless Foundation behavior. The same probe also passes for iOS with target
`arm64-apple-ios18.0-simulator`, the Simulator SDK, and import path
`/tmp/diorama-h01-ios-build/out/Products/Debug-iphonesimulator`.

No Linux execution, full Diorama gate, or hosted CI is claimed. H01 has no
production edits; V-doc and the bounded upstream checks are its relevant local
verification. H02 must obtain the required integration matrix when it introduces
the approved dependency. Adoption approval and H02 scope confirmation remain
separate owner checkpoints; only adoption is approved here.

V-doc review passes: all 295 local file links in the four changed documents
resolve, new section anchors match their linked headings, and the complete
branch diff passes `git diff --check`. The change consists only of this evidence,
the adoption record, its documentation-index link, and H01 plan status
and current deployment-floor wording. No accepted design decision changes.

## Owner review — 2026-11-07

The owner approves the `from: "1.8.0"` rule and requests that update checks also
report newer major releases and seek approval for them. The dependency policy
records that reporting requirement without broadening the adopted major range.
The review update changes only documentation; local file-link validation and
complete-diff whitespace checks pass. No experiments or production changes are
needed for this clarification.

## Pull request authorization

The owner authorizes H01/H02/H03 as separate stacked pull requests on 2026-11-08.
H01 is complete and targets `master`. Its approval record authorizes the stated
HTTP Types adoption; merge remains a separate owner action after required checks.
