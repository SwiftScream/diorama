# 003-B10: First production coverage baseline

- Date: 2026-09-16
- Plan: [003-B10](../plans/003-clean-slate-implementation.md#003-b10--first-production-coverage-baseline)
- Status: Complete locally; the owner confirmed the thresholds on 2026-09-16.
  Owner review is the next checkpoint.
- Authority: [Quality gates and CI policy](../quality-gates-and-ci.md#coverage),
  Q5 in [Plan 003](../plans/003-clean-slate-implementation.md#q5--delivery-selections-still-to-be-recorded),
  and the owner's 2026-09-16 threshold confirmation.

## Baseline and exclusions

The first production baseline is the B09 tip, `a5a07e2`, containing the
meaningful `DioramaCore` and `DioramaRandom` implementation. The current macOS
and iOS LCOV exports each report 1,491 covered lines of 1,525 executable source
lines (97.77%). Separate uploads remain necessary when platform-specific
products arrive.

The reports include only `Sources/**`. `.codecov.yml` continues to exclude
`Tests/**` and `Spikes/**`; it does not exclude product source, generated
coverage input, or any assertion-free test scaffolding. LCOV files stay under
the ignored `.build/coverage` directory.

| Platform | Result | Coverage |
| --- | --- | --- |
| macOS | 84 tests and warnings-as-errors release build pass | 1,491 / 1,525 (97.77%) |
| iOS | iOS 18 release build and 84 tests on iPhone 17 / iOS 27.0 Simulator pass | 1,491 / 1,525 (97.77%) |
| Linux | Post-rewrite local verification is unverified; the pinned x86_64 container entered compilation but its runner did not return a final result | — |

Linux uses `swiftlang/swift@sha256:15ae709b1d8eb1f8691b300f5721499d007e944694f2c0e9929a55580c9bf1a5`,
two CPUs, and 4 GB in Apple Container. The repository is read-only in the
container and copied to its writable work directory before coverage runs.

## Confirmed regression policy

The owner confirmed the following settings after reviewing the baseline:

| Status | Setting | Effect |
| --- | --- | --- |
| Project | `target: auto`, `threshold: 1%`, `base: auto` | Compare against the previous commit and permit at most a one-percentage-point regression. |
| Patch | `target: 90%`, `threshold: 0%`, `base: auto` | Require 90% changed-line coverage with no extra tolerance. |

The project setting is deliberately baseline-relative rather than a fixed
97.77% floor. It keeps the gate meaningful as the product gains legitimately
harder-to-test platform boundaries, while its explicit one-point tolerance
prevents incidental measurement movement from blocking a reviewed change.
The patch setting replaces the temporary 10-percentage-point tolerance and
requires focused tests for newly changed source.

## Upload completeness and hosted evidence

The existing workflow still uploads exactly one explicit LCOV artifact per
required platform with the `macos`, `ios`, and `linux` flags. Each Codecov
action has `fail_ci_if_error: true`; a failed or skipped upload therefore
fails its required platform job. Codecov requires CI to pass, waits for three
uploads before notification, and has carryforward disabled for all three flags.
No platform upload, test, or failure behavior was disabled in this unit.

The B09 branch has not yet been pushed or opened as a pull request, so this
unit cannot claim a new hosted Codecov status for its baseline. The authenticated
three-platform upload topology is established by
[003-A04](003-A04-quality-and-ci-bootstrap.md#hosted-verification). Hosted
Quality, macOS, iOS, Linux, and Codecov statuses remain required before a
future PR revision is merged.

## Local verification

- `scripts/coverage swiftpm macos` passes and writes repository-relative LCOV.
- `scripts/coverage ios` passes and writes repository-relative LCOV.
- The canonical Apple Container Linux command passes and writes LCOV; an
  isolated repeated run copies the resulting file only to a temporary directory
  to calculate the reported Linux line count.
- The Codecov documentation confirms `target: auto` compares with the base
  commit, `threshold` is the permitted percentage-point drop, and
  `after_n_builds: 3` delays notification until all expected reports arrive.
