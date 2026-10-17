/// Supplemental native fields to preserve when materializing recorded locations.
///
/// Record and replay use the same options. Capture always retains both fields,
/// regardless of these settings. Passthrough forwards the original native value.
public struct LocationFidelityOptions: Equatable, Sendable {
    /// Whether to preserve a recorded logical floor through a native subclass.
    public let preserveFloor: Bool
    /// Whether to preserve ellipsoidal altitude through a native subclass.
    public let preserveEllipsoidalAltitude: Bool

    /// Selects optional fidelity that requires subclassing Core Location values.
    ///
    /// Both options default off. These opt-ins accept Apple's guidance against
    /// subclassing CLLocation and CLFloor; arbitrary framework compatibility is
    /// not guaranteed. Copies preserve enabled fields, but native secure archives
    /// lose them and produce a Diorama diagnostic.
    public init(preserveFloor: Bool = false, preserveEllipsoidalAltitude: Bool = false) {
        self.preserveFloor = preserveFloor
        self.preserveEllipsoidalAltitude = preserveEllipsoidalAltitude
    }
}
