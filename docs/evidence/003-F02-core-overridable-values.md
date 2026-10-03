# 003-F02: Core overridable-value prerequisite

- Date: 2026-10-03
- Status: Complete; the owner requested a separate pull request on 2026-10-03.
- Authority: The owner's approved F02 Core prerequisite for one effective
  observed or authored value, independent of persistence policy.
- Review base: `master` at `674f112`.

## Delivered boundary

`OverridableValue<Value>` stores exactly one effective `Sendable` value and
whether it is an ordinary observation or an authored override. Its `value`
accessor exposes the effective value, `isOverride` reports authorship, and
`map` transforms the value while preserving that authorship. Equality is
available only when the wrapped value is `Equatable`.

The type does not define a persistence schema, merge policy, or how an owning
system handles overrides during recording. Edited persistence forms containing
both an observation and an override must resolve to one effective value before
constructing this runtime model.

## Verification

| Gate | Local result |
| --- | --- |
| Core behavior | Two focused tests cover effective values, authorship, conditional equality, and mapping a non-Equatable value. |
| Canonical local gate | `scripts/check` passes SwiftFormat, strict SwiftLint, the full macOS test suite, warning-free release builds, and the example run. |

The branch contains one Core implementation commit and this evidence update.
The complete diff against `master` is the review surface.
