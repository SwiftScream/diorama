# Decision 9: Normalization and redaction

- Status: Accepted
- Last updated: 2026-09-05
- Depends on: [Decision 1: Common abstraction](01-common-abstraction.md),
  [Decision 2: Shared and system-specific semantics](02-shared-vs-system-semantics.md),
  [Decision 3: Recorded behaviors](03-recorded-behaviors.md),
  [Decision 4: Replay selection](04-replay-selection.md),
  [Decision 5: Consumption and verification](05-consumption-and-verification.md),
  [Decision 6: Runtime-to-snapshot conversion](06-runtime-to-snapshot-conversion.md),
  [Decision 7: Persistence boundary](07-persistence-boundary.md),
  [Decision 8: Schema compatibility](08-schema-compatibility.md)

## Decision

How are volatile and sensitive values transformed before they enter matching,
diagnostics, referenced resources, and persisted snapshots?

## Context

Snapshot inputs commonly contain values that should not be compared literally
or committed to version control:

- authorization credentials, cookies, session identifiers, and API keys;
- personal data in URLs, headers, bodies, locations, and errors;
- generated request identifiers and tracing headers;
- server dates, signatures, nonces, and expiring tokens;
- machine-specific paths, process details, and unstable descriptions;
- exact wall-clock starts or coordinates that a test does not need.

These values create two different problems. Volatile data makes snapshots noisy
or impossible to match after re-recording. Sensitive data can leak through the
scenario file, external body resources, mismatch diagnostics, or testing
integrations.

The accepted architecture places stable semantic conversion at each system
boundary and gives systems ownership of domain meaning. A generic core cannot
correctly parse every HTTP body, decide whether a coordinate is private, or
know which custom identifier affects dependency behavior. It can nevertheless
enforce when transformations occur and ensure no later layer bypasses them.

## Terms

This decision uses distinct names for related operations:

| Operation | Purpose | Example |
| --- | --- | --- |
| Structural canonicalization | Give equivalent domain values one deterministic representation. | Normalize HTTP header-name casing and ordering. |
| Volatile-value normalization | Replace or remove a changing value whose exact value is not part of the intended scenario. | Replace a request ID with a stable placeholder. |
| Redaction | Irreversibly remove sensitive information from Diorama-controlled output. | Replace an authorization credential with a safe test value. |
| Match projection | Choose which already prepared fields participate in replay selection. | Ignore `User-Agent` when matching HTTP requests. |
| Authored override | Deliberately replace recorded behavior for replay. | Make an HTTP response take 12 seconds. |

These operations must not be collapsed into one generic "ignore" mechanism.
Match projection alone does not make a value safe to persist. Redaction changes
the replayable semantic value, while ignoring a field for matching changes only
selection. An override remains explicit authored behavior governed by decision
3 rather than an automatic sanitizer.

## Prepared stable values

Decision 6 introduced stable semantic values at the native system boundary.
This decision refines that boundary into two short-lived states:

1. A **capture-local stable value** is detached from the native API but has not
   necessarily been normalized or redacted. It remains inside the concrete
   system integration's controlled isolation.
2. A **prepared stable value** has passed the configured canonicalization,
   redaction, normalization, and validation pipeline. Only prepared values may
   enter generic scenario storage, matching indexes, diagnostics, or
   persistence.

The capture-local value is not another persisted model. It is temporary adapter
state used so transformations can operate on typed data rather than arbitrary
native objects.

"Prepared" means the value complies with the explicitly selected policy. It
does not guarantee that no personal data remains when the consumer deliberately
allows exact recording.

## Transformation order

The conceptual record pipeline is:

```text
observe native behavior and capture its logical-time token
    -> detach a capture-local typed value
    -> structurally canonicalize enough to address fields consistently
    -> apply confidentiality redaction
    -> apply configured volatile-value normalization
    -> validate the prepared semantic value
    -> admit it to the scenario track and diagnostic boundary
```

Redaction precedes other value transforms so a normalizer, diagnostic, or
extension is not accidentally given raw secrets it does not need. Minimal
structural canonicalization may run first when required to locate a field, such
as case-insensitively recognizing an HTTP authorization header. That phase must
not render or log raw values.

Every transformation should be deterministic and idempotent for the same value,
policy, and scenario context. It must not implicitly depend on current time,
locale, process identity, random values, or dictionary iteration order.

The pipeline also applies when persisted input is decoded. This ensures
manually edited values and authored overrides cannot bypass system validation
or configured redaction before entering generic diagnostics or canonical
rewriting. It cannot undo a secret that was already placed in a file, but it
prevents further propagation through Diorama-controlled output.

## Recording, replay, and re-recording

### Recording

The system prepares live inputs, intermediate phases, outputs, and failures
before recording them. Only prepared values become part of the working
candidate. Large payloads must not bypass the pipeline merely because they use
an external resource.

### Replay input

A native input is converted and passed through the same relevant preparation
policy before matching. A live authorization token can therefore become the
same safe placeholder stored in the recorded request. Matchers never need the
raw token.

### Replay output

Recorded outputs are already prepared. The native adapter materializes their
safe replay values. Redaction is not encryption: the original secret cannot be
recovered during replay. When application behavior needs a value, the persisted
snapshot must contain a safe substitute that satisfies the native API.

### Re-recording

New observations are prepared before correspondence and merge. Existing
persisted values are decoded and prepared through the currently configured
system policy, then decision 3's authored override rules apply. The complete
merged candidate is validated again before decision 7 permits publication.

## Ownership

The system or optional protocol-domain layer owns typed transformation semantics
because it understands the data. It decides:

- which fields are semantically equivalent after canonicalization;
- which values are known credentials or personal data;
- which volatile values can be replaced without changing intended behavior;
- which safe substitute remains valid for native replay;
- how structured bodies and errors can be traversed safely;
- which transformations affect input matching and output materialization.

The concrete adapter owns safe extraction and ensures capture-local values do
not escape. The scenario core owns the admission boundary: it accepts only the
system's prepared values and routes diagnostics through the safe representation
provided by that system.

Diorama may provide reusable transformation helpers, but should not use generic
reflection over arbitrary `Codable` values. A consumer-defined system owns its
payload rules and can reuse helpers appropriate to its types.

## Policy configuration

Transformation policy is selected during system setup and remains immutable for
one scenario execution. Application calls do not supply test-only sanitizer
identifiers or interact with Diorama after setup.

A system should distinguish policies that affect:

- recorded request or invocation inputs;
- recorded dependency outputs and failures;
- match projection;
- diagnostic rendering;
- external resources.

The setup surface should favor typed domain rules rather than unvalidated
string paths into arbitrary encoded JSON. Structured HTTP JSON or form helpers
can expose path rules when they own a real parser; opaque bytes remain opaque.

## Configuration source of truth

Transformation configuration belongs to consumer setup code, which is expected
to be versioned alongside the scenario files. The persisted scenario contains
the resulting prepared values, not a duplicate recipe, serialized closure, or
required transformation-profile identifier.

Replay and re-recording apply the currently configured system policy. A policy
change that alters prepared values should normally be committed with the
resulting snapshot diff. If the policy no longer corresponds to the persisted
values, ordinary conversion, matching, ambiguity, or recording-health
diagnostics expose the mismatch.

First-party default behavior is different from per-scenario configuration. If a
first-party release changes the persisted interpretation of a built-in rule, it
must evolve the owning system schema under decision 8 and retain the required
backward reader behavior. It does not need a second generic policy version.

This choice means a scenario is not independently replayable without the setup
code that attaches its systems and transformations. That is consistent with
Diorama's setup model. An optional diagnostic fingerprint for detecting policy
drift can be considered later without becoming part of initial replay
semantics.

## Redaction semantics

Redaction should normally replace a sensitive value rather than remove its
field when presence affects behavior. Examples include replacing a bearer token
with a valid test token or replacing a cookie value while preserving its name
and attributes.

A redaction rule must define:

- which typed value or field it recognizes;
- the safe recorded substitute or explicit removal behavior;
- how the same rule transforms replay inputs for matching;
- whether equality relationships between repeated values are intentionally
  preserved or collapsed;
- how its action is represented safely in diagnostics.

A constant placeholder is deterministic and simple but can make two distinct
secrets indistinguishable. If that creates ambiguous replay candidates, decision
4 reports the ambiguity. Scenario-scoped pseudonyms could preserve equality
relationships without storing raw values, but stable alias assignment and
re-record merge make this a separate feature rather than an automatic default.

Plain unsalted hashes are not a safe general redaction mechanism, especially
for low-entropy values. Keyed digests introduce key distribution and long-term
matching requirements. Neither should be an implicit built-in fallback.

## Planned enhancement: scenario-scoped named values

Scenario-scoped pseudonyms are valuable when one safe synthetic value appears
throughout several recordings. A future schema could declare a named value such
as `authenticationToken` once and let reference-capable fields use it across
systems and tracks.

This combines two related features:

- pseudonymization maps a live sensitive value to a safe synthetic value;
- a scenario-scoped named value gives that safe value a stable, reusable fixture
  identity.

The persisted declaration contains only the safe replay value. Any mapping from
the original live value remains ephemeral and never enters the scenario,
diagnostics, or setup configuration. Re-recording preserves the authored name
and safe value when candidate identity remains unambiguous.

The feature requires typed references rather than generic string interpolation.
Its design must diagnose missing, duplicate, cyclic, and type-incompatible
references and define how reference-capable fields participate across
heterogeneous system payloads.

These requirements are recorded now so the initial transformation model does
not assume every replacement is an unstructured string. The initial
implementation persists concrete safe substitutes directly, even when repeated.
Named declarations, reference syntax, automatic alias assignment, and
cross-system resolution are deferred to a later schema and implementation
milestone.

## Pragmatic defaults and consumer responsibility

Diorama is an engineering fixture tool, not a data-loss-prevention system. Its
defaults should protect well-known credential surfaces where a useful replay
substitute is practical, but they should otherwise preserve the recorded
semantics that make a scenario useful. Consumers remain responsible for the
data they choose to record and commit.

Recommended initial posture:

- Known HTTP credential fields, including authorization and cookie material,
  are replaced by safe values by default. Decision 11 will finalize the exact
  HTTP field set.
- Matcher defaults such as ignoring `User-Agent` remain matching policy and do
  not imply redaction.
- HTTP bodies are recorded unchanged by default because exact request and
  response body replay is a primary use case. Consumers can opt into typed
  sanitizers, substitutions, or removal for bodies that need them. Diorama does
  not claim that an unchanged body is free of sensitive data.
- Location observations are recorded with replayable fidelity by default.
  Decision 16 expresses horizontal observations as east/north meter offsets
  from a persisted WGS84 origin. An explicit origin override or setup default
  relocates the route without rewriting every observation. Without either, the
  persisted origin reveals the recorded location.
- Clock wall-time origins and successive signed observation deltas can be
  recorded exactly or normalized through a typed clock policy.
- Consumer-defined systems record their prepared stable values unchanged unless
  their attachment configures a transform.

These defaults retain useful recordings without presenting targeted credential
redaction as comprehensive sanitization. A project can centralize stricter
policies in its Diorama setup code when its data or repository access model
requires them.

## Diagnostics

Diagnostics are part of the redaction boundary. The core must not render a raw
capture-local value, arbitrary native error description, HTTP body, location,
or custom payload when transformation fails.

Systems should provide safe structured context such as:

- attachment and track identity;
- semantic field or coding path;
- current transformation or rule identifier when one is available safely;
- unsupported content type or value category;
- whether the candidate was made unhealthy;
- a safe comparison of already prepared values.

Decision 5's diagnostic sink and testing integrations receive only these safe
diagnostics. Diorama should not provide a generic "include raw value" logging
switch that can accidentally expose credentials in CI output.

## External resources

Referenced bodies and other external payloads are part of the same policy:

- a prepared safe resource can be staged and published by the repository;
- an existing external path deliberately owned by a custom system follows that
  system's declared policy;
- a raw temporary spool required for parsing remains adapter-owned sensitive
  state with restrictive access and reliable cleanup;
- an unsupported resource transformation makes the recording unhealthy rather
  than publishing raw bytes silently.

The initial implementation should avoid raw temporary spooling unless a
first-party system demonstrably needs it. Streaming redaction can be added for a
specific structured format rather than generalized prematurely.

## Failure behavior

A preparation or redaction failure follows decision 6:

- in record mode, preserve the live dependency behavior;
- immediately record a safe infrastructure diagnostic;
- mark the candidate unhealthy so decision 7 blocks normal publication;
- do not fall back to recording the raw value.

During replay, a missing policy, invalid prepared value, or failed input
transformation follows decision 5's infrastructure-error and deterministic
continuation rules. It never permits live fallback.

## Worked examples

### HTTP authorization and request IDs

A request contains a bearer token and a generated request ID. Structural
canonicalization recognizes the authorization header regardless of case. The
credential rule replaces its value with a safe test token. A configured
volatile-value rule replaces the request ID with a stable marker. The prepared
request is used for persistence, matching, and mismatch diagnostics.

Ignoring `User-Agent` in the matcher does not remove its prepared value from the
snapshot. A separate normalization or redaction rule is required to change what
is recorded.

### Login token replay

A login response body contains an access token that the application later sends
in an authorization header. A configured structured-body rule records a safe
synthetic token in the response, and the HTTP credential rule recognizes that
safe token in the later replay request. The original live token never enters
the scenario or diagnostics.

Supporting several distinct correlated tokens may later justify scenario-scoped
pseudonyms. The initial constant-substitute mechanism must report rather than
hide any ambiguity it creates.

### Location route

A location attachment records one WGS84 coordinate origin and east/north meter
offsets. Orthometric and ellipsoidal altitudes have independent optional
origins. An explicit persisted override wins over a setup-configured default,
which wins over the fresh observation. Setup defaults are applied before the
candidate is encoded, so raw origins do not enter persistence or diagnostics.

This representation improves editability and can support duplicating one route
at several origins. It is not comprehensive redaction: route shape, timing,
floor changes, movement, altitude, and source information may still disclose
context. Without a default or override, the original origin remains sensitive.

### Clock

A clock policy replaces the observed wall-time origin with a stable authored
origin while retaining successive signed wall-observation deltas. Re-recording
changes the observed values only where no authored override applies.

### Redaction failure

An HTTP attachment requires a JSON body sanitizer, but the live response claims
JSON and cannot be parsed. The application receives the live response. Diorama
reports the content type and configured rule without including body bytes,
marks the candidate unhealthy, and preserves the previously published scenario.

## Recommendation

Require every system to prepare stable values before they cross into generic
scenario storage, matching, diagnostics, resources, or persistence. Apply
minimal structural canonicalization, then redaction, volatile normalization,
and validation. Use the same relevant policy for recording and replay input.

Keep typed transformation semantics in the system or domain layer while the
core enforces the admission and diagnostic boundary. Keep per-scenario
transformation configuration in consumer setup code and prepared values in the
scenario. Treat redacted values as irreversible safe replay substitutes, not
encrypted originals.

Provide targeted safe defaults for known credential fields. Preserve HTTP
bodies, location observations, and consumer-defined prepared values by default,
with opt-in typed transformations for projects that need stricter handling.
Never silently fall back to an unprepared raw value when a configured
transformation fails.

## Consequences

Benefits:

- Snapshot files, resources, and diagnostics share one safety boundary.
- Replay matching uses the same prepared representation as recording.
- Volatile values can be stabilized without conflating matching and storage.
- Domain-specific policies remain meaningful for HTTP, location, clock, and
  consumer systems.
- Failed redaction cannot silently leak raw data into a healthy publication.

Costs:

- Systems must design typed transformation and safe diagnostic behavior.
- Unchanged bodies, locations, and custom payloads can contain sensitive data;
  consumers remain responsible for reviewing what they commit.
- Redacted output can change application-visible replay values.
- Constant placeholders can collapse otherwise distinct match candidates.
- Configuration drift may be diagnosed only when conversion, matching, or
  re-recording exposes it.

## Explicit non-decisions

This proposal does not determine:

- concrete transformation protocols, builders, or key-path APIs;
- the exact first-party HTTP sensitive-header list;
- built-in JSON, form, or multipart body-rule syntax;
- scenario-scoped named-value syntax, resolution, and pseudonym assignment;
- optional transformation-policy fingerprints for drift diagnostics;
- secure temporary-file implementation for a future streaming sanitizer;
- exact normalization helper declarations beyond the accepted location and
  clock semantics;
- organization-specific data classification or repository access policy;
- encryption or secret-management features.

## Review questions

1. **Safe admission boundary: Resolved.** Only prepared stable values enter
   generic scenario tracks, matching, diagnostics, external repository
   resources, or persistence. Capture-local unsanitized values remain confined
   to the concrete system integration's controlled isolation.
2. **Semantic separation and ownership: Resolved.** Systems or domain layers
   own typed canonicalization, redaction, and volatile normalization. Match
   projection and authored overrides remain separate mechanisms, while the core
   enforces only the prepared-value admission boundary.
3. **Redaction behavior: Resolved.** Redaction persists irreversible safe replay
   substitutes or explicit removal rather than encrypted originals, and applies
   the same relevant transform to replay inputs. Hashing is not an implicit
   fallback. Scenario-scoped pseudonyms are valuable but require separately
   specified reference semantics.
4. **Policy ownership: Resolved.** Per-scenario transformation configuration
   lives in consumer setup code versioned alongside its snapshots. Persisted
   scenarios contain prepared values without a required policy identifier.
   First-party changes to built-in persisted semantics evolve through the
   owning system schema; optional policy fingerprints are deferred.
5. **Default posture: Resolved.** Diorama provides targeted default redaction
   for recognized credential fields such as HTTP authorization and cookie
   material, but records HTTP bodies and location observations with replayable
   fidelity by default. Consumers own the decision to apply stricter policies.
   Decision 16 makes streams relocatable through WGS84 origins and east/north
   offsets while warning that route context may remain sensitive.

These resolved points constitute the accepted answer to decision 9.
