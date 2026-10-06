# 003-F04 replay continuation preparation

The owner approves this preparatory refactor during F04 review on 2026-10-07.
It precedes the wall-replay implementation and preserves existing default
replay behavior while adding opt-in continuation. Subsequent owner review on
the same date removes Core projection in favor of system-owned translation.

`SequentialTrackLease<Value, Header>` returns the stored `Value` from
`consumeNext()`. The headerless convenience alias selects `Void` headers.
Systems translate stored values into domain objects and may use execution
context; record types require no mapping protocol. Explicit claims still
carry record identity.

The public preparation boundary accepts `ReplayContinuationPolicy<Value>`.
The default `.error` policy retains no continuation value. `.fallback(value)` retains its configured value;
`.replayLast(defaultValue:)` replaces its default with the latest synchronously
consumed value. Exhausted and closed replay reads diagnose before returning the
selected continuation. Wrong-mode calls and explicit claims still throw.
Continuations create no records, identities, or consumption facts.

Recording and passthrough retain no continuation values. Consumption and
continuation selection share the lease's atomic order. Diagnostic handlers
and destruction of replaced defaults run outside the state lock. Closure
releases baseline content while an opted-in lease retains only its required
continuation value. There is no second array of projected values or retained
conversion closure.

The [DD19 refinement](../design-decisions/19-system-owned-records.md#system-owned-replay-conversion-refinement--accepted-2026-10-07)
records the approved contract. The [record-services guide](../record-services.md)
documents setup, system-owned translation, continuation, and lifetime semantics.
No dependency, persistence schema, or deployment-floor changes are introduced.

## Verification

At the original standalone preparatory revision on 2026-10-07:

- Focused Core gate: 27 tests passed across continuation, concurrency, lifetime,
  sequential operations, and record-service boundaries.
- `scripts/check`: formatting, strict lint, all 309 tests, debug/release builds,
  complete strict concurrency checking, and the release example passed on macOS.
- `git diff --check`: passed.

The stored-value review update also passes `scripts/check` independently on
2026-10-07: all 309 tests, formatting, strict lint, debug/release builds, and
the release example pass before applying the F04 clock adoption.

The new tests prove fixed and replay-last continuation, empty and partially
consumed tracks, backward values, distinct exhaustion positions, immutable
finalization facts, independent explicit claims, stored override preservation,
typed headers, concurrent consumption, closure races, reentrant diagnostics,
and release of unused values and replaced defaults. The review update checks
that both consumption and continuation preserve observed/override authorship.
The full F04 stack supplies the final macOS, iOS, and Linux integration evidence.
