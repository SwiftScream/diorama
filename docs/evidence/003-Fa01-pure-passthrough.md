# 003-Fa01: Pure passthrough

- Date: 2026-10-11
- Status: Complete.
- Plan: [003-Fa01](../plans/003-clean-slate-implementation.md#003-fa01--pure-passthrough-with-native-dependency-lifetime)
- Authority: DD20 and the owner-approved ordered Fa stack, using this session's
  model/settings.

## Behavior and ownership

Random and Date passthrough factories return their live sources directly after
all preparation completes. No source wrapper, operation lock, continuation,
closed flag, or reporter is retained by these dependencies. Copies of value
generators advance independently; reference sources retain their native sharing.
Retained dependencies remain live after finish without new Diorama diagnostics.

Core rejects passthrough lease requests and permits preparation without leases.
Final usage comes from the ordered attachment layout, and the immutable baseline
preserves passthrough headers and records independently of runtime leases.
Passthrough ignores managed deactivation callbacks: finish and startup rollback
release Core's references. Consumer-owned native work is not canceled or joined.
Throwing construction remains responsible for its own partial cleanup.

Public consumer systems and persistence fixtures follow the same native mode
boundary. Record/replay assertions remain, while obsolete passthrough lease,
copy-sharing, forced-release, and frozen-value assertions change deliberately.
Clock/scheduler ownership and record/replay continuation are unchanged.

Strict decoding remains independent. Standalone decoding rejects malformed Date
content. The existing all-passthrough startup policy can continue live after an
unusable baseline; it retains the decoder's load outcome and does not write the
file. This unit does not change that policy or admit malformed persisted content.
Programmatic passthrough content bypasses runtime record/replay policies, as DD20
requires. Existing mixed-mode file tests preserve valid baseline data and headers.

## Verification

`scripts/check` passes on Apple Swift 6.4 / Xcode 27.0: 393 tests, strict
formatting/lint, warnings-as-errors debug/release builds, and both examples.
Fresh iOS Simulator coverage passes 392 tests and exports LCOV. Pinned x86_64
Linux passes 393 tests with coverage collection, release builds, and both
examples. The Linux run uses the approved Swift image and a task-owned build
cache; the coverage exporter continues to use isolated current-build products.
New controlled proofs cover native value copies and reference sharing, live
reads after finish, last-handle release, baseline/header preservation, ordered
usage, lease rejection before content policies, later activation failure,
factory-owned partial cleanup, strict decoding, and unchanged repository bytes.

A gated native random read stays in flight while finish returns. A bounded
five-second failure guard releases the native gate even if the invariant fails;
the passing path does not wait for that timeout. The caller then receives its
native result without active or post-finish diagnostics.

Actual native Location/URLSession cleanup remains outside this unit. Retaining a
source intentionally in a reusable factory remains consumer ownership, not an
execution leak.

Required PR checks cover formatting/lint, macOS/iOS/Linux execution, and
Codecov uploads. The local runs above do not establish minimum-platform runtime
coverage.
