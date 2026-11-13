import CoreLocation
import Diorama
@testable import DioramaCore
@testable import DioramaLocation
import DioramaPersistence
import Foundation
import Testing

@MainActor
private final class ControlledLocationDriver: LocationNativeDriver {
    var location: CLLocation?
    var access = LocationAccessState(servicesEnabled: true, permission: .notDetermined, accuracy: .fullAccuracy)
    weak var bridge: LocationNativeBridge?
    var starts = 0
    var stops = 0
    var connections = 0
    var requests: [LocationAuthorizationRequest] = []
    var authorizationOnRequest: LocationAccessState?
    var configuration = DioramaLocationManager.Configuration()

    func connect(_ bridge: LocationNativeBridge?) {
        self.bridge = bridge; connections += 1
    }

    func configure(_ configuration: DioramaLocationManager.Configuration) {
        self.configuration = configuration
    }

    func start() {
        starts += 1
    }

    func stop() {
        stops += 1
    }

    func request(_ request: LocationAuthorizationRequest) {
        requests.append(request)
        if let authorizationOnRequest {
            access = authorizationOnRequest
            bridge?.receiveAuthorization()
        }
    }
}

@MainActor
private final class NativeJournal: DioramaLocationManagerDelegate {
    var batches: [[CLLocation]] = []
    var errors: [NSError] = []
    var states: [CLAuthorizationStatus] = []
    let signal = AsyncStream<Void>.makeStream()
    let accessSignal = AsyncStream<CLAuthorizationStatus>.makeStream()
    let errorSignal = AsyncStream<Void>.makeStream()

    func locationManager(_ manager: DioramaLocationManager, didUpdateLocations locations: [CLLocation]) {
        if let last = locations.last {
            #expect(manager.location === last)
        }
        batches.append(locations)
        signal.continuation.yield(())
    }

    func locationManager(_: DioramaLocationManager, didFailWithError error: Error) {
        errors.append(error as NSError)
        errorSignal.continuation.yield(())
    }

    func locationManagerDidChangeAuthorization(_ manager: DioramaLocationManager) {
        states.append(manager.authorizationStatus)
        accessSignal.continuation.yield(manager.authorizationStatus)
    }
}

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct LocationNativeBridgeTests {
    @Test(arguments: [false, true], [false, true])
    func `mixed consumer recording omits only location passthrough without a baseline`(
        fileBacked: Bool, hasPassthroughBaseline: Bool) async throws
    {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("mixed.json")
        let recordingDriver = ControlledLocationDriver()
        let liveDriver = ControlledLocationDriver()
        let record = try ScenarioSystem(named: "gps", definition: LocationDefinition(
            driverFactory: { recordingDriver })).withMode(.record)
        let live = try ScenarioSystem(named: "live", definition: LocationDefinition(driverFactory: { liveDriver }))
        let original = try LocationOriginFixtures.authored()
        let baseline = try ScenarioDefinition(attachments: hasPassthroughBaseline ? [
            LocationTracks.attachment(named: "live", recording: original),
        ] : [])
        let codec = try LocationOriginFixtures.codec()
        if fileBacked, hasPassthroughBaseline {
            try codec.encode(baseline).data.write(to: file)
        }
        let setup = try fileBacked
            ? Diorama(file: file, scenarioID: "mixed", mode: .passthrough, systems: live, record)
            : Diorama(definition: baseline, scenarioID: "mixed", mode: .passthrough, systems: live, record)
        let livePoint = point(40)
        let result = try await setup.execute { _, live, record in
            live.startUpdatingLocation()
            liveDriver.bridge?.receive([livePoint])
            #expect(live.location === livePoint)
            record.startUpdatingLocation()
            recordingDriver.bridge?.receive([point()])
            record.stopUpdatingLocation()
        }
        let definition = try #require(result.definition)
        let expected = hasPassthroughBaseline ? [live.attachment.id, record.attachment.id] : [record.attachment.id]
        #expect(definition.attachments.map(\.id) == expected)
        if hasPassthroughBaseline {
            #expect(try LocationOriginFixtures.content(definition, named: "live") == original)
        }
        #expect(result.report.evaluated(.noDiagnostics).isSatisfied)
        #expect(result.report.finalization.usage.map(\.attachmentID) == [live.attachment.id, record.attachment.id])
        #expect(result.report.finalization.cleanup.map(\.disposition) == [.completed, .completed])
        #expect(result.report.publication.candidate.attachmentCount == expected.count)
        #expect(result.report.publication.candidate.trackCount == expected.count * 2)
        #expect(result.report.publication.disposition == (fileBacked ? .published : .notRequested))
        #expect(liveDriver.bridge == nil)
        #expect(recordingDriver.bridge == nil)
        let bytes = try codec.encode(definition).data
        #expect(try codec.encode(codec.decode(bytes)).data == bytes)
        if fileBacked {
            #expect(try Data(contentsOf: file) == bytes)
            try await replayMixedRecording(in: file, live: live, record: record)
            #expect(recordingDriver.connections == 2)
        }
    }

    private func replayMixedRecording(in file: URL, live: ScenarioSystem<DioramaLocationManager>,
                                      record: ScenarioSystem<DioramaLocationManager>) async throws
    {
        let bytes = try Data(contentsOf: file)
        let replay = try await Diorama(file: file, scenarioID: "replay", mode: .passthrough,
                                       systems: live, record.withMode(.replay))
            .execute { _, _, record in
                let journal = NativeJournal()
                record.delegate = journal
                record.startUpdatingLocation()
                var iterator = journal.signal.stream.makeAsyncIterator()
                _ = await iterator.next()
                record.stopUpdatingLocation()
            }
        #expect(replay.report.evaluated(.noDiagnostics).isSatisfied)
        #expect(replay.report.evaluated(.allRecordsClaimed).isSatisfied)
        #expect(replay.report.evaluated(.allClaimedRecordsConsumed).isSatisfied)
        #expect(replay.report.publication.disposition == .notRequested)
        #expect(try Data(contentsOf: file) == bytes)
    }

    @Test(arguments: [false, true])
    func `fresh consumer recording publishes and replays without a baseline`(fileBacked: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("location.json")
        let driver = ControlledLocationDriver()
        let system = try ScenarioSystem(named: "gps", definition: LocationDefinition(driverFactory: { driver }))
        let setup = try fileBacked
            ? Diorama(file: file, scenarioID: "fresh", mode: .record, systems: system)
            : Diorama(scenarioID: "fresh", mode: .record, systems: system)
        let journal = NativeJournal()
        let recorded = try await setup.execute { _, manager in
            manager.delegate = journal
            manager.startUpdatingLocation()
            driver.bridge?.receive([point()])
            manager.stopUpdatingLocation()
        }
        let definition = try #require(recorded.definition)
        let content = try LocationOriginFixtures.content(definition)
        #expect(content.sessions.count == 1)
        #expect(content.sessions[0].events.count == 1)
        #expect(content.access.requests.isEmpty)
        #expect(recorded.report.evaluated(.noDiagnostics).isSatisfied)
        #expect(driver.starts == 1)
        #expect(driver.bridge == nil)
        let bytes = fileBacked ? try Data(contentsOf: file) : nil
        #expect(recorded.report.publication.disposition == (fileBacked ? .published : .notRequested))
        let replaySetup = try fileBacked
            ? Diorama(file: file, scenarioID: "replay", mode: .replay, systems: system)
            : Diorama(definition: definition, scenarioID: "replay", mode: .replay, systems: system)
        let replayJournal = NativeJournal()
        let replay = try await replaySetup.execute { _, manager in
            manager.delegate = replayJournal
            manager.startUpdatingLocation()
            var iterator = replayJournal.signal.stream.makeAsyncIterator()
            _ = await iterator.next()
            manager.stopUpdatingLocation()
        }
        let original = try #require(journal.batches.first?.first)
        let replayed = try #require(replayJournal.batches.first?.first)
        #expect(replayed.coordinate.latitude == original.coordinate.latitude)
        #expect(replayed.coordinate.longitude == original.coordinate.longitude)
        #expect(replayed.timestamp == original.timestamp)
        #expect(replay.report.evaluated(.noDiagnostics).isSatisfied)
        #expect(replay.report.evaluated(.allRecordsClaimed).isSatisfied)
        #expect(replay.report.evaluated(.allClaimedRecordsConsumed).isSatisfied)
        #expect(replay.report.publication.disposition == .notRequested)
        #expect(driver.connections == 2) // One record connection and its shutdown; replay constructs no driver.
        if fileBacked {
            #expect(try Data(contentsOf: file) == bytes)
        }
    }

    @Test
    func `replay rejects a recordless setup before constructing a native driver`() async throws {
        let driver = ControlledLocationDriver()
        let system = try ScenarioSystem(named: "gps", definition: LocationDefinition(driverFactory: { driver }))
        let empty = try ScenarioDefinition(attachments: [system.attachment]).removingRecords()
        let setup = try Diorama(definition: empty, scenarioID: "invalid", mode: .replay, systems: system)
        await #expect(throws: ScenarioStartupFailure.self) {
            try await setup.execute { _, _ in Issue.record("Invalid replay must not start") }
        }
        #expect(driver.connections == 0)
    }

    @Test(arguments: [ScenarioMode.record, .replay])
    func `sessions without an initial access segment remain invalid`(mode: ScenarioMode) async throws {
        let driver = ControlledLocationDriver()
        let system = try ScenarioSystem(named: "gps", definition: LocationDefinition(driverFactory: { driver }))
        let sessions = try SequentialTrack(
            id: system.attachment.trackIDs[0],
            header: ValuePreparation().admitPrepared(LocationTracks.SessionHeader(
                coordinateSpace: nil, altitudeOrigin: nil, initial: nil)),
            values: [ValuePreparation().admitPrepared(LocationSession(timestampOrigin: nil, events: []))])
        let access = try SequentialTrack<LocationTracks.AccessSegment, LocationRecordedAccessState>(
            id: system.attachment.trackIDs[1],
            header: ValuePreparation().admitPrepared(LocationAccessReplayFixtures.initial), values: [])
        let baseline = try ScenarioDefinition(attachments: [
            ScenarioAttachment(id: system.attachment.id).adding(sessions).adding(access),
        ])
        let setup = try Diorama(definition: baseline, scenarioID: "invalid", mode: mode, systems: system)
        await #expect(throws: ScenarioStartupFailure.self) {
            try await setup.execute { _, _ in Issue.record("Invalid baseline must not start") }
        }
        #expect(driver.connections == 0)
    }

    private func point(_ latitude: Double = 12.123456789) -> CLLocation {
        CLLocation(coordinate: .init(latitude: latitude, longitude: 30), altitude: 10.12345,
                   horizontalAccuracy: 2.12345, verticalAccuracy: 1.23456,
                   course: 45.12345, courseAccuracy: 2, speed: 3.12345, speedAccuracy: 0.5,
                   timestamp: Date(timeIntervalSince1970: 1_900_000_000.12345))
    }

    private func start(_ driver: ControlledLocationDriver, mode: ScenarioMode = .record,
                       policy: LocationOriginPolicy = .init(), baseline: ScenarioDefinition? = nil,
                       fidelity: LocationFidelityOptions = .init(),
                       clock: ExecutionClock = .continuous()) async throws
        -> (ScenarioExecution, DioramaLocationManager)
    {
        let system = try ScenarioSystem(named: "gps", definition: LocationDefinition(
            fidelity: fidelity, format: .degrees, policy: policy, driverFactory: { driver }))
        let execution = try await ScenarioExecution.start(
            definition: baseline ?? ScenarioDefinition(attachments: [system.attachment]),
            scenarioID: .init(rawValue: "native"), defaultMode: mode,
            systems: [AnyScenarioSystem(system)], clock: clock)
        return try (execution, execution.dependency(system))
    }

    @Test(arguments: [false, true], [false, true])
    func `recording normalizes batches cached state and errors and replay never constructs a driver`(
        floor: Bool, ellipsoidal: Bool) async throws
    {
        let driver = ControlledLocationDriver()
        let original = point()
        driver.location = original
        let (execution, manager) = try await start(driver, fidelity: .init(
            preserveFloor: floor, preserveEllipsoidalAltitude: ellipsoidal))
        #expect(manager.location !== original)
        #expect(manager.location?.horizontalAccuracy == 2.123)
        let journal = NativeJournal()
        manager.delegate = journal
        manager.desiredAccuracy = 7
        manager.distanceFilter = 8
        manager.activityType = .fitness
        manager.pausesLocationUpdatesAutomatically = false
        #expect(driver.configuration.accuracy == 7)
        #expect(driver.configuration.filter == 8)
        #expect(driver.configuration.activity == .fitness)
        #expect(driver.configuration.pauses == false)
        manager.startUpdatingLocation()
        manager.startUpdatingLocation()
        driver.bridge?.receive([original, point(12.5)])
        driver.bridge?.receive([])
        driver.bridge?.receive(NSError(domain: "native.test", code: 42, userInfo: ["safe": 3, "omit": NSObject()]))
        manager.requestWhenInUseAuthorization()
        driver.access = .init(servicesEnabled: false, permission: .denied, accuracy: .reducedAccuracy)
        driver.bridge?.receiveAuthorization()
        #expect(journal.states == [.denied])
        #expect(journal.errors.first?.code == 42)
        #expect(journal.errors.first?.userInfo["omit"] == nil)
        #expect(journal.batches.count == 2)
        #expect(journal.batches[0][0] !== original)
        #expect(driver.starts == 1)
        let result = await execution.finish()
        let definition = try #require(result.definition)
        let recording = try LocationOriginFixtures.content(definition)
        #expect(recording.sessions.count == 1)
        #expect(recording.access.requests.map(\.request) == [.whenInUse])
        #expect(recording.sessions[0].events.count == 3)
        #expect(result.report.diagnostics.count == 1)
        verifyOmission(result)
        #expect(driver.bridge == nil)
        #expect(driver.stops == 1)
        manager.startUpdatingLocation()
        manager.requestAlwaysAuthorization()
        manager.stopUpdatingLocation()
        #expect(driver.starts == 1)
        #expect(driver.requests == [.whenInUse])
        try await verifyReplay(definition, recorded: journal.batches[0][0],
                               fidelity: .init(preserveFloor: floor, preserveEllipsoidalAltitude: ellipsoidal))
    }

    private func verifyOmission(_ result: ScenarioFinalizationResult) {
        guard case let .nativeErrorMetadataOmitted(key, runtimeType) =
            result.report.diagnostics[0].diagnostic.issue
        else {
            Issue.record("Expected an omission fact"); return
        }
        #expect(key == "omit")
        #expect(runtimeType.contains("NSObject"))
        #expect(result.rendered().contains("native-error-metadata-omitted key=\"omit\""))
        #expect(result.evaluate(.noUnexpectedOperations).isSatisfied)
    }

    private func verifyReplay(_ definition: ScenarioDefinition, recorded: CLLocation,
                              fidelity: LocationFidelityOptions) async throws
    {
        let replayDriver = ControlledLocationDriver()
        let (replay, replayManager) = try await start(replayDriver, mode: .replay, baseline: definition,
                                                      fidelity: fidelity)
        let replayJournal = NativeJournal()
        replayManager.delegate = replayJournal
        replayManager.startUpdatingLocation()
        var iterator = replayJournal.signal.stream.makeAsyncIterator()
        _ = await iterator.next()
        let replayed = try #require(replayJournal.batches.first?.first)
        #expect(replayed.coordinate.latitude == recorded.coordinate.latitude)
        #expect(replayed.timestamp == recorded.timestamp)
        #expect(replayed.altitude == recorded.altitude)
        #expect(replayed.speed == recorded.speed)
        #expect(replayed.ellipsoidalAltitude == recorded.ellipsoidalAltitude)
        #expect(replayDriver.connections == 0)
        _ = await replay.finish()
    }

    @Test(arguments: [false, true], [false, true])
    func `capture retains supplemental fields independently of native fidelity`(floor: Bool, ellipsoidal: Bool)
        async throws
    {
        let reporter = try DiagnosticReporter(scenarioID: .init(rawValue: "fixture"),
                                              definition: ScenarioDefinition(attachments: []))
        let measurement = try #require(LocationMeasurement(
            coordinate: .init(latitude: 12, longitude: 30), horizontalAccuracyMeters: 1,
            vertical: LocationVerticalEstimate(orthometricAltitudeMeters: 10,
                                               ellipsoidalAltitudeMeters: 25, accuracyMeters: 1),
            floorLevel: 3, timestamp: point().timestamp,
            sourceInformation: .init(simulatedBySoftware: true, producedByAccessory: false)))
        let native = LocationNativeMaterializer(
            fidelity: .init(preserveFloor: true, preserveEllipsoidalAltitude: true),
            reporter: reporter, context: .scenario).materialize(measurement)
        let driver = ControlledLocationDriver()
        driver.location = native
        let (execution, manager) = try await start(driver, fidelity: .init(
            preserveFloor: floor, preserveEllipsoidalAltitude: ellipsoidal))
        manager.startUpdatingLocation()
        driver.bridge?.receive([native])
        #expect(manager.location?.floor?.level == (floor ? 3 : nil))
        if ellipsoidal {
            #expect(manager.location?.ellipsoidalAltitude == 25)
        }
        #expect(manager.location?.sourceInformation?.isSimulatedBySoftware == true)
        let result = await execution.finish()
        let content = try LocationOriginFixtures.content(#require(result.definition))
        #expect(content.initial?.location.floor?.level == 3)
        #expect(content.altitudeOrigin?.ellipsoidalMeters.value == 25)
        guard case let .batch(_, points) = content.sessions[0].events[0] else {
            Issue.record("Expected a batch"); return
        }
        #expect(points[0].floor?.level == 3)
        #expect(points[0].altitudeOffset?.ellipsoidalMeters == 0)
        #expect(result.report.diagnostics.isEmpty)
    }

    @Test
    func `passthrough preserves original identity and creates no recording`() async throws {
        let driver = ControlledLocationDriver()
        let original = point()
        driver.location = original
        let (execution, manager) = try await start(driver, mode: .passthrough)
        #expect(manager.location === original)
        let journal = NativeJournal()
        manager.delegate = journal
        manager.startUpdatingLocation()
        driver.bridge?.receive([original])
        let error = NSError(domain: "pass", code: 1, userInfo: ["opaque": NSObject()])
        driver.bridge?.receive(error)
        #expect(journal.batches[0][0] === original)
        #expect(journal.errors[0] === error)
        manager.stopUpdatingLocation()
        let result = await execution.finish()
        #expect(result.report.diagnostics.isEmpty)
        #expect(driver.stops == 2)
        #expect(driver.bridge == nil)
        #expect(manager.location === original)
        let content = try LocationOriginFixtures.content(#require(result.definition))
        #expect(content.sessions.isEmpty)
        #expect(content.initial == nil)
        #expect(content.access.requests.isEmpty)
    }

    @Test
    func `conversion failure forwards live batch and blocks publication`() async throws {
        let driver = ControlledLocationDriver()
        let (execution, manager) = try await start(driver)
        let journal = NativeJournal()
        manager.delegate = journal
        manager.startUpdatingLocation()
        let invalid = point(100)
        driver.bridge?.receive([invalid])
        #expect(journal.batches.first?.first === invalid)
        #expect(manager.location === invalid)
        let result = await execution.finish()
        #expect(result.definition == nil)
        #expect(!result.report.diagnostics.isEmpty)
        #expect(driver.bridge == nil)
    }

    @Test
    func `fresh setup origins never use baseline overrides and raw coordinates stay out of publication`() async throws {
        let driver = ControlledLocationDriver()
        let (execution, manager) = try await start(driver, policy: .init(
            coordinate: LocationOriginFixtures.defaultCoordinate,
            timestamp: LocationOriginFixtures.defaultTime), baseline: LocationOriginFixtures.definition(
            LocationOriginFixtures.authored()))
        let journal = NativeJournal()
        manager.delegate = journal
        manager.startUpdatingLocation()
        driver.bridge?.receive([point()])
        #expect(manager.location?.coordinate.latitude == LocationOriginFixtures.defaultCoordinate.latitudeDegrees)
        let result = await execution.finish()
        let definition = try #require(result.definition)
        let recording = try LocationOriginFixtures.content(definition)
        #expect(recording.coordinateSpace?.origin.value == LocationOriginFixtures.authoredCoordinate)
        let encoded = try LocationOriginFixtures.codec().encode(definition).data
        let text = try #require(String(data: encoded, encoding: .utf8))
        #expect(!text.contains("12.12345678"))
    }
}

private enum NativeStartupFailure: Error { case expected }

private struct FailingNativeSibling: SystemDefinition {
    let systemType = ScenarioSystemType("test.native-sibling")
    var record: SystemModeDefinition<Void, Int> {
        .init(makeDependency: { throw NativeStartupFailure.expected })
    }

    var replay: SystemModeDefinition<Void, Int> {
        record
    }

    var passthrough: SystemModeDefinition<Void, Int> {
        record
    }
}

extension LocationNativeBridgeTests {
    @Test
    func `pretracking authorization callbacks preserve replayable initial state`() async throws {
        let driver = ControlledLocationDriver()
        let (execution, manager) = try await start(driver)
        driver.access = .init(servicesEnabled: false, permission: .denied, accuracy: .reducedAccuracy)
        driver.bridge?.receiveAuthorization()
        #expect(manager.locationServicesEnabled)
        #expect(manager.authorizationStatus == .notDetermined)
        #expect(manager.accuracyAuthorization == .fullAccuracy)
        let result = await execution.finish()
        let definition = try #require(result.definition)
        let content = try LocationOriginFixtures.content(definition)
        #expect(content.access.initialState == LocationAccessReplayFixtures.initial)
        #expect(content.access.initialNotifications.isEmpty)
        #expect(content.access.requests.isEmpty)
        #expect(result.report.diagnostics.isEmpty)
        let replayDriver = ControlledLocationDriver()
        let (replay, replayManager) = try await start(replayDriver, mode: .replay, baseline: definition)
        #expect(replayManager.locationServicesEnabled == manager.locationServicesEnabled)
        #expect(replayManager.authorizationStatus == manager.authorizationStatus)
        #expect(replayManager.accuracyAuthorization == manager.accuracyAuthorization)
        let replayResult = await replay.finish()
        #expect(replayResult.report.diagnostics.isEmpty)
        #expect(replayDriver.connections == 0)
    }

    @Test(arguments: [LocationAuthorizationRequest.whenInUse, .always])
    func `request before delegate records native state and later registration preserves replay timing`(
        kind: LocationAuthorizationRequest) async throws
    {
        let clock = LocationReplayClock()
        let driver = ControlledLocationDriver()
        driver.authorizationOnRequest = .init(
            servicesEnabled: false, permission: .denied, accuracy: .reducedAccuracy)
        let (execution, manager) = try await start(driver, clock: clock.source)
        clock.advance(to: .milliseconds(20))
        request(kind, on: manager)
        // The driver calls back synchronously from the request, before a delegate exists.
        #expect(manager.delegate == nil)
        #expect(manager.locationServicesEnabled == false)
        #expect(manager.authorizationStatus == .denied)
        #expect(manager.accuracyAuthorization == .reducedAccuracy)
        clock.advance(to: .milliseconds(40))
        let journal = NativeJournal()
        manager.delegate = journal
        #expect(journal.states.isEmpty)
        #expect(manager.authorizationStatus == .denied)
        clock.advance(to: .milliseconds(50))
        driver.access = .init(servicesEnabled: true, permission: .authorizedAlways, accuracy: .fullAccuracy)
        driver.bridge?.receiveAuthorization()
        #expect(journal.states == [.authorizedAlways])
        let result = await execution.finish()
        let definition = try #require(result.definition)
        let content = try LocationOriginFixtures.content(definition)
        #expect(content.access.initialNotifications.isEmpty)
        #expect(content.access.requests.map(\.request) == [kind])
        #expect(content.access.requests[0].notifications.map(\.delayMilliseconds) == [0, 30])
        #expect(driver.requests == [kind])
        #expect(result.report.diagnostics.isEmpty)

        try await verifyAuthorizationReplay(definition, kind: kind, recorded: manager)
    }

    private func verifyAuthorizationReplay(_ definition: ScenarioDefinition, kind: LocationAuthorizationRequest,
                                           recorded: DioramaLocationManager) async throws
    {
        let replayClock = LocationReplayClock()
        let replayDriver = ControlledLocationDriver()
        let (replay, replayManager) = try await start(
            replayDriver, mode: .replay, baseline: definition, clock: replayClock.source)
        replayClock.advance(to: .milliseconds(20))
        request(kind, on: replayManager)
        try await replayClock.waitForDeadline(.milliseconds(50))
        #expect(replayManager.delegate == nil)
        #expect(replayManager.locationServicesEnabled == false)
        #expect(replayManager.authorizationStatus == .denied)
        #expect(replayManager.accuracyAuthorization == .reducedAccuracy)
        replayClock.advance(to: .milliseconds(40))
        let replayJournal = NativeJournal()
        replayManager.delegate = replayJournal
        #expect(replayJournal.states.isEmpty)
        replayClock.advance(to: .milliseconds(50))
        var iterator = replayJournal.accessSignal.stream.makeAsyncIterator()
        #expect(await iterator.next() == .authorizedAlways)
        #expect(replayManager.locationServicesEnabled == recorded.locationServicesEnabled)
        #expect(replayManager.accuracyAuthorization == recorded.accuracyAuthorization)
        let replayResult = await replay.finish()
        #expect(replayJournal.states == [recorded.authorizationStatus])
        #expect(replayResult.usage[0].tracks[1].claimedRecords.map(\.progressCount) == [0, 2])
        #expect(replayResult.usage[0].tracks[1].claimedRecords.allSatisfy(\.isConsumed) == true)
        #expect(replayResult.report.diagnostics.isEmpty)
        #expect(replayDriver.connections == 0)
        #expect(replayDriver.requests.isEmpty)
    }

    private func request(_ kind: LocationAuthorizationRequest, on manager: DioramaLocationManager) {
        switch kind {
        case .whenInUse: manager.requestWhenInUseAuthorization()
        case .always: manager.requestAlwaysAuthorization()
        }
    }

    @Test
    func `passthrough exposes native authorization before any registration or request`() async throws {
        let driver = ControlledLocationDriver()
        let (execution, manager) = try await start(driver, mode: .passthrough)
        driver.access = .init(servicesEnabled: false, permission: .denied, accuracy: .reducedAccuracy)
        driver.bridge?.receiveAuthorization()
        #expect(manager.locationServicesEnabled == false)
        #expect(manager.authorizationStatus == .denied)
        #expect(manager.accuracyAuthorization == .reducedAccuracy)
        manager.requestWhenInUseAuthorization()
        #expect(driver.requests == [.whenInUse])
        let result = await execution.finish()
        #expect(result.report.diagnostics.isEmpty)
        let content = try LocationOriginFixtures.content(#require(result.definition))
        #expect(content.access.initialNotifications.isEmpty)
        #expect(content.access.requests.isEmpty)
    }

    @Test(arguments: [ScenarioMode.record, .passthrough])
    func `later activation failure rolls back the owned native manager`(mode: ScenarioMode) async throws {
        let driver = ControlledLocationDriver()
        let location = try ScenarioSystem(named: "gps", definition: LocationDefinition(driverFactory: { driver }))
        let failure = try ScenarioSystem(named: "later", definition: FailingNativeSibling())
        do {
            _ = try await ScenarioExecution.start(
                definition: ScenarioDefinition(attachments: [location.attachment, failure.attachment]),
                scenarioID: .init(rawValue: "rollback"), defaultMode: mode,
                systems: [AnyScenarioSystem(location), AnyScenarioSystem(failure)])
            Issue.record("Startup unexpectedly succeeded")
        } catch {}
        #expect(driver.connections == 2)
        #expect(driver.bridge == nil)
        #expect(driver.stops == 1)
        #expect(driver.starts == 0)
    }

    @Test
    func `restarts reserve separate sessions and stopped callbacks are ignored`() async throws {
        let driver = ControlledLocationDriver()
        let (execution, manager) = try await start(driver)
        manager.startUpdatingLocation()
        driver.bridge?.receive([point()])
        manager.stopUpdatingLocation()
        driver.bridge?.receive([point(13)])
        manager.startUpdatingLocation()
        driver.bridge?.receive([])
        manager.requestAlwaysAuthorization()
        let result = await execution.finish()
        let content = try LocationOriginFixtures.content(#require(result.definition))
        #expect(content.sessions.count == 2)
        #expect(content.sessions.map(\.events.count) == [1, 1])
        #expect(content.sessions[1].timestampOrigin == nil)
        #expect(content.access.requests.map(\.request) == [.always])
        #expect(result.report.diagnostics.isEmpty)
    }

    @Test
    func `empty native recording freezes valid tracks and public options reject invalid inputs`() async throws {
        let driver = ControlledLocationDriver()
        let (execution, _) = try await start(driver)
        let result = await execution.finish()
        let content = try LocationOriginFixtures.content(#require(result.definition))
        #expect(content.sessions.isEmpty)
        #expect(content.access.initialNotifications.isEmpty)
        #expect(result.report.diagnostics.isEmpty)
        #expect(throws: (any Error).self) {
            try LocationRecordingOptions(coordinateFormat: .degrees, altitudeOriginMeters: .nan)
        }
        #expect(throws: (any Error).self) {
            try LocationRecordingOptions(coordinateFormat: .degrees,
                                         coordinateOrigin: .init(latitude: 100, longitude: 0))
        }
        #expect(throws: (any Error).self) {
            try LocationRecordingOptions(coordinateFormat: .degrees,
                                         timestampOrigin: Date(timeIntervalSince1970: .infinity))
        }
        let options = try LocationRecordingOptions(coordinateFormat: .degrees,
                                                   coordinateOrigin: .init(latitude: 10, longitude: 20))
        let system = try DioramaLocationSystem.instance(named: "public", recording: options)
        #expect(system.attachment.id.systemTypeID == DioramaLocationSystem.type.id)
    }
}

extension LocationNativeBridgeTests {
    @Test(arguments: [ScenarioMode.record, .passthrough], [false, true])
    func `finish releases driver and ignores retained late callbacks`(mode: ScenarioMode, stopFirst: Bool)
        async throws
    {
        var driver: ControlledLocationDriver? = ControlledLocationDriver()
        weak let releasedDriver = driver
        let (execution, manager) = try await start(#require(driver), mode: mode)
        let bridge = try #require(driver?.bridge)
        let journal = NativeJournal()
        manager.delegate = journal
        manager.startUpdatingLocation()
        bridge.receive([point(), point(13)])
        manager.requestAlwaysAuthorization()
        manager.desiredAccuracy = 7
        if stopFirst {
            manager.stopUpdatingLocation()
        }
        let frozen = manager.location
        let waiter = Task { await execution.finish() }
        waiter.cancel()
        let result = await execution.finish()
        #expect(await waiter.value.report == result.report)
        #expect(driver?.connections == 2)
        #expect(driver?.stops == (stopFirst ? 2 : 1))
        #expect(driver?.bridge == nil)
        driver = nil
        #expect(releasedDriver == nil)
        bridge.receive([point(14)])
        bridge.receive(NSError(domain: "late", code: 1))
        bridge.receiveAuthorization()
        manager.startUpdatingLocation()
        manager.requestWhenInUseAuthorization()
        manager.desiredAccuracy = 99
        manager.stopUpdatingLocation()
        #expect(manager.location === frozen)
        #expect(manager.desiredAccuracy == 7)
        #expect(journal.batches.count == 1)
        #expect(journal.errors.isEmpty)
        #expect(journal.states.isEmpty)
        #expect(result.report.diagnostics.isEmpty)
        let content = try LocationOriginFixtures.content(#require(result.definition))
        #expect(content.sessions.count == (mode == .record ? 1 : 0))
        if mode == .record {
            #expect(content.sessions[0].events.count == 1)
            #expect(content.access.requests.map(\.request) == [.always])
        }
    }

    @Test
    func `separately keyed native managers capture independent sessions`() async throws {
        let first = ControlledLocationDriver()
        let second = ControlledLocationDriver()
        let systems = try [first, second].enumerated().map { index, driver in
            try ScenarioSystem(named: "gps-\(index)", definition: LocationDefinition(driverFactory: { driver }))
        }
        let execution = try await ScenarioExecution.start(
            definition: ScenarioDefinition(attachments: systems.map(\.attachment)),
            scenarioID: .init(rawValue: "independent"), defaultMode: .record,
            systems: systems.map(AnyScenarioSystem.init))
        let managers = try systems.map { try execution.dependency($0) }
        let journals = [NativeJournal(), NativeJournal()]
        for index in managers.indices {
            managers[index].delegate = journals[index]
            managers[index].startUpdatingLocation()
        }
        first.bridge?.receive([point(10)])
        managers[0].stopUpdatingLocation()
        first.bridge?.receive([point(11)])
        second.bridge?.receive([point(20)])
        second.bridge?.receive([point(21)])
        #expect(journals.map(\.batches.count) == [1, 2])
        #expect(managers[0].location?.coordinate.latitude == 10)
        #expect(managers[1].location?.coordinate.latitude == 21)
        let result = await execution.finish()
        let definition = try #require(result.definition)
        let eventCounts = try definition.attachments.map { attachment in
            try LocationTracks.recording(in: attachment).sessions[0].events.count
        }
        #expect(eventCounts == [1, 2])
        #expect(first.bridge == nil)
        #expect(second.bridge == nil)
        #expect(first.stops == 2)
        #expect(second.stops == 1)
        #expect(result.report.diagnostics.isEmpty)
    }

    @Test(arguments: [ScenarioMode.record, .passthrough])
    func `real Core Location driver constructs forwards and detaches`(mode: ScenarioMode) async throws {
        let driver = CoreLocationDriver()
        let system = try ScenarioSystem(named: "gps", definition: LocationDefinition(driverFactory: { driver }))
        let execution = try await ScenarioExecution.start(
            definition: ScenarioDefinition(attachments: [system.attachment]),
            scenarioID: .init(rawValue: "apple-driver"), defaultMode: mode,
            systems: [AnyScenarioSystem(system)])
        let manager = try execution.dependency(system)
        let journal = NativeJournal()
        manager.delegate = journal
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        manager.distanceFilter = 100
        // Exercise native construction/configuration/stop without requesting permission or GPS.
        // Delegate entry is controlled: this is not evidence of live sensor fidelity.
        let sender = CLLocationManager()
        driver.locationManager(sender, didUpdateLocations: [point()])
        #expect(journal.batches.isEmpty)
        let before = journal.states.count
        driver.locationManagerDidChangeAuthorization(sender)
        let count = journal.states.count
        #expect(count == before + 1)
        let result = await execution.finish()
        let frozenCount = journal.states.count
        driver.locationManager(sender, didUpdateLocations: [point(14)])
        driver.locationManager(sender, didFailWithError: NSError(domain: "late", code: 2))
        driver.locationManagerDidChangeAuthorization(sender)
        #expect(journal.batches.isEmpty)
        #expect(journal.errors.isEmpty)
        #expect(journal.states.count == frozenCount)
        #expect(result.report.diagnostics.isEmpty)
    }
}

extension LocationNativeBridgeTests {
    @Test(arguments: [false, true], [false, true])
    func `apple recorded fixture decodes and replays through the production facade`(floor: Bool, ellipsoidal: Bool)
        async throws
    {
        let url = try #require(Bundle.module.url(
            forResource: "native-recorded", withExtension: "json", subdirectory: "Fixtures"))
        let bytes = try Data(contentsOf: url)
        let codec = try LocationOriginFixtures.codec()
        let definition = try codec.decode(bytes)
        #expect(try codec.encode(definition).data == bytes)
        let driver = ControlledLocationDriver()
        let (execution, manager) = try await start(driver, mode: .replay, baseline: definition,
                                                   fidelity: .init(preserveFloor: floor,
                                                                   preserveEllipsoidalAltitude: ellipsoidal))
        let journal = NativeJournal()
        manager.delegate = journal
        manager.startUpdatingLocation()
        var iterator = journal.signal.stream.makeAsyncIterator()
        _ = await iterator.next()
        _ = await iterator.next()
        let points = try #require(journal.batches.first)
        #expect(points.count == 2)
        #expect(points[0].coordinate.latitude == 12.12345679)
        #expect(points[1].coordinate.latitude == 12.5)
        #expect(points[0].horizontalAccuracy == 2.123)
        #expect(manager.location === points[1])
        #expect(journal.batches[1].isEmpty)
        var errors = journal.errorSignal.stream.makeAsyncIterator()
        _ = await errors.next()
        #expect(journal.errors.first?.code == 42)
        manager.requestWhenInUseAuthorization()
        var access = journal.accessSignal.stream.makeAsyncIterator()
        #expect(await access.next() == .denied)
        let result = await execution.finish()
        #expect(result.report.diagnostics.isEmpty)
        #expect(driver.connections == 0)
        #expect(driver.starts == 0)
        #expect(driver.requests.isEmpty)
    }
}
