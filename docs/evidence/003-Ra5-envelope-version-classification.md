# 003-Ra5: Envelope-version classification

- Date: 2026-10-15
- Status: Complete.
- Plan: [003-Ra5](../plans/003-clean-slate-implementation.md#003-ra5--classify-missing-envelope-versions-consistently)
- Authority: Owner request to fix Ra5 on its own branch and raise a PR.

## Behavior

The envelope header checks for an absent `schemaVersion` before numeric
decoding. Both a missing `diorama` header and an empty header now report
`PersistedScenarioCodingError.unversionedEnvelope`; repository loading preserves
that error as `incompatibleEnvelope`. The fix adds three production lines to
`PersistedScenario+Codable.swift` and changes no schema, version, or mode policy.

Present malformed values remain invalid documents. Zero and other unsupported
UInt32 versions preserve their declared value in the compatibility error.
Missing system-entry versions remain malformed rather than being classified
as absent envelope versions. Loading does not publish anything.

## Regression evidence

`EnvelopeVersionClassificationTests` uses public persistence imports and runs
the same documents through `JSONScenarioCodec` and `JSONScenarioRepository`.
Five tests cover eleven inputs: absent root header, absent nested version,
null, string, fractional, negative and overflowing versions, unsupported zero,
two and UInt32 maximum, and a missing system-entry version.

Before the fix, the empty-header case reproduces the wrong `malformed` codec
error and `invalidDocument` repository outcome. After the fix, the focused
suite passes. Fractional-number rejection checks the malformed classification
without imposing a Foundation-specific diagnostic path.

## Verification

On Apple Swift 6.4 / Xcode 27.0:

- `swift test -Xswiftc -warnings-as-errors --filter EnvelopeVersionClassificationTests`
  passes all five tests.
- `scripts/check` passes 453 host tests, formatting, strict lint, public
  authoring and lifecycle compiler probes, Release builds, and both examples.
- V-doc checks cover links, plan status, the complete branch diff, and whitespace.

Required PR checks cover the current revision's macOS, iOS Simulator, Linux,
and Codecov matrix. No dependency or accepted decision changes are introduced.
