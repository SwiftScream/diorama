import DioramaCore
import Foundation
import Testing

struct TimestampOriginTests {
    @Test
    func `construction normalizes native and textual dates with retained offsets`() throws {
        for (seconds, expected) in [(-0.0625, -0.063), (0.0625, 0.063), (1_893_456_000.1236, 1_893_456_000.124)] {
            let origin = try #require(TimestampOrigin(date: Date(timeIntervalSince1970: seconds), offsetMinutes: 330))
            #expect(origin.date == Date(timeIntervalSince1970: expected))
            #expect(origin.offsetMinutes == 330)
            #expect(TimestampOrigin(origin.text) == origin)
            #expect(TimestampOrigin(date: origin.date, offsetMinutes: origin.offsetMinutes) == origin)
        }
        let parsed = try #require(TimestampOrigin("2030-01-01T00:00:00.0006+05:30"))
        #expect(parsed.text == "2030-01-01T00:00:00.001+05:30")
    }

    @Test
    func `invalid origins fail and signed advancement respects portable boundaries`() throws {
        for seconds in [Double.nan, .infinity, -.infinity, -62_135_500_000.001, 253_402_250_000.001] {
            #expect(TimestampOrigin(date: Date(timeIntervalSince1970: seconds), offsetMinutes: 0) == nil)
        }
        for offset in [-841, 841, Int.min, Int.max] {
            #expect(TimestampOrigin(date: Date(timeIntervalSince1970: 0), offsetMinutes: offset) == nil)
        }
        #expect(TimestampOrigin("invalid") == nil)
        let origin = try #require(TimestampOrigin("2030-01-01T00:00:00.000Z"))
        #expect(origin.advanced(by: -1250) == origin.date.addingTimeInterval(-1.25))
        #expect(origin.advanced(by: 1250) == origin.date.addingTimeInterval(1.25))
        #expect(origin.advanced(by: .min) == nil)
        #expect(origin.advanced(by: .max) == nil)
        for (bound, outward) in [(-62_135_500_000.0, Int64(-1)), (253_402_250_000.0, Int64(1))] {
            let boundary = try #require(TimestampOrigin(date: Date(timeIntervalSince1970: bound), offsetMinutes: 840))
            #expect(TimestampOrigin(boundary.text) == boundary)
            #expect(boundary.advanced(by: outward) == nil)
            #expect(boundary.advanced(by: -outward) != nil)
        }
    }
}
