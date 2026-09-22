import DioramaCore

/// Safe failures while converting a semantic attachment to a system payload.
public enum PersistentSystemEncodingError: Error, Equatable, Sendable {
    /// The attachment does not contain the tracks required by its system writer.
    case invalidTrackLayout(AttachmentID)
}
