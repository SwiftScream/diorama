import DioramaCore

/// Setup and persistence capability for Apple-only standard location updates.
public enum DioramaLocationSystem {
    /// The first-party Location type and its versioned persistence capability.
    public static let type = LocationTracks.type

    /// Creates an independent, privately owned main-actor location manager.
    /// Recording delivers normalized native values; passthrough preserves identity.
    /// All modes stop at finish and retained facades become frozen and inert.
    public static func instance(
        named name: String, recording: LocationRecordingOptions = .init(), fidelity: LocationFidelityOptions = .init(),
        allowsUnclaimedReplayRecords: Bool = false) throws -> ScenarioSystem<DioramaLocationManager>
    {
        try ScenarioSystem(named: name, definition: LocationDefinition(
            fidelity: fidelity, format: recording.format, policy: recording.policy),
        allowsUnclaimedReplayRecords: allowsUnclaimedReplayRecords)
    }
}

struct LocationDefinition: SystemDefinition {
    let systemType = LocationTracks.type
    let sessions: TrackDefinition<LocationSession, LocationTracks.SessionHeader>
    let access: TrackDefinition<LocationTracks.AccessSegment, LocationRecordedAccessState>
    let fidelity: LocationFidelityOptions
    let format: LocationCoordinateFormat
    let policy: LocationOriginPolicy
    let driverFactory: @MainActor @Sendable () -> any LocationNativeDriver

    init(fidelity: LocationFidelityOptions = .init(), format: LocationCoordinateFormat = .meters,
         policy: LocationOriginPolicy = .init(),
         driverFactory: @escaping @MainActor @Sendable () -> any LocationNativeDriver = { CoreLocationDriver() }) throws
    {
        self.fidelity = fidelity
        self.format = format
        self.policy = policy
        self.driverFactory = driverFactory
        sessions = try LocationTracks.sessionDefinition(header: .init(
            coordinateSpace: nil, altitudeOrigin: nil, initial: nil))
        access = try TrackDefinition("access", header: ValuePreparation().admitPrepared(
            LocationRecordedAccessState(servicesEnabled: false, permission: .notDetermined, accuracy: .full)),
        values: [ValuePreparation().admitPrepared(LocationTracks.AccessSegment.initial([]))])
    }

    var tracks: [AnyTrackDefinition] {
        [sessions.erased, access.erased]
    }

    func validate(in context: borrowing SystemValidationContext) throws {
        guard context.mode != .passthrough else { return }
        try context.validate(sessions) { sessions in
            let access = try context.track(access)
            // Diorama resolves fresh setup to a recordless layout. The native
            // bridge captures the required initial access segment at activation.
            // This exception is not a valid persisted or replay recording.
            if context.mode == .record, sessions.records.isEmpty, access.records.isEmpty,
               sessions.header == LocationTracks.SessionHeader(
                   coordinateSpace: nil, altitudeOrigin: nil, initial: nil)
            {
                return
            }
            _ = try LocationTracks.recording(in: ScenarioAttachment(id: context.attachmentID)
                .adding(sessions).adding(access))
        }
    }

    var record: SystemModeDefinition<LocationCaptureState, DioramaLocationManager> {
        .init(makeState: { context in
            try LocationCaptureState(sessions: context.lease(for: sessions), access: context.lease(for: access))
        }, makeDependency: { @MainActor execution in
            let context = try execution.state.withLock { state, _ in
                DiagnosticContext.attachment(state.sessions.id.attachmentID)
            }
            // All fallible lease lookup precedes native construction. Initialization
            // contains conversion failures and starts no updates before returning.
            let bridge = LocationNativeBridge(driver: driverFactory(), recording: .init(
                execution: execution, preparation: .init(format: format, policy: policy)),
            reporter: execution.reporter, context: context, fidelity: fidelity)
            return DioramaLocationManager(backend: bridge, reporter: execution.reporter, context: context)
        }, requestStop: { _, manager in await manager?.close() })
    }

    var replay: SystemModeDefinition<LocationReplayState, DioramaLocationManager> {
        .init(makeState: { context in
            try LocationReplayState(sessions: context.lease(for: sessions), access: context.lease(for: access))
        }, makeDependency: { @MainActor execution in
            try DioramaLocationManager(execution: execution, fidelity: fidelity)
        }, requestStop: { _, manager in await manager?.close() })
    }

    var passthrough: SystemModeDefinition<DiagnosticContext, DioramaLocationManager> {
        .init(makeState: { .attachment($0.attachmentID) }, makeDependency: { @MainActor execution in
            let context = try execution.state.withLock { state, _ in state }
            let bridge = LocationNativeBridge(driver: driverFactory(), recording: nil,
                                              reporter: execution.reporter, context: context, fidelity: fidelity)
            return DioramaLocationManager(backend: bridge, reporter: execution.reporter, context: context)
        }, requestStop: { _, manager in await manager?.close() })
    }
}
