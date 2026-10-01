# Stable time scalars

Plan 003-F01 supplies shared scalar codecs in `DioramaCore`. They define the
text and arithmetic used by later clock, location, and HTTP payloads; they do
not define those systems' schemas or runtime behavior.

## Durations

`StableTimeCodec.parseDuration(_:)` returns signed `Int64` milliseconds. The
reader accepts ASCII integral milliseconds (`+250ms`, `-1500ms`) or ASCII
seconds with zero to three fractional digits (`5s`, `1.5s`, `-0.001s`). A leading
sign is optional. It rejects whitespace, exponents, locale-specific decimal
separators or digits, a fraction on `ms`, extra precision, and overflow. It
does not impose a nonnegative rule: each field validates whether a negative
duration is meaningful.

`formatDuration(_:)` writes `0ms` for zero, integral seconds when exactly
divisible by 1,000, and integral milliseconds otherwise. For example, the
accepted `1.5s` writes as `1500ms`.

## Wall origins

An origin is an absolute Foundation `Date` and a numeric offset in whole
minutes east of UTC. The offset is retained to write the origin; replay needs
only the `Date`. The reader gives the full text to Foundation's ISO 8601
format style, trying its fractional and nonfractional forms. Both attempts are
needed on iOS 18 and macOS 15. It does not check the
date-field grammar separately. Foundation may normalize a calendar value, such
as February 30, or accept more than three fractional digits; canonical output
reflects the parsed `Date` rounded to milliseconds. `parseOrigin(_:)` returns
that rounded `Date`, so replay sees the same millisecond instant. Foundation's
handling of malformed calendar fields and out-of-range textual offsets may
vary by release; these are not guaranteed accepted forms.

The reader separately extracts a trailing ASCII `+HH:MM` or `-HH:MM` offset.
It retains the offset only when the numeric fields are in range and Foundation
can safely format its fixed `TimeZone` on every supported platform. Otherwise
the retained offset is zero; the absolute `Date` from Foundation is unchanged.
This includes `Z`, compact offsets, and parsed offsets beyond `-14:00` through
`+14:00`. The portable limit also avoids a Linux Foundation formatting crash
with larger fixed offsets.

The writer gives the rounded `Date` and retained fixed `TimeZone` to
Foundation's ISO 8601 format style. Canonical output always writes exactly three
fractional digits, including `.000` for a whole second. Zero offset writes as
`Z`, which the Foundation parser also accepts.
The formatter's numeric offset is a display choice; no regional timezone or
daylight-saving rule is persisted. The writer declines a nonfinite `Date` or an
offset outside the portable fixed-timezone range. Some Foundation releases
format an exact millisecond as the preceding millisecond; the writer formats
from within the selected millisecond to avoid that rounding artifact.

`roundedToMillisecond(_:)` returns a `Date` and does not convert an origin into
an absolute integer millisecond count. It rounds each represented absolute
instant separately to the nearest millisecond; an exact halfway value rounds
away from the Unix epoch. Later recording logic selects the offset at the
observation instant and derives successive deltas from independently rounded
`Date` values.

The committed
[scalar goldens](../Tests/DioramaCoreTests/Fixtures/stable-time-goldens.json)
include exact absolute millisecond values and both canonical and rejected
forms. They are independent of the codec's writer.
