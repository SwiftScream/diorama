/// Whether quiet state or native access entered the published execution lifetime.
public enum SystemStateAccessResult<Value> {
    /// Admission was closed; no operation or late-call diagnostic was produced.
    case ignored
    /// The admitted operation returned this value.
    case performed(Value)
}

extension SystemStateAccessResult: Sendable where Value: Sendable {}

/// Retainable access to one execution's state. Retention never extends admission.
/// Locked bodies cannot suspend, reenter, invoke arbitrary callbacks, or launch
/// untracked work. Native actors retain their own isolation requirements.
public struct SystemStateAccess<State: Sendable>: Sendable {
    let execution: SystemExecution<State>

    /// Serializes mutation and scoped Core effects, committing even on a throw.
    public func withLock<Result>(
        _ body: (inout State, inout SystemOperation<State>) throws -> Result) throws -> Result
    {
        try execution.withState(body)
    }

    /// Quiet callback mutation, ignored before publication and after closure.
    public func withLockIfOpen<Result>(
        _ body: (inout State, inout SystemOperation<State>) throws -> Result) throws -> SystemStateAccessResult<Result>
    {
        guard try execution.enter(quiet: true) else { return .ignored }
        defer { execution.leave() }
        return try .performed(execution.mutate(body))
    }

    /// Admits before selecting a member under protection, then invokes the body
    /// outside protection. The entire scope is joined by finalization.
    public func withTrackedValue<Value: Sendable, Result>(
        _ keyPath: KeyPath<State, Value>, _ body: (Value) throws -> Result) throws -> Result
    {
        _ = try execution.enter(quiet: false)
        defer { execution.leave() }
        let value = try execution.protected { $0[keyPath: keyPath] }
        return try body(value)
    }

    /// Tracks selection, suspension, actor hops, and throwing exits as one scope.
    /// Copied references and unstructured tasks require explicit author ownership.
    public func withTrackedValue<Value: Sendable, Result: Sendable>(
        _ keyPath: KeyPath<State, Value> & Sendable,
        _ body: @isolated(any) @Sendable (Value) async throws -> Result) async throws -> Result
    {
        _ = try execution.enter(quiet: false)
        defer { execution.leave() }
        let value = try execution.protected { $0[keyPath: keyPath] }
        return try await body(value)
    }

    /// Quiet synchronous native entry with one ignored/performed disposition.
    public func withTrackedValueIfOpen<Value: Sendable, Result>(
        _ keyPath: KeyPath<State, Value>, _ body: (Value) throws -> Result) throws -> SystemStateAccessResult<Result>
    {
        guard try execution.enter(quiet: true) else { return .ignored }
        defer { execution.leave() }
        let value = try execution.protected { $0[keyPath: keyPath] }
        return try .performed(body(value))
    }

    /// Quiet asynchronous native entry. An admitted scope cannot reopen closed state.
    public func withTrackedValueIfOpen<Value: Sendable, Result: Sendable>(
        _ keyPath: KeyPath<State, Value> & Sendable,
        _ body: @isolated(any) @Sendable (Value) async throws -> Result) async throws -> SystemStateAccessResult<Result>
    {
        guard try execution.enter(quiet: true) else { return .ignored }
        defer { execution.leave() }
        let value = try execution.protected { $0[keyPath: keyPath] }
        return try await .performed(body(value))
    }
}
