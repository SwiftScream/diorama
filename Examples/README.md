# Diorama examples

Run the random example from the repository root:

```sh
swift run --package-path Examples DioramaRandomUsage
```

It records random values in memory, replays the returned definition in a new
execution, then records to a temporary JSON file and replays that file. The
program checks that both replays return the recorded values and that file replay
does not publish a new document. It removes its temporary file afterward.

The executable uses one random system so the file workflow stays easy to follow.
For an example of **authoring a persistable system**, see the compiled
[consumer registration](../Tests/DioramaConsumerTestSupport/ConsumerPersistedSystem.swift).
Its shared `ScenarioSystemType` holds a versioned
`PersistentSystemRegistration`. The private `Codable` payload stores integers;
the public semantic value itself does not conform to `Codable`. The reader
validates and admits those values into the typed track. File-backed `Diorama`
setup collects that capability from the configured system, with no separate
registration list. The corresponding
[conformance tests](../Tests/DioramaConsumerTests/PersistedConsumerConformanceTests.swift)
cover multiple keyed systems, all three modes, report facts, and concurrent
random domains.

The canonical macOS and Linux checks build and run this command-line example.
The iOS job verifies the library package and its tests; this example is a
command-line executable for macOS and Linux.
