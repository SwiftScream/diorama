/// Safe structural failures for Diorama's private persisted schema.
///
/// Coding paths and field names are schema-authored. Payload values and
/// arbitrary decoder descriptions are deliberately excluded.
public enum PersistedScenarioCodingError: Error, Equatable, Sendable {
    /// No explicit Diorama envelope version can be selected.
    case unversionedEnvelope

    /// The envelope declares a version this schema does not read.
    case unsupportedEnvelopeVersion(declared: UInt32, supported: [UInt32])

    /// A strict Diorama-owned structure contains an unrecognized field.
    case unknownField(codingPath: [String], field: String)

    /// Required structure or a scalar has the wrong encoded representation.
    case malformed(codingPath: [String])
}
