import Diorama
import DioramaCore
@testable import DioramaLocation
import DioramaPersistence
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct LocationOriginPublicationTests {
    typealias Fixtures = LocationOriginFixtures

    private func file(containing bytes: Data) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("diorama-g06-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("scenario.json")
        try bytes.write(to: file)
        return file
    }

    private func capture(_ fresh: LocationRecording, using dependency: SystemExecution<LocationMergeState>) throws {
        try dependency.state.withLock { state, operation in try state.record(fresh, operation: &operation) }
    }

    private func expectSafeFixture(_ bytes: Data, renderedReport: String) throws {
        let golden = try #require(Bundle.module.url(
            forResource: "origin-rerecorded", withExtension: "json", subdirectory: "Fixtures"))
        #expect(try bytes == Data(contentsOf: golden))
        let text = try #require(String(data: bytes, encoding: .utf8))
        for secret in ["37.12345678", "-122.98765432", "123.456", "145.678", "2037-04-05", "\"observed\""] {
            #expect(!text.contains(secret))
            #expect(!renderedReport.contains(secret))
        }
        #expect(text.contains("\"override\""))
    }

    @Test
    func `file rerecord publishes only effective overrides and leaves fresh output isolated`() async throws {
        let codec = try Fixtures.codec()
        let baseline = try Fixtures.definition(Fixtures.authored())
        let baselineBytes = try codec.encode(baseline)
        let file = try file(containing: baselineBytes)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let system = try ScenarioSystem(named: "gps", definition: LocationMergeDefinition())
        let observed = try Fixtures.observed()
        let fresh = try LocationOriginPolicy(
            coordinate: Fixtures.defaultCoordinate,
            altitude: LocationAltitudeDefaults(meters: 40, ellipsoidalMeters: 50),
            timestamp: Fixtures.defaultTime).prepare(observed)
        let point = try #require(fresh.initial?.location)
        let output = try fresh.measurement(for: point, timestampOrigin: Fixtures.defaultTime, deliveryMilliseconds: 250)
        let result = try await Diorama(file: file, scenarioID: "origin-merge", mode: .record, systems: system)
            .execute { _, dependency in
                try capture(fresh, using: dependency)
                return try fresh.measurement(
                    for: point, timestampOrigin: Fixtures.defaultTime, deliveryMilliseconds: 250)
            }
        let candidate = try #require(result.definition)
        let published = try Fixtures.content(candidate)
        #expect(result.body == output)
        #expect(try published == (Fixtures.merge(fresh, baseline: Fixtures.content(baseline))))
        #expect(published.initial == fresh.initial)
        #expect(published.sessions[0].events == fresh.sessions[0].events)
        let replayed = try published.measurement(
            for: point, timestampOrigin: #require(published.sessions[0].timestampOrigin?.value),
            deliveryMilliseconds: 250)
        #expect(replayed.coordinate.latitude != output.coordinate.latitude)
        #expect(replayed.vertical != output.vertical)
        #expect(replayed.timestamp != output.timestamp)
        #expect(result.report.publication.disposition == .published)
        #expect(result.report.finalization.report.diagnostics.isEmpty)
        #expect(try codec.encode(baseline) == baselineBytes)
        let bytes = try Data(contentsOf: file)
        #expect(try bytes == (codec.encode(candidate)))
        try expectSafeFixture(bytes, renderedReport: result.report.rendered())
        #expect(try codec.encode(codec.decode(bytes)) == bytes)
        #expect(try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path)
            == ["scenario.json"])
        // Loading has no setup policy to reapply, and replay does not invoke record merge.
        let replay = try await Diorama(file: file, scenarioID: "replay", mode: .replay, systems: system)
            .execute { _, dependency in
                try dependency.state.withLock { state, operation in
                    try operation.consumeNext(on: state.sessions)
                }
            }
        #expect(replay.body == published.sessions[0])
        #expect(replay.report.publication.disposition == .notRequested)
        #expect(try Data(contentsOf: file) == bytes)
    }

    @Test(arguments: [false, true])
    func `initial only and access only replacements drop session origins`(accessOnly: Bool) async throws {
        let codec = try Fixtures.codec()
        let baseline = try Fixtures.definition(Fixtures.authored(sessionCount: 3))
        let file = try file(containing: codec.encode(baseline))
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let observed = try Fixtures.observed()
        let fresh = try LocationRecording(
            coordinateSpace: accessOnly ? nil : observed.coordinateSpace,
            altitudeOrigin: accessOnly ? nil : observed.altitudeOrigin,
            initial: accessOnly ? nil : observed.initial, sessions: [], access: Fixtures.access())
        let system = try ScenarioSystem(named: "gps", definition: LocationMergeDefinition())
        let result = try await Diorama(file: file, scenarioID: "shrink", mode: .record, systems: system)
            .execute { _, dependency in try capture(fresh, using: dependency) }
        let candidate = try Fixtures.content(#require(result.definition))
        #expect(try candidate == (Fixtures.merge(fresh, baseline: Fixtures.content(baseline))))
        #expect(candidate.sessions.isEmpty)
        #expect(candidate.initial == fresh.initial)
        #expect(candidate.access == fresh.access)
        #expect(result.report.finalization.report.recordingHealth.isHealthy)
        #expect(result.report.publication.disposition == .published)
        #expect(try Fixtures.content(codec.decode(Data(contentsOf: file))) == candidate)
        if accessOnly {
            #expect(candidate.coordinateSpace == nil)
            #expect(candidate.altitudeOrigin == nil)
        }
    }

    @Test
    func `invalid merged timestamp refuses publication with safe diagnostics`() async throws {
        let observed = try Fixtures.observed()
        let point = try #require(LocationRecordedLocation(
            latencyMilliseconds: 0, coordinateOffset: .degrees(latitudeDegrees: 0, longitudeDegrees: 0),
            horizontalAccuracyMeters: 1))
        let latest = try #require(TimestampOrigin("9999-12-31T09:53:20.000Z"))
        let originalSession = try LocationSession(timestampOrigin: .override(latest), events: [
            .batch(delayMilliseconds: 0, locations: [point]),
        ])
        let original = try LocationRecording(
            coordinateSpace: observed.coordinateSpace, sessions: [originalSession], access: Fixtures.access())
        let freshSession = try LocationSession(timestampOrigin: .observed(Fixtures.observedTime), events: [
            .batch(delayMilliseconds: 1000, locations: [point]),
        ])
        let fresh = try LocationRecording(
            coordinateSpace: observed.coordinateSpace, sessions: [freshSession], access: Fixtures.access())
        let codec = try Fixtures.codec()
        let bytes = try codec.encode(Fixtures.definition(original))
        let file = try file(containing: bytes)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let system = try ScenarioSystem(named: "gps", definition: LocationMergeDefinition())
        let result = try await Diorama(file: file, scenarioID: "invalid", mode: .record, systems: system)
            .execute { _, dependency in try capture(fresh, using: dependency) }
        #expect(result.definition == nil)
        #expect(result.report.publication.disposition == .refusedUnhealthy)
        #expect(result.report.publication.preservation == .unchangedByThisRun)
        #expect(result.report.finalization.report.diagnostics.map(\.diagnostic.issue)
            == [.verification(.recordingMergeFailed)])
        #expect(try Data(contentsOf: file) == bytes)
        #expect(!result.report.rendered().contains("9999"))
        #expect(!result.report.rendered().contains("37.12345678"))
    }

    @Test
    func `keyed attachments retain separate baselines and current defaults`() async throws {
        let first = try ScenarioSystem(named: "first", definition: LocationMergeDefinition())
        let second = try ScenarioSystem(named: "second", definition: LocationMergeDefinition())
        let original = try Fixtures.authored()
        let observed = try Fixtures.observed()
        let baseline = try ScenarioDefinition(attachments: [
            LocationTracks.attachment(named: "first", recording: original),
            LocationTracks.attachment(named: "second", recording: observed),
        ])
        let fresh = try LocationOriginPolicy(
            coordinate: Fixtures.defaultCoordinate, timestamp: Fixtures.defaultTime).prepare(observed)
        let result = try await Diorama(
            definition: baseline, scenarioID: "keys", mode: .record, systems: first, second)
            .execute { _, first, second in
                try capture(fresh, using: first)
                try capture(fresh, using: second)
            }
        let candidate = try #require(result.definition)
        #expect(try Fixtures.content(candidate, named: "first") == Fixtures.merge(fresh, baseline: original))
        #expect(try Fixtures.content(candidate, named: "second") == fresh)
        #expect(try Fixtures.content(baseline, named: "first") == original)
        #expect(try Fixtures.content(baseline, named: "second") == observed)
        #expect(result.report.finalization.report.diagnostics.isEmpty)
    }

    @Test
    func `first capture and later default changes publish ordinary origins`() async throws {
        let codec = try Fixtures.codec()
        let empty = try LocationRecording(coordinateSpace: nil, sessions: [], access: Fixtures.access())
        let file = try file(containing: codec.encode(Fixtures.definition(empty)))
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let system = try ScenarioSystem(named: "gps", definition: LocationMergeDefinition())
        let observed = try Fixtures.observed()
        let policies = [
            LocationOriginPolicy(coordinate: Fixtures.defaultCoordinate, timestamp: Fixtures.defaultTime),
            LocationOriginPolicy(
                coordinate: Fixtures.authoredCoordinate, altitude: LocationAltitudeDefaults(meters: 70),
                timestamp: Fixtures.authoredTime),
            LocationOriginPolicy(),
        ]
        for policy in policies {
            let fresh = try policy.prepare(observed)
            let result = try await Diorama(file: file, scenarioID: "defaults", mode: .record, systems: system)
                .execute { _, dependency in try capture(fresh, using: dependency) }
            #expect(try Fixtures.content(#require(result.definition)) == fresh)
            #expect(try Fixtures.content(codec.decode(Data(contentsOf: file))) == fresh)
            #expect(result.report.publication.disposition == .published)
            #expect(result.report.finalization.report.diagnostics.isEmpty)
        }
    }
}
