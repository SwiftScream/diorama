/// Immutable execution policy, independent of recorded scenario content.
///
/// Systems and their preparation factories remain separate runtime declarations.
/// This value contains no baseline, dependency, replay cursor, or live resource.
public struct ScenarioConfiguration: Sendable {
    /// The diagnostic identity of each execution using this configuration.
    public let id: ScenarioID

    /// The mode inherited by attachments without an override.
    public let defaultMode: ScenarioMode

    /// Whole-attachment mode overrides indexed by caller-selected key.
    public let modeOverrides: [AttachmentKey: ScenarioMode]

    /// Active keys exempt only from unused-recording verification.
    public let ignoredAttachments: Set<AttachmentKey>

    /// Creates reusable execution policy. Startup validates all policy keys
    /// against the active attachment layout before calling any system.
    ///
    /// - Parameters:
    ///   - id: Diagnostic scenario identity, never persisted with recordings.
    ///   - defaultMode: The inherited attachment mode.
    ///   - modeOverrides: Overrides for complete active attachments.
    ///   - ignoredAttachments: Active keys exempt from usage verification.
    public init(id: ScenarioID, defaultMode: ScenarioMode,
                modeOverrides: [AttachmentKey: ScenarioMode] = [:],
                ignoredAttachments: Set<AttachmentKey> = [])
    {
        self.id = id
        self.defaultMode = defaultMode
        self.modeOverrides = modeOverrides
        self.ignoredAttachments = ignoredAttachments
    }

    /// Resolves policy for an attachment key. Startup separately checks that
    /// the key belongs to the active layout.
    ///
    /// - Parameter key: The attachment key whose mode is required.
    /// - Returns: Its configured override or the default mode.
    public func effectiveMode(for key: AttachmentKey) -> ScenarioMode {
        modeOverrides[key] ?? defaultMode
    }

    /// Validates policy membership without accessing recorded values.
    ///
    /// - Parameter definition: The active attachment layout for this execution.
    /// - Throws: The first unknown policy key, in deterministic lexical order.
    public func validate(against definition: ScenarioDefinition) throws(ScenarioConfigurationError) {
        let keys = Set(definition.attachments.map(\.id.key))
        for key in ignoredAttachments.sorted(by: { $0.rawValue < $1.rawValue }) where !keys.contains(key) {
            throw .unknownIgnoredAttachment(key)
        }
        for key in modeOverrides.keys.sorted(by: { $0.rawValue < $1.rawValue }) where !keys.contains(key) {
            throw .unknownModeOverride(key)
        }
    }
}

/// Invalid execution policy detected before any system preparation or activation.
public enum ScenarioConfigurationError: Error, Equatable, Sendable {
    /// An ignored key does not identify an active attachment.
    case unknownIgnoredAttachment(AttachmentKey)

    /// A mode override does not identify an active attachment.
    case unknownModeOverride(AttachmentKey)
}
