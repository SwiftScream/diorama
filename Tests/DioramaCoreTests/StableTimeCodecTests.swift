@testable import DioramaCore
import Foundation
import Testing

private struct StableTimeGoldens: Decodable {
    struct DurationCase: Decodable {
        let input: String
        let milliseconds: Int64
        let canonical: String
    }

    struct OriginCase: Decodable {
        let input: String
        let milliseconds: Int64
        let offsetMinutes: Int
        let canonical: String
    }

    let durations: [DurationCase]
    let origins: [OriginCase]
    let invalidDurations: [String]
    let invalidOrigins: [String]

    static func load() throws -> Self {
        let url = try #require(Bundle.module.url(
            forResource: "stable-time-goldens", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }
}

struct StableTimeCodecTests {
    @Test
    func `duration grammar and canonical output follow independent goldens`() throws {
        let goldens = try StableTimeGoldens.load()
        for item in goldens.durations {
            #expect(StableTimeCodec.parseDuration(item.input) == item.milliseconds)
            #expect(StableTimeCodec.formatDuration(item.milliseconds) == item.canonical)
            #expect(StableTimeCodec.parseDuration(item.canonical) == item.milliseconds)
        }
        for invalid in goldens.invalidDurations {
            #expect(StableTimeCodec.parseDuration(invalid) == nil)
        }
    }

    @Test
    func `foundation origin parsing retains absolute instant and supported numeric offset`() throws {
        let goldens = try StableTimeGoldens.load()
        for item in goldens.origins {
            let parsed = try #require(StableTimeCodec.parseOrigin(item.input))
            #expect(parsed.date == Date(timeIntervalSince1970: Double(item.milliseconds) / 1000))
            #expect(parsed.offsetMinutes == item.offsetMinutes)
            #expect(StableTimeCodec.formatOrigin(parsed.date,
                                                 offsetMinutes: parsed.offsetMinutes) == item.canonical)
            let canonical = try #require(StableTimeCodec.parseOrigin(item.canonical))
            #expect(canonical.date == parsed.date)
            #expect(canonical.offsetMinutes == item.offsetMinutes)
        }
        for invalid in goldens.invalidOrigins {
            #expect(StableTimeCodec.parseOrigin(invalid) == nil)
        }
    }

    @Test
    func `origin formatting requires a representable date and fixed timezone`() {
        #expect(StableTimeCodec.formatOrigin(Date(timeIntervalSince1970: 0),
                                             offsetMinutes: 1440) == nil)
        #expect(StableTimeCodec.formatOrigin(Date(timeIntervalSince1970: 0),
                                             offsetMinutes: 841) == nil)
        #expect(StableTimeCodec.formatOrigin(Date(timeIntervalSince1970: .infinity),
                                             offsetMinutes: 0) == nil)
    }

    @Test
    func `native absolute dates round separately with ties away from epoch`() {
        let observations: [(Double, Double)] = [
            (0.00049, 0), (0.00051, 1), (0.00149, 1), (0.00151, 2),
            (-0.00049, 0), (-0.00051, -1), (-0.00149, -1), (-0.00151, -2),
        ]
        for (seconds, expectedMilliseconds) in observations {
            #expect(StableTimeCodec.roundedToMillisecond(Date(timeIntervalSince1970: seconds))
                == Date(timeIntervalSince1970: expectedMilliseconds / 1000))
        }
        #expect(StableTimeCodec.roundedToMillisecond(Date(timeIntervalSince1970: 0.0625))
            == Date(timeIntervalSince1970: 0.063))
        #expect(StableTimeCodec.roundedToMillisecond(Date(timeIntervalSince1970: -0.0625))
            == Date(timeIntervalSince1970: -0.063))
        #expect(StableTimeCodec.roundedToMillisecond(Date(timeIntervalSince1970: .infinity)) == nil)
        #expect(StableTimeCodec.formatOrigin(Date(timeIntervalSince1970: 0.0006), offsetMinutes: 0)
            == "1970-01-01T00:00:00.001Z")
    }

    @Test
    func `origin formatting stays within selected milliseconds around the epoch`() {
        let cases: [(Int, String)] = [
            (-2, "1969-12-31T23:59:59.998Z"),
            (-1, "1969-12-31T23:59:59.999Z"),
            (0, "1970-01-01T00:00:00.000Z"),
            (1, "1970-01-01T00:00:00.001Z"),
            (2, "1970-01-01T00:00:00.002Z"),
            (998, "1970-01-01T00:00:00.998Z"),
            (999, "1970-01-01T00:00:00.999Z"),
            (1000, "1970-01-01T00:00:01.000Z"),
            (1001, "1970-01-01T00:00:01.001Z"),
        ]
        for (milliseconds, expected) in cases {
            let date = Date(timeIntervalSince1970: Double(milliseconds) / 1000)
            #expect(StableTimeCodec.formatOrigin(date, offsetMinutes: 0) == expected)
        }
    }

    @Test
    func `display offset can be selected from daylight saving time at an instant`() throws {
        let zone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let winter = Date(timeIntervalSince1970: 1_735_718_400)
        let summer = Date(timeIntervalSince1970: 1_751_353_200)
        #expect(StableTimeCodec.formatOrigin(winter,
                                             offsetMinutes: zone.secondsFromGMT(for: winter) / 60)
                == "2025-01-01T00:00:00.000-08:00")
        #expect(StableTimeCodec.formatOrigin(summer,
                                             offsetMinutes: zone.secondsFromGMT(for: summer) / 60)
                == "2025-07-01T00:00:00.000-07:00")
    }
}
