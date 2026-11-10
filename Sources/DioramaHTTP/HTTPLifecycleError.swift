/// Safe structural validation failures without request, body, or failure values.
public enum HTTPLifecycleError: Error, Equatable, Sendable {
    /// A local delay cannot run backward.
    case negativeDelay
    /// Cumulative local timing exceeds the Int64 millisecond scalar range.
    case delayOverflow
    /// A segment's observed byte count cannot be negative.
    case negativeByteWeight
    /// Cumulative original byte weights exceed Int64.
    case byteWeightOverflow
    /// An explicit delivery profile must contain at least one segment.
    case emptyBodyProfile
    /// Allocation requires a nonnegative effective body length.
    case negativeBodyLength
    /// Absent or unavailable content cannot own a segment profile.
    case bodyProfileWithoutBytes
}
