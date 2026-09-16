# 003-B09: Scoped execution convenience

- Date: 2026-09-16
- Status: Implementation and macOS/iOS local verification complete; the
  post-amendment pinned Linux result remains unverified.
- Authority: Owner confirmation of 003-B09's scope, including
  `ScenarioDefinition.execute(with:)`, a preferred variadic system form, and an
  erased-system form for dynamic or execution-level use. The owner requested
  rebase onto the accepted, squashed B08 revision on 2026-09-16. The owner also
  approved DD10's publication-policy amendment: body outcome does not control
  candidate publication.
- Prerequisites: [B08 evidence](003-B08-concurrent-finalization-and-evaluation.md)
  and [DD10](../design-decisions/10-lifecycle-and-ownership.md).

## Public API

The preferred overload accepts heterogeneous typed systems directly. It starts
a fresh execution, supplies dependencies to the body in argument order, and
always finalizes before returning:

```swift
let scoped = try await definition.execute(
    with: randomSystem, httpSystem, clockSystem
) { random, http, clock in
    try await exerciseApplication(
        random: random,
        http: http,
        clock: clock
    )
}
```

System preparation, activation, and cleanup retain definition order even when
the variadic arguments use another order. Typed dependencies retain the
argument order. The body closure carries its inferred actor isolation through
the call; the tests exercise a main-actor-isolated caller.

The advanced overload accepts `[AnyScenarioSystem]` and supplies the activated
`ScenarioExecution` itself. It supports registrations assembled dynamically and
callers that need execution-level operations:

```swift
let scoped = try await definition.execute(with: erasedSystems) { execution in
    let random = try execution.dependency(randomSystem)
    return try await exerciseApplication(random: random)
}
```

Startup remains a throwing operation because failed startup produces no running
execution to finalize. Once startup succeeds, `ScopedExecutionResult` preserves
the body's typed `Result` and the complete `ScenarioFinalizationResult`
separately. A body or cleanup failure therefore cannot mask the other outcome.

## Finalization and candidate health

The scoped helper captures body success, error, or cancellation and then calls
the same idempotent, execution-owned finalization primitive proved by B08. A
canceled caller cannot cancel the finalization task. Cleanup still runs in
reverse activation order, continues after a cleanup failure, and contributes
safe diagnostics to the immutable report.

The body outcome does not control the definition's eventual publication policy.
Whether the body returns, throws, or is canceled, B09 calls the same idempotent
`finish()` operation. The typed body `Result` remains available alongside the
finalization result, so neither body nor cleanup failure masks the other.

B09 does not publish or persist anything. 003-C05 owns durable candidate
publication, which DD10 permits only for a complete, healthy candidate under
the definition's configured policy. Candidate health is not inferred from a
body error, cancellation, diagnostic sink, or test-framework result.

## Swift compiler regression

The initial preferred syntax exposed an upstream Swift compiler regression. A
reduced two-target package crashes when a public function accepts an `async`
parameter-pack closure and another module supplies an inline closure while
`NonisolatedNonsendingByDefault` is enabled. This exactly matches open
[Swift issue 91831](https://github.com/swiftlang/swift/issues/91831), which
identifies the combination as a Swift 6.3 regression.

The reduced case was reproduced with all of these compilers:

- Xcode 27.0 final's Apple Swift 6.4
  (`swiftlang-6.4.0.34.1`, `clang-2100.3.34.1`);
- the pinned x86_64 Linux Swift 6.4.2 development image used by Diorama CI;
- the official `nightly-main-jammy` Swift 6.5 development image from
  2026-09-10 (`Swift 2abb962c344c545`, `LLVM 7be344f3975b01a`).

Marking the closure `@concurrent` avoids the crash but would intentionally move
work away from the caller's executor, so it is not an acceptable lifecycle
workaround. The variadic overload instead uses `@isolated(any)`. Under
[SE-0431](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0431-isolated-any-functions.md),
that function type dynamically carries the closure's actor isolation. The
reduced main-actor probe, the production actor-isolation test, Xcode 27 final,
and the current Swift nightly all compile and run with this annotation.

The annotation is localized to the parameter-pack overload and documented next
to its declaration so it is not removed as redundant while issue 91831 remains
open. No concurrency checking is disabled, and B09 adds no unsafe isolation,
`@unchecked Sendable`, detached task, dependency, or deployment-floor change.

## Scope and tests

Core tests cover heterogeneous dependency order, definition-ordered lifecycle,
caller actor isolation, body success, typed body error, throwing and
cooperatively handled cancellation, cleanup failure, startup failure, and safe
finalization diagnostics. Existing B08 tests continue to prove shared finish
behavior and cancellation-resistant finalization.

The unit adds no test-framework hook, sink-derived test outcome, repository,
durable write, new publication mode, scheduler, or native adapter. The erased
startup representation remains available for advanced use; the variadic
overload is convenience over the same validated startup and finalization
primitives.

## Verification results

| Gate | Result |
| --- | --- |
| `scripts/check` | Zero formatting/lint violations; 84 tests pass (65 core, 15 random, 4 consumer); debug tests and release compilation pass with warnings as errors. |
| Apple toolchain | Xcode 27.0 final, build `27A266a`; Apple Swift 6.4 `swiftlang-6.4.0.34.1`; final iOS 27.0 Simulator runtime. |
| `scripts/coverage swiftpm macos` | All 84 tests and release compilation pass; LCOV export succeeds. |
| `scripts/coverage ios` | All 84 tests and release compilation pass on iPhone 17 / iOS 27.0 Simulator with the iOS 18 deployment floor; LCOV export succeeds. |
| Pinned Linux container | The mandated post-amendment `scripts/coverage swiftpm linux` run entered compilation in the pinned Swift 6.4.2-dev (`d2e983b81b18217`) x86_64 container, but the local container runner detached without returning a final exit status or log. No Linux pass result is claimed. |
| Current Swift nightly | The unannotated reduced case crashes; the annotated reduced probe and pre-rebase 84-test B09 revision pass with Swift 6.5-dev (`2abb962c344c545`), target `aarch64-unknown-linux-gnu`. The feature patch is unchanged by the rebase. |
| Documentation/diff | Local links and anchors resolve; the complete B09 diff against B08 passes `git diff --check`. |

Coverage measurements are evidence, not new thresholds; 003-B10 owns that
policy. Hosted Quality, macOS, iOS, Linux, and Codecov statuses remain required
integration gates obtained through the separately authorized PR workflow.

The review base is B08's integrated commit `9ba73cd`. One feature commit
contains the core behavior and its proving tests; a separate documentation
commit records this evidence, the owning plan status, and the documentation
index link. This review does not incorporate B08's own changes into the B09 diff.
