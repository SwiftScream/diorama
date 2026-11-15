import DioramaCore
import DioramaPersistence
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct NSErrorSnapshotPayloadTests {
    @Test
    func `native URL metadata round trips through tagged JSON and reconstructs as URLs`() throws {
        let spelling = "https://example.invalid/a?x=%2f&x=%2F"
        let url = try #require(URL(string: spelling))
        let relative = try #require(URL(string: "../relative"))
        let original = NSError(domain: NSURLErrorDomain, code: -1001, userInfo: [
            NSURLErrorFailingURLErrorKey: url as NSURL,
            "nested": [relative],
            "text": spelling,
        ])
        let snapshot = try #require(NSErrorSnapshot.capture(original).snapshot)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let encoded = try encoder.encode(NSErrorSnapshotPayload(snapshot))
        let json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let metadata = try #require(json["userInfo"] as? [String: [String: Any]])
        #expect(metadata[NSURLErrorFailingURLErrorKey]?["type"] as? String == "url")
        #expect(metadata[NSURLErrorFailingURLErrorKey]?["value"] as? String == spelling)
        #expect(metadata["text"]?["type"] as? String == "string")
        let decoded = try JSONDecoder().decode(NSErrorSnapshotPayload.self, from: encoded)
        let decodedSnapshot = try decoded.snapshot()
        #expect(decodedSnapshot.userInfo[NSURLErrorFailingURLErrorKey] == .url(url))
        #expect(decodedSnapshot.userInfo["nested"] == .array([.url(relative)]))
        let restored = try decoded.snapshot().makeError()
        #expect(restored !== original)
        #expect(restored.domain == original.domain)
        #expect(restored.code == original.code)
        #expect((restored.userInfo[NSURLErrorFailingURLErrorKey] as? URL)?.absoluteString == spelling)
        #expect((restored.userInfo["nested"] as? [URL])?.first?.absoluteString == "../relative")
        #expect(try decoded.snapshot() == snapshot)
        #expect(NSErrorSnapshot.capture(restored).snapshot == snapshot)
        #expect(try encoder.encode(decoded) == encoded)
    }

    @Test
    func `URL tags reject malformed oversized missing null and wrong type values`() throws {
        let invalid: [[String: Any]] = [
            ["type": "url", "value": ""],
            ["type": "url", "value": "https://example.invalid/bad path"],
            ["type": "url", "value": "https://example.invalid/%zz"],
            ["type": "url", "value": String(repeating: "u", count: NSErrorSnapshot.maximumStringBytes + 1)],
            ["type": "url"],
            ["type": "url", "value": NSNull()],
            ["type": "url", "value": 42],
            ["type": "url", "value": "https://example.invalid/", "base": "https://other.invalid/"],
        ]
        for tag in invalid {
            let encoded = try JSONSerialization.data(withJSONObject: [
                "domain": "ExampleError", "code": 1, "userInfo": ["url": tag],
            ])
            #expect(throws: (any Error).self) {
                try JSONDecoder().decode(NSErrorSnapshotPayload.self, from: encoded)
            }
        }
        let urlTag = ["type": "url", "value": String(repeating: "u", count: NSErrorSnapshot.maximumStringBytes)]
        let urls = Array(repeating: urlTag, count: 16)
        let oversized = try JSONSerialization.data(withJSONObject: [
            "domain": "ExampleError", "code": 1,
            "userInfo": ["urls": ["type": "array", "value": urls]],
        ])
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(NSErrorSnapshotPayload.self, from: oversized)
        }
    }

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
