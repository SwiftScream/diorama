# 003-F02: Core track-header prerequisite

- Date: 2026-10-03
- Status: Complete; the owner authorized a separate pull request on 2026-10-03.
- Authority: The owner's F02 prerequisite request and subsequent review direction
  to make the header type generic and its value required. Later review chose
  `Void` for headerless tracks and removed whole-track equality.
- Review base: `master` at `bc2a17d`.

## Delivered boundary

`SequentialTrack<Value, Header>` stores a non-optional header beside its ordered
records. A headered track receives a prepared header and retains it even with
zero records. A headerless track uses `Header == Void` and stores `()`; it can
also hold any number of records. Public constructors cannot create a headered
track without its header.

`HeaderlessSequentialTrack<Value>` and
`HeaderlessSequentialTrackLease<Value>` name the `Void` specializations for
consumer code. They are type aliases, so they share the same storage, behavior,
and type identity as the two-parameter forms.

Headers require only `Sendable`. Tracks do not conform to `Equatable`.

`ScenarioAttachment` erases track types only for heterogeneous storage. It
rejects duplicate IDs on insertion and checks both generic types with one
typed cast on retrieval. A headered baseline is validated with its own
`ValuePreparation<Header>`. A record-mode
lease may replace the header repeatedly; the latest call to begin wins even
when earlier calls finish later. If no call replaces it, finalization keeps
the baseline header. Removing records leaves the track header in place. Failed
header preparation or any unfinished header call invalidates the candidate.

This prerequisite adds no clock model, clock persistence schema, or wall source.
F02 will adapt its clock offset to this Core contract after the prerequisite
lands.

## Verification

| Gate | Local result |
| --- | --- |
| Focused header suite | Six macOS tests pass, including non-Equatable headers, empty-recording retention, typed retrieval, recording/replay, repeated replacement, overlapping calls, failed replacement, and unfinished calls. |
| Current review revision | The full macOS suite, SwiftFormat, and strict SwiftLint pass. |
| Initial prerequisite revision | `scripts/check`, macOS coverage, and iOS Simulator coverage passed before the review revisions. |
| Linux | Docker is installed but its daemon is unavailable locally. Required PR CI provides the Linux test and coverage gate. |

The isolated branch contains one Core implementation commit. The complete diff
against `master` is the review surface. F02 remains on its separate branch for
a rebase after this prerequisite lands.
