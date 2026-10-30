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

Run the date example from the repository root:

```sh
swift run --package-path Examples DioramaDateUsage
```

It records wall observations across a monotonic retry delay to a temporary
JSON file, replays without additional live reads, and verifies unchanged file
bytes. Its injected source moves wall time backward while the execution clock
continues forward. It also runs a delay with no wall attachment or persisted
observations. The application helper accepts the standard Swift `Clock`
protocol. See the [date usage guide](../docs/date-usage.md) for attachment
modes, overrides, timeout composition, and lifecycle limitations.

The canonical macOS and Linux checks build and run both command-line examples.
The iOS job verifies the library package and its tests; this example is a
command-line executable for macOS and Linux.

## Completed reports and caller-owned output

A successful `execute` returns `DioramaResult<Value>`. Its `body` is the
application value, and `definition` is the complete healthy scenario when
available. Keep the definition to replay in memory or publish explicitly;
encoding or storage failure does not discard it. Exact load and publication
outcomes remain on `loadResult` and `publication`, including underlying errors.

`result.report` is the same immutable evidence stored on `diorama.report`.
The report stores structured `finalization` facts (diagnostics, usage, cleanup)
and a safe `publication` summary. It does not retain either definition, the
body value/error, or arbitrary load/publication errors. Text is generated only
by `rendered()`. Select verification conditions explicitly:

```swift
let result = try await diorama.execute { _, dependency in
    try await exercise(dependency)
}
let evaluation = result.report.evaluated(.allRecordsClaimed)
let cleanup = result.report.finalization.cleanup
let publication = result.report.publication
```

After a body error, inspect the same report API while preserving that error:

```swift
do {
    _ = try await diorama.execute { _, dependency in
        try await exercise(dependency)
    }
} catch {
    if let report = diorama.report {
        let evaluation = report.evaluated(.allRecordsClaimed)
        inspect(evaluation, report.publication)
    }
    throw error
}
```

Here `exercise` and `inspect` represent application-owned functions. Evaluation
returns facts without failing a test automatically. Publication problems remain
separate from the selected Core conditions. Startup failure leaves `report` nil
and carries its own evidence in the startup error. Copy the report before the
next admitted execution clears the setup's property; copied reports stay frozen.

Migration: use `result.report.finalization` for the former consumer
`result.finalization`, `report.finalization.report.diagnostics` for formerly
flat diagnostics, and `report.publication` for formerly flat publication fields.
Core's lower-level `ScenarioFinalizationResult` accessors remain available.

## Location manager migration

On Apple platforms, `swift build --package-path Examples` also compiles
[LocationConsumer](Sources/LocationMigration/LocationConsumer.swift). It shows
application code receiving a `DioramaLocationManager`, keeping its delegate alive,
configuring standard updates, and handling native locations and nonterminal errors.
The delegate uses native `CLLocation` and reads already installed current state.

G07 supplies the manager/delegate surface over controlled replay. The example
accepts an injected manager; native manager construction and the live attachment
integration belong to G08. It does not create a live Core Location manager.
The compile-only migration target is absent from the Linux example graph.
