/// One effective stable value and whether it was authored for playback.
///
/// Systems use this only for fields that support authored overrides. A
/// persisted editing form may temporarily contain both an observation and an
/// override; its reader resolves that form before constructing this value.
public enum OverridableValue<Value: Sendable>: Sendable {
    /// A captured or otherwise ordinary observation.
    case observed(Value)
    /// A deliberate playback value retained according to the owning system's
    /// re-recording policy.
    case override(Value)

    /// The sole effective value after edited input has been normalized.
    public var value: Value {
        switch self {
        case let .observed(value), let .override(value): value
        }
    }

    /// Whether this value was deliberately authored for playback.
    public var isOverride: Bool {
        if case .override = self {
            true
        } else {
            false
        }
    }

    /// Transforms the effective value without changing its authorship.
    public func map<NewValue: Sendable>(
        _ transform: (Value) throws -> NewValue) rethrows -> OverridableValue<NewValue>
    {
        switch self {
        case let .observed(value): try .observed(transform(value))
        case let .override(value): try .override(transform(value))
        }
    }
}

extension OverridableValue: Equatable where Value: Equatable {}
