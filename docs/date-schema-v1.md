# Date payload schema version 1

The portable `DioramaDate` wall recording model established in Plan 003-F02 uses
the first-party `diorama.date` payload schema version 1. A date attachment uses
one `wall` track. In memory, that track stores absolute dated observations as
Core `OverridableValue<Date>` values and a typed header holding the origin's numeric UTC
offset. The header is absent for an empty track. Its declared empty track is
distinct from a missing date attachment.
The schema model and its attachment builders are internal to `DioramaDate`.
`DioramaDateSystem.instance(named:sourceFactory:)` creates a wall
attachment. Record mode captures native `Date` values in source order, rounds
each absolute value independently, and selects the origin's numeric timezone
offset from the first observation using `TimeZone.current` captured at activation.
Re-recording clears the old header and produces a fresh observed origin and
offset. Finalization preserves an authored whole-origin override, including
its offset; there is no independent offset override. With no new observations,
the empty payload drops the old origin and offset.
Passthrough returns native values without changing the track. Replay claims
effective values sequentially and never activates the live source factory.
The lease returns stored `OverridableValue<Date>` entries; the date source extracts
their effective `Date` without changing stored authorship. The lease's configured
replay-last continuation repeats the last consumed entry or uses
`.observed(unixEpoch)` before any consumption. Continuation values have no record
identity and never become additional observations.
Repeated and backward dates are returned as recorded without waits. Exhaustion
reports a replay diagnostic and continues with the last successfully claimed
date, or Unix epoch when no value was claimed. Finishing the execution closes
claims; escaped wall handles continue with the last date and report the
separate lifecycle diagnostic.
An offset with subminute precision cannot be written in this schema; recording
reports a conversion failure while the live read still returns its native Date.

The payload has a required `observations` array. An empty array has no `origin`
field. A nonempty array requires an `origin` and starts with `0ms`:

```json
{
  "origin": "2030-01-01T09:00:00.000+11:00",
  "observations": ["0ms", "5s", "0ms", "-1s"]
}
```

Each later signed value is relative to the preceding effective wall value.
The codec derives those deltas from adjacent dates; the track itself does not
store origin or delta variants at record positions.
The example denotes 09:00:00, 09:00:05, 09:00:05, and 09:00:04 in the
origin's fixed offset. Deltas change returned wall values; they do not cause
replay waits. Effective cumulative deltas must fit `Int64` and produce
representable Foundation `Date` values. The origin and scalar text use the
[shared time codecs](stable-time-scalars.md). The numeric origin offset is a
display choice; it is not a regional timezone rule.

An observed field canonically writes as a string. An authored override writes
as an object containing only `override`. The reader also accepts an explicit
`observed` object or both keys in one object; when both exist, `override` wins.
For example, this edited position-one value is valid:

```json
{"observed":"5s","override":"-1s"}
```

An override at position zero shifts the effective origin by its signed value.
The runtime model marks the shifted origin as an override and resets position
zero to ordinary `0ms`. Later deltas are unchanged. Canonical writing retains
only the effective origin override. The
[editing and canonical output fixtures](../Tests/DioramaDateTests/Fixtures/date-edited.json)
show this transformation.

## Re-recording authored overrides

The date system registers its typed merge through the public
[recording merge boundary](record-services.md#recording-merge). It runs during
in-memory finalization before returning a healthy definition or publishing a
file. The baseline remains immutable; replay and passthrough preserve it.

First, record mode captures and prepares a complete fresh wall sequence. Its
successive deltas come from fresh independently rounded dates, before applying
any old override. Then the date system preserves an authored baseline origin with
its full absolute date and numeric display offset, and each later authored
delta at a position that still exists. Other fields use fresh observations.
The merged sequence is cumulatively validated and converted back to prepared
absolute dates for the track.

For example, fresh observations at 0s, 2s, and 9s yield deltas of 2s and 7s.
Preserving a 5s override at position one produces effective values at 0s, 5s,
and 12s. The later ordinary delta stays 7s, rather than being recalculated
against the earlier override. An authored origin shifts that complete sequence
to its chosen date while preserving its authored offset.

Correspondence is strictly positional. Inserting or removing a read can move
an override to another logical call site without changing its numeric position.
There is no heuristic rematching. Overrides beyond the new sequence length
are dropped; an empty new recording drops all old content, including the origin
and offset. These deliberate deletions do not invalidate publication.

A merge that cannot produce a valid cumulative sequence reports a safe
`recordingMergeFailed` fact and makes the whole candidate unhealthy. Live wall
reads still return their native observations; no healthy definition is returned
and the previous file is preserved. Canonical writing stores only effective
overrides, not the fresh observations they replace. The version-one schema
and its tolerant editing forms are unchanged.

The reader rejects missing or extra fields, unknown tags or versions, invalid
scalar text, an origin without observations, observations without an origin,
nonzero ordinary position zero, and cumulative overflow. The first-party
schema is deliberate `Codable`; the JSON envelope and deterministic whitespace
follow the [repository schema](persistence-schema-v1.md). Version 1 is the
only date payload version currently read or written.

## Former system identifier

The [owner-approved naming amendment](design-decisions/15-clock-system.md#date-system-naming-amendment--owner-approved-2026-10-09)
renames the former `diorama.clock` system to `diorama.date`. Existing recordings
must change each wall system's `type` value to `diorama.date`; its `schemaVersion`
and payload stay unchanged. There is no identifier alias or automatic migration.
Standalone decoding rejects `diorama.clock` as unknown. Consumer startup uses
its existing unknown-type and incompatible-baseline policies.

For complete public workflows, see [wall observations and execution time](date-usage.md).
The runtime execution clock requires no wall payload. A declared empty wall
still represents a wall system with zero observations, independently of
execution-clock use. The portable [composition fixture](../Tests/DioramaDateTests/Fixtures/date-composition.json)
combines independently keyed overridden, repeated, backward, and empty walls.
