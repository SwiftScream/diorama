import DioramaCore
@testable import DioramaDate
import DioramaPersistence
import Foundation
import Testing

struct WallRecordingTests {
    private let codec: JSONScenarioCodec

    init() throws {
        codec = try JSONScenarioCodec(
            registry: PersistentSystemRegistry([DioramaDateSystem.type]))
    }

    @Test
    func `former clock identifier is not accepted as a date system`() throws {
        let current = try #require(String(data: fixture("date-empty"), encoding: .utf8))
        let former = Data(current.replacingOccurrences(of: "diorama.date", with: "diorama.clock").utf8)
        #expect(throws: PersistenceDispatchError.unknownSystemType(SystemTypeID(rawValue: "diorama.clock"))) {
            _ = try codec.decode(former)
        }
    }

    @Test
    func `empty wall payload is distinct from an absent clock attachment`() throws {
        let empty = try DioramaDateSystem.attachment(named: "clock")
        let data = try codec.encode(ScenarioDefinition(attachments: [empty]))
        let expected = try fixture("date-empty")
        #expect(data == expected)
        #expect(try DioramaDateSystem.recording(in: empty) == .empty)
        let trackID = DioramaDateSystem.trackID(for: AttachmentKey(rawValue: "clock"))
        let track = try #require(try empty.track(
            trackID, as: OverridableValue<Date>.self, header: Int?.self))
        #expect(track.header == nil)
        #expect(track.records.isEmpty)
        #expect(try codec.decode(data).attachments.count == 1)
        #expect(try codec.decode(codec.encode(ScenarioDefinition())).attachments.isEmpty)
    }

    @Test
    func `signed successive deltas retain repeats and backward wall values`() throws {
        let origin = try #require(WallOrigin(
            date: Date(timeIntervalSince1970: 1_893_448_800), offsetMinutes: 660))
        let recording = try WallRecording(
            origin: .observed(origin),
            observations: [
                .observed(0), .observed(5000), .observed(0),
                .observed(2000), .observed(-1000),
            ])
        #expect(recording.effectiveDates == [
            origin.date,
            origin.date.addingTimeInterval(5),
            origin.date.addingTimeInterval(5),
            origin.date.addingTimeInterval(7),
            origin.date.addingTimeInterval(6),
        ])
        let attachment = try DioramaDateSystem.attachment(named: "clock", recording: recording)
        let trackID = DioramaDateSystem.trackID(for: AttachmentKey(rawValue: "clock"))
        let track = try #require(try attachment.track(
            trackID, as: OverridableValue<Date>.self, header: Int?.self))
        #expect(track.header == 660)
        #expect(track.records.map(\.value) == recording.effectiveValues)
        let data = try codec.encode(ScenarioDefinition(attachments: [attachment]))
        let expected = try fixture("date-nonempty")
        #expect(data == expected)
        let decoded = try codec.decode(data)
        #expect(try DioramaDateSystem.recording(in: decoded.attachments[0]) == recording)
    }

    @Test
    func `authored first delta shifts origin and canonicalizes position zero`() throws {
        let decoded = try codec.decode(fixture("date-edited"))
        let recording = try DioramaDateSystem.recording(in: decoded.attachments[0])
        #expect(recording.origin?.isOverride == true)
        #expect(recording.origin?.value.date == Date(timeIntervalSince1970: 1_893_448_802))
        #expect(recording.observations == [.observed(0), .override(5000), .observed(-1000)])
        #expect(recording.effectiveValues == [
            .override(Date(timeIntervalSince1970: 1_893_448_802)),
            .override(Date(timeIntervalSince1970: 1_893_448_807)),
            .observed(Date(timeIntervalSince1970: 1_893_448_806)),
        ])

        let canonical = try codec.encode(decoded)
        let expected = try fixture("date-edited-canonical")
        #expect(canonical == expected)
    }

    @Test
    func `dated observations derive successive deltas without losing override markers`() throws {
        let first = try #require(StableTimeCodec.roundedToMillisecond(
            Date(timeIntervalSince1970: 1_893_448_800.125)))
        let second = try #require(StableTimeCodec.roundedToMillisecond(
            Date(timeIntervalSince1970: 1_893_448_800.126)))
        let third = try #require(StableTimeCodec.roundedToMillisecond(
            Date(timeIntervalSince1970: 1_893_448_800.124)))
        let values: [OverridableValue<Date>] = [.observed(first), .override(second), .observed(third)]
        let recording = try WallRecording(offsetMinutes: 660, values: values)
        #expect(recording.effectiveValues == values)
        #expect(recording.observations == [.observed(0), .override(1), .observed(-2)])

        let attachment = try DioramaDateSystem.attachment(named: "clock", recording: recording)
        let encoded = try codec.encode(ScenarioDefinition(attachments: [attachment]))
        let decoded = try codec.decode(encoded)
        #expect(try DioramaDateSystem.recording(in: decoded.attachments[0]) == recording)
    }

    @Test
    func `builder rejects malformed structures and cumulative overflow`() throws {
        let origin = try #require(WallOrigin(date: Date(timeIntervalSince1970: 0), offsetMinutes: 0))
        #expect(throws: WallRecordingError.originWithoutObservations) {
            _ = try WallRecording(origin: .observed(origin), observations: [])
        }
        #expect(throws: WallRecordingError.missingOrigin) {
            _ = try WallRecording(origin: nil, observations: [.observed(0)])
        }
        #expect(throws: WallRecordingError.nonzeroFirstObservation) {
            _ = try WallRecording(origin: .observed(origin), observations: [.observed(1)])
        }
        #expect(throws: WallRecordingError.cumulativeOverflow(position: 2)) {
            _ = try WallRecording(origin: .observed(origin),
                                  observations: [.observed(0), .observed(Int64.max), .observed(1)])
        }
        let shifted = try WallRecording(origin: .observed(origin),
                                        observations: [.override(-1000), .observed(1000)])
        #expect(try shifted.origin == .override(
            #require(WallOrigin(date: Date(timeIntervalSince1970: -1), offsetMinutes: 0))))
        #expect(shifted.observations == [.observed(0), .observed(1000)])

        let unheadered = try ScenarioAttachment(
            id: DioramaDateSystem.trackID(for: AttachmentKey(rawValue: "clock")).attachmentID)
            .adding(HeaderlessSequentialTrack<OverridableValue<Date>>(
                id: DioramaDateSystem.trackID(for: AttachmentKey(rawValue: "clock"))))
        #expect(throws: WallRecordingError.invalidTrackLayout) {
            _ = try DioramaDateSystem.recording(in: unheadered)
        }
    }

    @Test(arguments: [
        ("missing origin", "{\"observations\":[\"0ms\"]}"),
        ("origin without observations", "{\"origin\":\"2030-01-01T09:00:00.000+11:00\"" +
            ",\"observations\":[]}"),
        ("missing observations", "{\"origin\":\"2030-01-01T09:00:00.000+11:00\"}"),
        ("null origin", "{\"origin\":null,\"observations\":[]}"),
        ("nonzero first", "{\"origin\":\"2030-01-01T09:00:00.000+11:00\",\"observations\":[\"1ms\"]}"),
        ("bad origin", "{\"origin\":\"not-a-date\",\"observations\":[\"0ms\"]}"),
        ("bad delta", "{\"origin\":\"2030-01-01T09:00:00.000+11:00\",\"observations\":[\"0ms\",\"1.0000s\"]}"),
        ("cumulative overflow", "{\"origin\":\"2030-01-01T09:00:00.000+11:00\"" +
            ",\"observations\":[\"0ms\",\"9223372036854775807ms\",\"1ms\"]}"),
        ("unknown field", "{\"observations\":[],\"extra\":0}"),
        ("unknown tag", "{\"origin\":\"2030-01-01T09:00:00.000+11:00\",\"observations\":[{\"author\":\"0ms\"}]}"),
        ("missing tag", "{\"origin\":\"2030-01-01T09:00:00.000+11:00\",\"observations\":[{}]}"),
    ])
    func `strict payload rejects invalid edited forms`(_: String, payload: String) throws {
        #expect(throws: (any Error).self) {
            _ = try codec.decode(document(payload: payload))
        }
    }

    @Test
    func `unknown clock version is rejected before payload decoding`() throws {
        let data = Data("""
        {"diorama":{"schemaVersion":1},"systems":[{"attachmentKey":"clock",\
        "type":"diorama.date","schemaVersion":2,"payload":{"observations":[]}}]}
        """.utf8)
        #expect(throws: PersistenceDispatchError.unsupportedSchemaVersion(
            systemTypeID: DioramaDateSystem.type.id,
            declared: 2,
            supported: [DioramaDatePersistence.schemaVersion]))
        {
            _ = try codec.decode(data)
        }
    }

    @Test
    func `unknown clock fields and tags preserve safe coding paths`() throws {
        #expect(throws: PersistedScenarioCodingError.unknownField(
            codingPath: ["systems", "0", "payload"], field: "extra"))
        {
            _ = try codec.decode(document(payload: "{\"observations\":[],\"extra\":0}"))
        }
        let payload = """
        {"origin":"2030-01-01T09:00:00.000+11:00","observations":[{"author":"0ms"}]}
        """
        #expect(throws: PersistedScenarioCodingError.unknownField(
            codingPath: ["systems", "0", "payload", "observations", "0"], field: "author"))
        {
            _ = try codec.decode(document(payload: payload))
        }
    }

    private func document(payload: String) -> Data {
        Data("""
        {"diorama":{"schemaVersion":1},"systems":[{"attachmentKey":"clock",\
        "type":"diorama.date","schemaVersion":1,"payload":\(payload)}]}
        """.utf8)
    }

    private func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(
            forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }
}
