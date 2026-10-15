# 003-Ra4: Structured retained reports

- Date: 2026-10-15
- Status: Complete.
- Plan: [003-Ra4](../plans/003-clean-slate-implementation.md#003-ra4--review-structured-retained-report-evaluation)
- Authority: Owner-approved result/report structure, naming, implementation,
  feature branch, and PR. [DD18](../design-decisions/18-diorama-setup-and-scenario-data.md#structured-retained-reports--owner-approved-2026-10-15)
  and [DD05](../design-decisions/05-consumption-and-verification.md#structured-completed-evaluation--owner-approved-2026-10-15)
  record the accepted amendments.

## Result and report ownership

`DioramaResult<Success>` remains the successful return from `execute`. It stores
`body`, `report`, the optional healthy `definition`, exact optional `loadResult`,
and detailed `publication`. The body, output definition, loaded baseline, and
arbitrary underlying errors remain caller-owned. Healthy definitions still
support in-memory inspection/replay and explicit publication after an encoding
or storage failure; persistence remains optional.

`DioramaReport` stores two immutable values:

- `finalization: ScenarioFinalizationFacts`: Core diagnostics/recording health,
  ordered attachment usage, and attachment cleanup outcomes.
- `publication: DioramaPublicationSummary`: safe prior-document, disposition,
  preservation, candidate-count, and issue evidence.

The consumer builds one report before returning or rethrowing the original body
error. The returned result and `Diorama.report` hold that same value. Neither
report property retains a semantic definition, body value/error, native
resource, storage backend, or arbitrary error. No rendered text is stored.
`rendered()` generates the existing deterministic text on demand.

`evaluated(condition, attachments:)` delegates to the same Core facts used by
successful finalization. It preserves all existing conditions, scoping,
unclaimed-record waivers, unknown-key failures, and failure ordering. Publication
issues remain explicitly inspectable rather than implicitly changing Core
conditions. There is no automatic test failure or new diagnostic delivery API.
Core's `ScenarioFinalizationResult` now stores the definition and `facts`;
existing Core accessors, `evaluate`, and `rendered` delegate to those facts.

Startup failure still leaves the report nil; the startup error carries its own
evidence. Admission and cancellation still cover complete finalization and
publication. Sequential reuse clears the setup's previous report on admission,
while separately retained snapshots stay immutable.

## Public regression evidence

- `StructuredReportTests` records two Random values, consumes one, and compares
  successful and throwing replay reports. Empty diagnostics coexist with typed
  unclaimed-record evidence. Scoped evaluation, unknown keys, consumption,
  sequential reuse, complete subsequent replay, and repeated rendering are
  checked through public consumer APIs.
- `DioramaReportPayloadLifetimeTests` retains the setup and report while output
  payloads are released. A successful result keeps usable typed output until
  the caller releases it; a throwing body preserves its original error and
  releases output without report retention. Payload descriptions are never read.
- `DioramaReportOwnershipTests` proves that an exact successful load outcome
  retains its decoded baseline, while the setup/report does not. Precommit and
  postcommit publication errors remain exact caller-owned evidence on success,
  then release after either body outcome. Report rendering never describes those
  errors; publication issues remain separate from Core evaluation.
- Existing retained-report tests now assert structured cleanup-failure evaluation
  after the original body error. Existing admission, cancellation, dependency,
  body-value/error lifetime, healthy output recovery, publication refusal, and
  rendering golden tests continue to run against the migrated API.
- Core evaluation tests compare the extracted facts with the existing result
  evaluator for every condition and preserve its rendered output.

## Verification

Apple checks use Xcode 27.0 (27A266a), Apple Swift 6.4
(`swiftlang-6.4.0.34.1`), macOS 15 deployment, and iOS 18 deployment on the
iPhone 17 / iOS 27.0 Simulator:

- Core extraction: seven focused evaluation/rendering tests pass with warnings
  as errors before the consumer change.
- Consumer change: 12 focused report, publication, evaluation, and ownership tests
  pass in Debug, including their parameterized invocations.
- Eight focused evaluation/ownership tests also pass under optimized Release
  with warnings as errors, preserving payload/error release and original errors.
- `scripts/check` passes formatting, strict lint, all 464 host tests, the public
  system-authoring/lifecycle compiler probes, Release builds, and both examples.
- `scripts/coverage ios` passes the Release build, 463 Simulator tests, lifecycle
  compiler probes, and LCOV export.
- The pinned x86_64 Swift 6.4 Linux image under Apple Container (2 CPUs, 4 GB)
  passes all 464 tests, public compiler probes, Release/example builds, both
  examples, and LCOV export on an isolated rerun of the quality policy command.
- V-doc checks cover changed Markdown file links, the complete branch diff from
  its base, whitespace, the accepted amendments, and plan status.

The first local x86_64 Linux run under Apple Container passes all new report
regressions but exceeds existing five-second wall-clock guards in
`SchedulingLifetimeTests` (5.16 seconds) and `ScenarioClockTests` (5.05 seconds)
while Apple builds run concurrently. The isolated rerun passes the complete
Linux gate without weakening any timing threshold or assertion. Native Linux CI
also passes on the implementation revision; emulated timing remains sensitive
to host contention.

Required PR checks validate the revision's macOS, iOS, Linux, and Codecov matrix.
The implementation adds no dependencies, schemas, unsafe concurrency annotations,
or deployment changes. The source API migration is documented in the
[examples guide](../../Examples/README.md#completed-reports-and-caller-owned-output).

## Review boundaries and costs

The branch separates a behavior-preserving Core facts extraction from the
consumer API and ownership change with its tests, migration guidance, and design
records. The consumer's former `result.finalization` moves to
`result.report.finalization`; flat report diagnostics and publication fields move
under the corresponding properties. Core accessors remain available.

Retained reports now keep structured per-record usage metadata instead of a
rendered copy of those facts. Its size still grows with execution evidence;
no constant-space or measured performance improvement is claimed. Evaluation
and rendering never need the definition. J01/J02 can use the selected API, but
this work does not begin either integration or change publication/test policy.
