import DioramaCore
import DioramaPersistence
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct NSErrorSnapshotPayloadTests {
    @Test
    func `bounded failure values round trip with exact integer and nested types`() throws {
        let date = Date(timeIntervalSince1970: 1_893_456_000.000125)
        let values: [NSErrorSnapshotValue] = [.integer(Int64.max), .real(0.10000000000000002), .boolean(false)]
        let snapshot = try #require(NSErrorSnapshot(
            domain: "ExampleError", code: 99,
            userInfo: [
                "bytes": .data(Data([0, 255])),
                "date": .date(date),
                "nested": .dictionary(["values": .array(values)]),
            ]))
        let encoded = try JSONEncoder().encode(NSErrorSnapshotPayload(snapshot))
        let decoded = try JSONDecoder().decode(NSErrorSnapshotPayload.self, from: encoded)
        #expect(try decoded.snapshot() == snapshot)
        let encodedText = try #require(String(data: encoded, encoding: .utf8))
        #expect(encodedText.contains("0.10000000000000002"))
        let invalid = Data(#"{"domain":"","code":1,"userInfo":{}}"#.utf8)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(NSErrorSnapshotPayload.self, from: invalid)
        }
    }
}
