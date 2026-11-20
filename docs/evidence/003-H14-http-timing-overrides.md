# 003-H14 — HTTP timing overrides during re-recording

The owner confirms the H14 scope on 2026-11-21. The integration builds on the
H13 URLSession registration. The [HTTP schema](../http-message-schema-v1.md#re-recording-http-timing-overrides)
describes correspondence, delay ownership, and the track declaration.

## Exact fixture changes

The file-backed test runs the standard URLSession interactions track through
record finalization and compares the published JSON bytes with the candidate.

| Fresh invocation | Fresh failure delay | Published delay | Published failure code |
| --- | --- | --- | --- |
| `/two` | 5 ms | 5 ms observed | -2000 |
| First `/one` | 6 ms | 11 ms override | -2001 |
| Second `/one` | 7 ms | 22 ms override | -2002 |
| `/new` | 8 ms | 8 ms observed | -2003 |

The obsolete 44 ms override for `/gone` produces an informational fact
at baseline record 3. The canonical fresh and candidate documents differ
only at the first and second `/one` delays. Compare the
[baseline](../../Tests/DioramaURLSessionTests/Fixtures/rerecord-baseline.json),
[fresh recording](../../Tests/DioramaURLSessionTests/Fixtures/rerecord-fresh.json),
and [candidate](../../Tests/DioramaURLSessionTests/Fixtures/rerecord-candidate.json).

## Structural and publication checks

The [HTTP merge tests](../../Tests/DioramaHTTPTests/HTTPRecordingMergeTests.swift)
assign distinct overrides to every persisted delay in the lifecycle, redirect,
and authentication fixtures. They compare the entire merged value against that
independent input. Additional cases change decision branches, segment counts
and weights, conclusions, resources, and match policies. Combining a valid
baseline head override with a valid fresh completion can overflow a local
duration. The checked HTTP constructors reject that merge.

A refused redirect's disposition retains overrides along its own path. When
fresh capture records direct delivery instead, the old disposition and its
body overrides become obsolete while the redirect presentation can retain
its own override.

The [URLSession publication tests](../../Tests/DioramaURLSessionTests/URLSessionRecordingMergeTests.swift)
also run an overlapping custom comparison and an unhealthy capture against a
real file. Both preserve the prior fixture byte for byte. The ambiguous run
reports a safe record identity and the need for resolution. The unhealthy
capture skips correspondence altogether.

The standard matcher groups hashable projections directly. A custom comparison
can require quadratic comparisons among distinct projections to detect
overlapping groups. Repeated identical projections reuse their group. Merge
uses owned body bytes and needs no native adapter, external package, or
persisted correspondence key.

## Verification

On arm64 macOS with Xcode 27.2 (27B52) and Apple Swift 6.4.2, the focused
command passes all 12 tests, including the three fixture arguments in the
lifecycle timing test.

```sh
swift test -Xswiftc -warnings-as-errors --filter 'HTTPRecordingMergeTests|URLSessionRecordingMergeTests'
scripts/check
```

The canonical macOS gate passes all 856 tests across nine test products,
formatting and strict lint, coverage-tool fixtures, compiler probes, release
builds, and the Random and Date examples. Local platform verification for H14
covers macOS. The repository's integration gate also requires iOS Simulator
and Linux CI.
