# Clock wall payload schema version 1

Plan 003-F02 adds the portable `DioramaClock` wall recording model and the
first-party `diorama.clock` payload schema version 1. A clock attachment uses
one `wall` track. In memory, that track stores absolute dated observations as
Core `OverridableValue<Date>` values and a typed header holding the origin's numeric UTC
offset. The header is absent for an empty track. Its declared empty track is
distinct from a missing clock attachment.
The schema model and its attachment builders are internal to `DioramaClock`.
`DioramaClockSystem.instance(named:sourceFactory:)` creates a live wall
attachment. Record mode captures native `Date` values in source order, rounds
each absolute value independently, and selects the origin's numeric timezone
offset from the first observation using `TimeZone.current` captured at activation.
Re-recording clears the old header and produces a fresh observed origin and
offset. The planned F05 merge preserves an authored whole-origin override, including
its offset; there is no independent offset override. With no new observations,
the empty payload drops the old origin and offset.
Passthrough returns native values without changing the track. Replay claims
effective values sequentially and never activates the live source factory.
The lease returns stored `OverridableValue<Date>` entries; the clock extracts
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
[editing and canonical output fixtures](../Tests/DioramaClockTests/Fixtures/clock-edited.json)
show this transformation.

The reader rejects missing or extra fields, unknown tags or versions, invalid
scalar text, an origin without observations, observations without an origin,
nonzero ordinary position zero, and cumulative overflow. The first-party
schema is deliberate `Codable`; the JSON envelope and deterministic whitespace
follow the [repository schema](persistence-schema-v1.md). Version 1 is the
only clock payload version currently read or written. No older public clock
schema exists to migrate.
