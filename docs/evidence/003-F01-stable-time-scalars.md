# 003-F01: Shared stable time scalar codecs

- Date: 2026-10-03
- Status: Implementation complete and owner review closed on 2026-10-03;
  current-revision macOS verification is recorded below.
- Authority: The owner's 2026-10-01 confirmation of F01 scope and GPT-6 Sol at
  `high` reasoning, [Decision 8](../design-decisions/08-schema-compatibility.md),
  [Decision 15](../design-decisions/15-clock-system.md), and the
  [approved plan](../plans/003-clean-slate-implementation.md#003-f01--shared-millisecond-duration-and-iso-8601-codecs).
- Review base: `master` at `f6bf08f`, with E01–E03 merged and later Phase E work
  left on its separate review branch.

## Delivered boundary

`StableTimeCodec` in `DioramaCore` reads signed ASCII `ms` and `s` values into
`Int64` milliseconds, writes one canonical duration form, and rejects malformed
or overflowing text. It also reads and writes ISO 8601 wall origins as a
Foundation `Date` and a separately retained numeric UTC offset. Foundation
parses the full date text, including forms it normalizes.
The codec retains a trailing offset when Foundation can safely format its fixed
`TimeZone` across the supported platforms; otherwise it stores zero and later
writes the absolute instant in UTC. The writer uses that `TimeZone` in
Foundation's `Date.ISO8601FormatStyle` and always writes three fractional digits.
Foundation's `Z` suffix is the canonical form for zero offset and parses back
to zero offset minutes.
The style is available below the supported Apple deployment floors and is
`Sendable`. The reader keeps fractional and nonfractional parsing attempts for
iOS 18 and macOS 15, whose Foundation versions predate the single-parser
behavior documented in the [iOS 26](https://developer.apple.com/documentation/ios-ipados-release-notes/ios-ipados-26-release-notes)
and [macOS 26](https://developer.apple.com/documentation/macos-release-notes/macos-26-release-notes)
release notes. On the tested macOS release, the style can write an exact `.999`
millisecond as `.998`; formatting from inside the selected millisecond restores
canonical output. The writer trusts Foundation's formatted text without
reparsing it.
Parsing and formatting each round a `Date` to the nearest millisecond without
converting the origin to absolute `Int64` milliseconds. An exact tie in the
represented value rounds away from the Unix epoch. Later wall-source recording
will round each `Date` before deriving successive deltas.

The [scalar format contract](../stable-time-scalars.md) states accepted and
rejected forms, canonical output, the portable fixed-offset limit, and the
rounding rule. F01 adds no clock attachment, wall track, persistence schema,
scheduler behavior, third-party package, or deployment-floor change. F02 owns
the version-one clock payload and strict cumulative wall recording model.

## Proving fixtures and tests

Committed independent JSON goldens cover signed zero, negative fractional
seconds with zero whole seconds, `Int64.min` and `Int64.max`, a pre-epoch
millisecond, offsets across UTC day boundaries, Foundation-normalized calendar
dates and times, extra fractional digits, the `±14:00` portable offset limit,
year endpoints, UTC fallback for parsed but unrepresentable suffixes, and
canonical output with three digits, including `.000Z` for a whole second at UTC.
Rejection cases cover duration overflow, excess precision, locale-specific
syntax and digits, and date text that Foundation cannot parse. Malformed
textual offsets and leap seconds are not fixed acceptance or rejection goldens
because Foundation's handling varies by release. Tests also cover
per-observation `Date` rounding, exact numeric rounding ties, millisecond
boundaries around the Unix epoch, and offsets selected from winter and summer
instants in one daylight-saving timezone.

## Verification

| Gate | Local result |
| --- | --- |
| Focused codec suite | Six tests pass on macOS. |
| `scripts/check` | Attempted; this sandbox denied SwiftLint's cache write. SwiftFormat passed and strict SwiftLint passed with `--no-cache`. The equivalent macOS test and build commands passed with SwiftPM's subprocess sandbox disabled. |
| macOS test and release builds | All 239 host tests pass with compiler warnings treated as errors. The package release build passes. The examples release build and execution pass with debug-symbol generation disabled; `dsymutil` fails with `Operation not permitted` in this sandbox. |
| macOS coverage | All 239 tests pass with coverage enabled. SwiftPM's Codecov JSON reports 115 of 115 executable codec lines covered. The canonical LCOV export was not run in this sandbox. |

Apple verification uses Xcode 27.0 (`27A266a`) and Apple Swift 6.4
(`swiftlang-6.4.0.34.1`). The required PR jobs provide the current-revision
iOS Simulator and Linux results. The iOS job proves the installed simulator
runtime with the iOS 18 compile-time floor; it does not establish behavior on
an iOS 18 installation.

## Review boundary

The feature commit contains the core codec, package fixture registration,
goldens, tests, and format documentation. The separate documentation commit
contains this evidence and the plan-status update. The owner closed review and
authorized PR creation on 2026-10-03. Required PR quality and platform jobs
provide the integration gate for this unit.
