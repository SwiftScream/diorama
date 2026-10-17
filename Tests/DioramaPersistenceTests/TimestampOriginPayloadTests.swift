import DioramaCore
import DioramaPersistence
import Foundation
import Testing

struct TimestampOriginPayloadTests {
    @Test
    func `ISO scalar normalizes before writing and preserves authored origins`() throws {
        let json = Data(#"{"observed":"2030-01-01T00:00:00Z","override":"2030-01-01T00:00:00.0006+05:30"}"#.utf8)
        let value = try JSONDecoder().decode(OverridableValue<TimestampOriginPayload>.self, from: json)
        let expected = try #require(TimestampOrigin("2030-01-01T00:00:00.001+05:30"))
        #expect(value.isOverride)
        #expect(value.value.value == expected)
        let bytes = try JSONEncoder().encode(value)
        #expect(String(data: bytes, encoding: .utf8) == #"{"override":"2030-01-01T00:00:00.001+05:30"}"#)
        #expect(try JSONDecoder().decode(OverridableValue<TimestampOriginPayload>.self, from: bytes)
            .map(\.value) == .override(expected))
        for invalid in [#""invalid""#, "123", "null"] {
            #expect(throws: (any Error).self) {
                try JSONDecoder().decode(TimestampOriginPayload.self, from: Data(invalid.utf8))
            }
        }
    }
}
