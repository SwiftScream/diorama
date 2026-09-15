/// A typed lookup key for one dependency in a scenario execution.
///
/// The complete attachment identity prevents an attachment key shared by two
/// system types from selecting the wrong system. The generic parameter binds
/// lookup to the dependency type produced by that system's registration.
public struct DependencyKey<Dependency: Sendable>: Hashable, Sendable {
    /// The complete identity of the attachment that produces the dependency.
    public let attachmentID: AttachmentID

    /// Creates a typed dependency key for an attachment.
    ///
    /// Prefer the key exposed by ``ScenarioSystem/dependencyKey``. This
    /// initializer supports independently retained keys and makes an
    /// incompatible type request a diagnosed runtime failure.
    ///
    /// - Parameter attachmentID: The exact attachment to look up.
    public init(attachmentID: AttachmentID) {
        self.attachmentID = attachmentID
    }
}
