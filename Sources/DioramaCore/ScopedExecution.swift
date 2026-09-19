public extension ScenarioDefinition {
    /// Runs a body with dependencies from a statically typed system list and
    /// always finalizes the fresh execution afterward.
    ///
    /// Dependencies are passed to `body` in registration argument order while
    /// preparation, activation, and cleanup retain definition order. A thrown
    /// body error is returned alongside finalization instead of replacing it.
    /// Startup failure still throws because no execution exists to finalize.
    ///
    /// - Parameters:
    ///   - configuration: Runtime identity, modes, and verification policy.
    ///   - systems: Exactly one reusable system for every declared attachment.
    ///   - sink: Optional diagnostic notification for this execution.
    ///   - body: Work receiving each activated dependency in argument order.
    ///     Its inferred actor isolation is carried through the scoped call.
    /// - Returns: Both the body outcome and immutable finalization result.
    /// - Throws: ``ScenarioStartupFailure`` when startup cannot produce a run.
    /// Keep the explicit isolation on this parameter-pack closure. It preserves
    /// caller actor isolation and avoids swiftlang/swift#91831.
    func execute<each Dependency: Sendable, Success: Sendable, Failure: Error>(
        configuration: ScenarioConfiguration,
        with systems: repeat ScenarioSystem<each Dependency>,
        sink: DiagnosticSink? = nil,
        _ body: @isolated(any) (repeat each Dependency) async throws(Failure) -> Success)
        async throws(ScenarioStartupFailure) -> ScopedExecutionResult<Success, Failure>
    {
        var registrations: [AnyScenarioSystem] = []
        for system in repeat each systems {
            registrations.append(AnyScenarioSystem(system))
        }
        let execution = try ScenarioExecution.start(
            definition: self,
            configuration: configuration,
            systems: registrations,
            sink: sink)
        let dependencies = (repeat execution.requiredDependency(for: each systems))
        return await execution.runScoped { () async throws(Failure) -> Success in
            try await body(repeat each dependencies)
        }
    }

    /// Runs a body with direct access to a fresh execution and always finalizes
    /// it afterward.
    ///
    /// Use this overload for dynamically assembled registrations or execution-
    /// level access. Prefer the variadic overload when systems are statically
    /// known so the body receives their dependencies directly.
    ///
    /// - Parameters:
    ///   - configuration: Runtime identity, modes, and verification policy.
    ///   - systems: Exactly one erased registration per declared attachment.
    ///   - sink: Optional diagnostic notification for this execution.
    ///   - body: Work receiving the fully activated execution.
    /// - Returns: Both the body outcome and immutable finalization result.
    /// - Throws: ``ScenarioStartupFailure`` when startup cannot produce a run.
    func execute<Success: Sendable, Failure: Error>(
        configuration: ScenarioConfiguration,
        with systems: [AnyScenarioSystem],
        sink: DiagnosticSink? = nil,
        _ body: (ScenarioExecution) async throws(Failure) -> Success)
        async throws(ScenarioStartupFailure) -> ScopedExecutionResult<Success, Failure>
    {
        let execution = try ScenarioExecution.start(
            definition: self,
            configuration: configuration,
            systems: systems,
            sink: sink)
        return await execution.runScoped {
            () async throws(Failure) -> Success in
            try await body(execution)
        }
    }
}

private extension ScenarioExecution {
    func runScoped<Success: Sendable, Failure: Error>(
        _ body: () async throws(Failure) -> Success) async -> ScopedExecutionResult<Success, Failure>
    {
        let bodyResult: Result<Success, Failure>
        do {
            bodyResult = try await .success(body())
        } catch {
            bodyResult = .failure(error)
        }

        let finalization = await finish()
        return ScopedExecutionResult(body: bodyResult, finalization: finalization)
    }
}
