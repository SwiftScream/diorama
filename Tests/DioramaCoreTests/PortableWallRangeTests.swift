import DioramaCore
import Foundation
import Testing

struct PortableWallRangeTests {
    @Test
    func `rounded inclusive bounds round trip at every supported minute offset`() throws {
        let lower = -62_135_500_000.0
        let upper = 253_402_250_000.0
        let supported = [
            lower, lower + 0.001, lower + 0.999, -0.001, 0, 0.001,
            upper - 0.999, upper - 0.001, upper,
        ]
        for seconds in supported {
            let date = try #require(StableTimeCodec.roundedToMillisecond(Date(timeIntervalSince1970: seconds)))
            for offset in -840...840 {
                let text = try #require(StableTimeCodec.formatOrigin(date, offsetMinutes: offset))
                let decoded = try #require(StableTimeCodec.parseOrigin(text))
                #expect(decoded.date == date)
                #expect(decoded.offsetMinutes == offset)
            }
        }
        // Verify the documentation next to the numeric production constants.
        #expect(StableTimeCodec.formatOrigin(Date(timeIntervalSince1970: lower), offsetMinutes: 0)
            == "0001-01-04T02:53:20.000Z")
        #expect(StableTimeCodec.formatOrigin(Date(timeIntervalSince1970: upper), offsetMinutes: 0)
            == "9999-12-31T09:53:20.000Z")
    }

    @Test
    func `range checks follow rounding and reject finite extreme dates`() {
        for bound in [-62_135_500_000.0, 253_402_250_000.0] {
            let exact = Date(timeIntervalSince1970: bound)
            for fraction in [-0.0004, 0.0004] {
                #expect(StableTimeCodec.roundedToMillisecond(Date(timeIntervalSince1970: bound + fraction)) == exact)
            }
        }
        let unsupported: [Double] = [
            -62_135_500_000.001, 253_402_250_000.001, 100_000_000_000_000,
            -100_000_000_000_000, .infinity, -.infinity, .nan,
        ]
        for seconds in unsupported {
            let date = Date(timeIntervalSince1970: seconds)
            #expect(StableTimeCodec.roundedToMillisecond(date) == nil)
            for offset in [-840, 0, 840] {
                #expect(StableTimeCodec.formatOrigin(date, offsetMinutes: offset) == nil)
            }
        }
    }
}
