# 003-Ra1: Scoped dependency lifetime

- Date: 2026-10-15
- Status: Complete.
- Plan: [003-Ra1](../plans/003-clean-slate-implementation.md#003-ra1--release-scoped-invocation-dependencies-before-finalization)
- Authority: Owner request to fix Ra1 on its own branch and raise a PR; DD21's
  state-owned lifecycle and DD18's original-error/retained-report contracts.

## Ownership boundary

`Diorama.execute` invokes the application body through a private helper that
owns the temporary dependency tuple. That helper returns `Result<Success,
Failure>` before `DioramaRun.finish` begins finalization and publication.
The result preserves the returned value or original error, while invocation
argument ownership has ended. The existing execution gate still covers startup,
body execution, cleanup, publication, and storing the completed report.

Core can now release its remaining dependency references at its accepted
release-before-report boundary. Their destruction can contribute final facts
and invalidate a recording before publication. Explicit stop/cleanup hooks
remain responsible for native shutdown; this change does not force destruction
of dependencies intentionally retained in returned values, errors, external
storage, or setup/factory captures. No public signature or mode policy changes.

## Public regression evidence

`DioramaScopedDependencyLifetimeTests` and
`DioramaScopedReleasePublicationTests` use public module imports. Four new tests
cover ten parameterized invocations:

- A MainActor-isolated body suspends, uses heterogeneous injected dependencies,
  then returns an unrelated scalar or throws its original typed error. In all
  three modes, release facts enter the final report and the late log stays empty.
- Body cancellation preserves `CancellationError` after releasing temporary
  arguments and retaining the final report.
- Application storage intentionally retains a passthrough dependency. Its native
  value remains usable after finish; subsequent destruction enters only the
  post-finish log and does not mutate the completed report.
- File-backed record scopes return a scalar or throw the original error. A
  dependency release invalidates the candidate, refuses publication, and leaves
  the prior file byte-identical with no extra directory entries.

The new release/publication cases reproduce the original failure before the
fix. Existing scoped and retained-report tests additionally protect dependencies
returned as body values, retained by original errors or setup captures, actor
isolation, cancellation with a returning body, sequential reuse, and admission.

## Verification

On Apple Swift 6.4 / Xcode 27.0:

- The focused scoped lifetime/publication, scope, retained-report, and variadic
  execution suites pass all 17 tests with warnings as errors in both Debug and
  optimized Release (`swift test -c release` with the same suite filter).
- `scripts/check` passes 452 host tests, formatting, strict lint, public
  authoring and lifecycle compiler probes, Release builds, and both examples.
- V-doc checks cover links, plan status, the complete branch diff, and whitespace.

Required PR checks cover the current revision's macOS, iOS Simulator, Linux,
and Codecov matrix. Ra2's canceled-capture join and Ra3's merge phase ordering
remain separate work units; this fix changes neither scheduler nor lease logic.
