# 003-H03 — Typed HTTP preparation

- Date: 2026-11-08
- Status: Complete; stacked PR creation is owner-authorized on 2026-11-08.
- Owning unit: [003-H03](../plans/003-clean-slate-implementation.md#003-h03--typed-http-preparation-and-credential-defaults)
- Base: `feat/003-h02-http-message-values` at `b130f75`.
- Contract: [HTTP preparation and credential admission](../http-message-schema-v1.md#preparation-and-credential-admission).

## Delivered behavior

The owner confirms scope and GPT-6 Astra at high reasoning before implementation.
`HTTPPreparation` builds typed request, response-head, body, and adapter-owned
failure preparation on Core's existing `ValuePreparation`. Case-insensitive field
addressing preserves repeated-field order and unrelated raw bytes. Credential
redaction precedes consumer redaction and normalization; final validation prevents
normalizers from reintroducing incompatible credentials. Original input values
remain intact. No native consumer-delivery policy is implemented in this unit.

Defaults cover Authorization, Proxy-Authorization, Cookie, Set-Cookie,
Authentication-Info, and Proxy-Authentication-Info. Conservative syntax checks
retain supported authentication schemes, cookie names, and recognized cookie
attributes; malformed or unsupported shapes receive valid fixed whole-field
substitutes and safe non-invalidating warnings. Explicit setup rules
support custom fields, removal, and application-specific fixture tokens. Their safety is
consumer-owned. Defaults leave bodies, arbitrary custom fields, challenge fields,
and URL values unchanged; consumers can supply typed transforms.

Decoded and edited baselines undergo validation only, as required by DD09's
persisted-value amendment. The plan's older “same preparation” wording is clarified
accordingly. Direct message codecs establish structural validity, while selected
policy admission establishes credential invariants. Later lifecycle and adapter
units must invoke these policies at their admission boundaries. There is no new
HTTP system registration, native error taxonomy, resource I/O, matching policy,
body placement, or dependency adoption. The manifest adds the existing Core
target as a direct HTTP/test dependency.

Failure diagnostics use static labels and Core's existing stage categories;
underlying consumer errors and captured payloads never become failure evidence.
Recording failures invalidate candidates; replay failures remain infrastructure
facts without live fallback. Preparation warnings do not invalidate candidates.

## Initial implementation verification (`11cf700`)

- `swift test --filter HTTPPreparationTests -Xswiftc -warnings-as-errors` passes.
  The subsequent host gate includes all seven preparation tests (32 parameterized
  cases and individual invocations), plus existing message fixtures.
- `scripts/check` passes strict format/lint, host tests, debug/release builds,
  public authoring/lifecycle compiler probes, coverage-script fixtures, and examples.
- `scripts/coverage swiftpm macos` passes the fresh-build host gate and LCOV
  export. New source line coverage is 196/198 (98.99%).
- `scripts/coverage ios` passes the complete iPhone 17 / iOS 27.2 Simulator
  suite, release build, lifecycle compiler probes, and LCOV export using the
  iOS 18 deployment floor. New source coverage is also 196/198 (98.99%). This
  does not establish execution on an actual iOS 18 runtime.
- Final `scripts/lint` passes with zero violations. V-doc verifies all 300 local
  file links across changed documentation; the complete diff passes
  `git diff --check`.
- Local Linux cannot run: `container system status` reports “apiserver is not
  running and not registered with launchd.” No local Linux result is claimed.
  The required platform matrix and Codecov checks remain merge requirements.

Tests cover all six credential names; malformed and unsupported auth/cookie
syntax; Digest and supported attributes; repeated cookies; raw non-UTF-8 fields;
unchanged request bodies and live originals; deterministic idempotence; codec
round trips followed by policy admission; rejection of unprepared/edited
credentials; explicit replacements/custom keys; transform ordering; and safe
recording/replay failure health. Stored typed values bypass capture transforms.

The first sandboxed Swift invocation cannot write the toolchain module cache;
verification succeeds with the normal cache permissions. An initial test helper
omits the `ScenarioID` initializer label; that compilation error and initial
line-length/complexity lint findings are corrected before the passing gates.
No concurrency suppression or lint exception is added.

## Review unit

One atomic implementation commit includes the typed policies, focused tests,
manifest edges, public contract, plan status, and evidence. The full H03 diff is
against `b130f75`, excluding the H01/H02 stack. The owner authorizes publishing this branch and creating its stacked PR on
2026-11-08; merge requires a separate request and passing required checks.

## Owner-requested rule interface review update

The owner authorizes direct amendment of H03, without fixup commits. Rename the
policy to `HTTPFieldRedactionPolicy` and the setup property to `fieldRedaction`.
Built-in credential rules now use the same public `HTTPFieldRedactionRule`
interface as custom rules. Rule mappings overlay defaults case-insensitively.

Capture returns `.safe`, `.replace(value)`, `.replaceWithWarning(value)`, or
`.remove`. The policy owns warning emission and removal; the rule supplies every
replacement directly. `HTTPFieldValue` validates bytes without repair and exposes
optional UTF-8 text. Kept fields preserve name, order, bytes, and indexing strategy.
The diagnostic becomes `http.redaction.replacement-warning`.

Constant rules validate exact replacement bytes. Removal rules reject retained
prepared occurrences. Custom validators run after capture/normalization and on
baseline admission; admission never invokes their redaction closures. Absence is
valid for these per-field rules. A failed validator still rejects `.safe` or a
warned replacement, and a normalizer cannot reintroduce a removed field.

The review adds focused tests for custom decisions, binary values, repeated-field
removal, overrides, reusable built-ins, warning contents, prepared admission,
normalizer reintroduction, and safe failure health. Initial macOS/iOS coverage
figures above describe the original revision; this update uses focused tests and
the canonical macOS gate under the repository's review-verification policy.
The full platform matrix remains required through the authorized PR workflow.

Review verification passes:

- `swift test --filter 'HTTPPreparationTests|HTTPFieldRedactionTests'
  -Xswiftc -warnings-as-errors`: 14 tests pass, including all parameterized cases.
- `scripts/check`: strict formatting/lint, full host tests, debug/release builds,
  compiler probes, coverage-script fixtures, and examples pass.
- All 300 local file links in the changed documentation resolve; the complete
  H03 diff and isolated review update pass `git diff --check`.

The initial review gate catches one missing trailing comma in a test collection;
it is corrected before the passing gate. No warning suppression or lint exception
is introduced. Additional iOS/Linux checks and refreshed coverage are not claimed
for this review revision. The original platform evidence remains identified above.
