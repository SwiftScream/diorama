import DioramaCore

/// Test systems explicitly select an unchanged-value policy for safe fixtures.
func preparedValues<Value: Sendable>(_ values: [Value]) throws -> [PreparedValue<Value>] {
    let reporter = try DiagnosticReporter(definition: ScenarioDefinition(
        id: ScenarioID(rawValue: "fixtures"),
        defaultMode: .replay))
    let preparation = ValuePreparation<Value>()
    return try values.map { value in
        try preparation.prepare(capturing: { value }, purpose: .replay, reporter: reporter)
    }
}
