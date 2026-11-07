# 003-H04 — Standard HTTP matching and safe differences

- Date: 2026-11-08
- Status: Complete; initial and review verification are recorded below.
- Owning unit: [003-H04](../plans/003-clean-slate-implementation.md#003-h04--standard-http-matcher-and-safe-differences)
- Base: `feat/003-h03-http-preparation` at `513c544`.
- Contract: [Prepared request matching](../http-message-schema-v1.md#prepared-request-matching).

## Delivered behavior

The owner confirms the stated scope, stacked feature branch, and recommended
GPT-6 Sol / high reasoning setting before implementation.
`HTTPRequestMatcher` projects admitted requests into immutable match values.
The default compares literal prepared method, scheme, authority, path/query,
logical body bytes, and prepared fields. No implicit query, JSON, or multipart
normalization is introduced.

`HTTPMatchFields` exposes explicit `including` and `excluding` enum cases, with
no implicit defaults. `.standard` excludes the public `defaultExclusions` set;
ordinary set union and subtraction support additional exclusions and opt-ins.
An empty inclusion set ignores every field; an empty exclusion set matches every
field. Names compare without case;
interleaving between names is ignored while repeated byte-value order remains
significant. Projection preserves absent versus present-empty content and
resolves resource content through a controlled caller-supplied closure before
selection. Inline/resource storage and resource paths do not affect equality.
Resolver failures become one safe typed error without retaining underlying
errors or resource paths.

Typed custom comparisons receive resolved projections; custom Core selectors
remain available for unresolved ambiguity. The selector bridge uses existing
Core FIFO claims, exhaustion, and identity validation. Safe differences use fixed
component categories and static policy labels. Prepared messages and persisted
schemas remain unchanged; no manifest, dependency, platform, concurrency
exception, native adapter, resource repository, or lifecycle change is needed.
Adapters remain responsible for removing internal routing metadata before
admission. Projections must use the same setup policy, and custom matchers must
be deterministic equivalence relations. Resource bytes must already satisfy the
selected preparation policy. This unit resolves logical bytes, without defining
resource storage or streaming APIs assigned to later units.

## Behavioral evidence

Ten test functions, including parameterized cases, cover name case and field
interleaving, repeated-value order, every default exclusion and opt-in, meaningful
custom and conditional fields, explicit inclusion/exclusion without inherited
defaults, empty field selections, absent/empty and
inline/resource bodies, different resource paths, missing/failed resolution,
query ordering, method/scheme/authority, opaque field bytes, credential
preparation, and typed custom comparison.

A real Core execution proves reordered requests, repeated equivalent FIFO claims,
exhaustion, no match, and explicit custom-selector ambiguity. It asserts exact
retained issue categories and identities and verifies secret markers in request
paths never appear in rendered diagnostics. Credential projection compares safe
substitutes while original requests retain their live values.

## Initial implementation verification

- Toolchain: Xcode 27.2 (`27B52`), Apple Swift 6.4.2
  (`swiftlang-6.4.2.1.9`), arm64 macOS host.
- `scripts/coverage swiftpm macos` passes fresh-build tests, release builds,
  compiler probes, examples, and LCOV export. Matcher source coverage is
  108/108 executable lines (100%).
- `scripts/check` passes formatting, strict lint, all host tests, debug/release
  warning-as-error compilation, public compiler probes, coverage tooling fixtures,
  and examples.
- `scripts/coverage ios` passes the complete iPhone 17 / iOS 27.2 Simulator
  suite, release build, lifecycle compiler probes, and LCOV export with the
  iOS 18 deployment floor. Matcher source coverage is 108/108 executable lines
  (100%). This does not establish execution on an actual iOS 18 runtime.
- V-doc: all 302 local file links across the changed documentation resolve;
  the complete H04 diff passes `git diff --check`.
- Local Linux is unavailable: `container system status` reports “apiserver is not
  running and not registered with launchd.” No Linux execution is claimed.
- Required PR checks enforce formatting/lint, macOS, iOS, Linux, and Codecov
  verification before merge.

Initial sandboxed Swift commands cannot write the standard toolchain module
cache; checks use normal cache access. Initial checks catch an ambiguous
initializer reference, use of internal Core test fixtures without a testable
import, incorrect diagnostic-report access, and formatting/lint findings. These
are corrected before passing checks. No warning suppression or lint exception
is added.

## Review verification — 2026-11-10

- `swift test -Xswiftc -warnings-as-errors --filter HTTPRequestMatcherTests`
  passes all ten matcher test functions on macOS, including parameterized cases.
- `scripts/check` passes formatting, strict lint, host tests, debug/release
  warning-as-error compilation, public compiler probes, coverage tooling fixtures,
  and examples. The initial sandboxed run reports no lint violations but cannot
  save SwiftLint's cache; the gate passes with normal cache access.
- `git diff --check` passes for the review fixup and complete H04 diff.
- Per owner instruction, this review runs macOS validation only. iOS, Linux, and
  fresh coverage collection are not rerun; the initial coverage figures above
  describe the original implementation.

## Review unit

The atomic implementation commit contains the matcher/projection, proving tests,
public contract, documentation index, plan status, and this evidence, including
the owner-approved review update that makes field selection an explicit public
enum and exposes the default exclusion set. The complete
H04 diff is against `513c544`, excluding the prerequisite H01–H03 stack. The owner
approves review and authorizes stacked PR creation on 2026-11-11, with H04 targeting
`master` and H05 targeting H04. Merge requires passing required PR checks and a
separate explicit owner request.
