import CoreLocation
import DioramaCore
@testable import DioramaLocation
import Foundation
import Testing

struct LocationNativeMaterializerTests {
    private static let options = [
        LocationFidelityOptions(),
        LocationFidelityOptions(preserveFloor: true),
        LocationFidelityOptions(preserveEllipsoidalAltitude: true),
        LocationFidelityOptions(preserveFloor: true, preserveEllipsoidalAltitude: true),
    ]

    @Test(arguments: options, [(false, false), (false, true), (true, false), (true, true)])
    func `fidelity options choose native construction and preserve enabled fields`(
        options: LocationFidelityOptions, presence: (hasFloor: Bool, hasVertical: Bool)) throws
    {
        let (hasFloor, hasVertical) = presence
        let measurement = try measurement(hasFloor: hasFloor, hasVertical: hasVertical)
        let reporter = try reporter()
        let value = materialize(measurement, options: options, reporter: reporter)
        let ordinary = materialize(measurement, options: .init(), reporter: reporter)
        let usesSubclass = options.preserveEllipsoidalAltitude || (options.preserveFloor && hasFloor)

        #expect((type(of: value) != CLLocation.self) == usesSubclass)
        #expect(value.coordinate.latitude == measurement.coordinate.latitude)
        #expect(value.coordinate.longitude == measurement.coordinate.longitude)
        #expect(value.timestamp == measurement.timestamp)
        #expect(value.horizontalAccuracy == 1.125)
        #expect(value.altitude == (hasVertical ? 42.125 : 0))
        #expect(value.verticalAccuracy == (hasVertical ? 2.125 : -1))
        #expect(value.floor?.level == (options.preserveFloor && hasFloor ? -2 : nil))
        #expect(value.ellipsoidalAltitude == (options.preserveEllipsoidalAltitude && hasVertical
                ? 73.125 : ordinary.ellipsoidalAltitude))
        #expect(value.speed == 3.125)
        #expect(value.speedAccuracy == 0.125)
        #expect(value.course == 180.125)
        #expect(value.courseAccuracy == 1.125)
        #expect(value.sourceInformation?.isSimulatedBySoftware == true)
        #expect(value.sourceInformation?.isProducedByAccessory == false)

        let copy = try #require(value.copy() as? CLLocation)
        #expect(copy.floor?.level == value.floor?.level)
        #expect(copy.ellipsoidalAltitude == value.ellipsoidalAltitude)
        #expect(copy.timestamp == value.timestamp)
        #expect(copy.coordinate.latitude == value.coordinate.latitude)
        if let floor = copy.floor {
            #expect((floor.copy() as? CLFloor)?.level == -2)
        }
        #expect(reporter.freeze().diagnostics.isEmpty)
    }

    @Test(arguments: options, [false, true])
    func `secure archives decode native values and diagnose only subclass encoding`(
        options: LocationFidelityOptions, hasFloor: Bool) throws
    {
        let measurement = try measurement(hasFloor: hasFloor)
        let reporter = try reporter()
        let value = materialize(measurement, options: options, reporter: reporter)
        let data = try NSKeyedArchiver.archivedData(withRootObject: value, requiringSecureCoding: true)
        let decoded = try #require(try NSKeyedUnarchiver.unarchivedObject(ofClass: CLLocation.self, from: data))

        #expect(type(of: decoded) == CLLocation.self)
        #expect(decoded.coordinate.latitude == value.coordinate.latitude)
        #expect(decoded.coordinate.longitude == value.coordinate.longitude)
        #expect(decoded.altitude == value.altitude)
        #expect(decoded.timestamp == value.timestamp)
        #expect(decoded.floor == nil)
        let usesSubclass = options.preserveEllipsoidalAltitude || (options.preserveFloor && hasFloor)
        let facts = reporter.freeze()
        #expect(facts.recordingHealth.isHealthy)
        #expect(facts.diagnostics.count == (usesSubclass ? 1 : 0))
        if usesSubclass {
            let fact = try #require(facts.diagnostics.first?.diagnostic)
            #expect(fact.issue == .system(DiagnosticLabel("location.archiveFidelityLoss")))
            #expect(fact.context == .attachment(Self.attachmentID))
        }
    }

    @Test
    func `absent optional measurements use canonical native sentinels`() throws {
        let measurement = try #require(LocationMeasurement(
            coordinate: CLLocationCoordinate2D(latitude: 0, longitude: -180),
            horizontalAccuracyMeters: 0, timestamp: Date(timeIntervalSince1970: 0)))
        let reporter = try reporter()
        let baseline = CLLocation(
            coordinate: measurement.coordinate, altitude: 0, horizontalAccuracy: 0,
            verticalAccuracy: -1, course: -1, courseAccuracy: -1,
            speed: -1, speedAccuracy: -1, timestamp: measurement.timestamp)
        for options in Self.options {
            let value = materialize(measurement, options: options, reporter: reporter)
            #expect(value.verticalAccuracy == -1)
            #expect(value.speed == -1)
            #expect(value.speedAccuracy == -1)
            #expect(value.course == -1)
            #expect(value.courseAccuracy == -1)
            #expect(value.floor == nil)
            #expect(value.sourceInformation?.isSimulatedBySoftware == baseline.sourceInformation?.isSimulatedBySoftware)
            #expect(value.sourceInformation?.isProducedByAccessory == baseline.sourceInformation?.isProducedByAccessory)
        }
    }

    @Test
    func `explicit false source flags survive native materialization`() throws {
        let measurement = try #require(LocationMeasurement(
            coordinate: CLLocationCoordinate2D(latitude: 1, longitude: 2),
            horizontalAccuracyMeters: 0, timestamp: Date(timeIntervalSince1970: 0),
            sourceInformation: LocationSourceInformation(
                simulatedBySoftware: false, producedByAccessory: false)))
        let reporter = try reporter()
        for options in Self.options {
            let value = materialize(measurement, options: options, reporter: reporter)
            #expect(value.sourceInformation?.isSimulatedBySoftware == false)
            #expect(value.sourceInformation?.isProducedByAccessory == false)
        }
    }

    @Test
    func `native distance works with materialized subclass in either direction`() throws {
        let measurement = try measurement()
        let reporter = try reporter()
        let native = materialize(measurement, options: .init(), reporter: reporter)
        let fidelity = materialize(measurement, options: Self.options[3], reporter: reporter)
        let other = CLLocation(latitude: 40.7128, longitude: -74.006)
        #expect(other.distance(from: fidelity) == other.distance(from: native))
        #expect(fidelity.distance(from: other) == native.distance(from: other))
    }

    @Test
    func `concurrent reads copies and archives retain immutable fidelity and safe facts`() async throws {
        let reporter = try reporter()
        let value = try materialize(measurement(), options: Self.options[3], reporter: reporter)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<24 {
                group.addTask {
                    let copy = try #require(value.copy() as? CLLocation)
                    #expect(copy.floor?.level == -2)
                    #expect(copy.ellipsoidalAltitude == 73.125)
                    _ = try NSKeyedArchiver.archivedData(withRootObject: copy, requiringSecureCoding: true)
                }
            }
            try await group.waitForAll()
        }
        let final = reporter.freeze()
        #expect(final.diagnostics.count == 24)
        #expect(final.recordingHealth.isHealthy)
        _ = try NSKeyedArchiver.archivedData(withRootObject: value, requiringSecureCoding: true)
        #expect(reporter.report == final)
        #expect(reporter.postFinishDiagnostics.count == 1)
    }

    @Test
    func `escaped native values retain safe reporting without retaining the execution`() async throws {
        var execution: ScenarioExecution? = try await ScenarioExecution.start(
            definition: ScenarioDefinition(), scenarioID: ScenarioID(rawValue: "native-lifetime"),
            defaultMode: .record, systems: [])
        weak let weakExecution = execution
        let reporter = try #require(execution?.reporter)
        let value = try materialize(measurement(), options: Self.options[3], reporter: reporter)
        let final = await execution?.finish()
        execution = nil
        #expect(weakExecution == nil)
        #expect(final?.report.diagnostics.isEmpty == true)
        _ = try NSKeyedArchiver.archivedData(withRootObject: value, requiringSecureCoding: true)
        #expect(reporter.report?.diagnostics.isEmpty == true)
        #expect(reporter.postFinishDiagnostics.count == 1)
        #expect(value.floor?.level == -2)
    }

    private static let attachmentID = AttachmentID(
        systemTypeID: LocationTracks.type.id, key: AttachmentKey(rawValue: "gps"))

    private func reporter() throws -> DiagnosticReporter {
        try DiagnosticReporter(
            scenarioID: ScenarioID(rawValue: "native-materialization"),
            definition: ScenarioDefinition(attachments: [ScenarioAttachment(id: Self.attachmentID)]))
    }

    private func materialize(_ measurement: LocationMeasurement, options: LocationFidelityOptions,
                             reporter: DiagnosticReporter) -> CLLocation
    {
        LocationNativeMaterializer(
            fidelity: options, reporter: reporter, context: .attachment(Self.attachmentID))
            .materialize(measurement)
    }

    private func measurement(hasFloor: Bool = true, hasVertical: Bool = true) throws -> LocationMeasurement {
        try #require(LocationMeasurement(
            coordinate: CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194),
            horizontalAccuracyMeters: 1.125,
            vertical: hasVertical ? LocationVerticalEstimate(
                orthometricAltitudeMeters: 42.125, ellipsoidalAltitudeMeters: 73.125, accuracyMeters: 2.125) : nil,
            floorLevel: hasFloor ? -2 : nil,
            speed: LocationSpeedEstimate(metersPerSecond: 3.125, accuracyMetersPerSecond: 0.125),
            course: LocationCourseEstimate(degrees: 180.125, accuracyDegrees: 1.125),
            timestamp: Date(timeIntervalSince1970: 1_700_000_000.125),
            sourceInformation: LocationSourceInformation(simulatedBySoftware: true, producedByAccessory: false)))
    }
}
