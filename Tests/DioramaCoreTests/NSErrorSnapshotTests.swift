import DioramaCore
import Foundation
import Testing

struct NSErrorSnapshotTests {
    @Test
    func `reconstruction preserves supported values with fresh native identity`() throws {
        let snapshot = try #require(NSErrorSnapshot(domain: "example.failure", code: -987_654, userInfo: [
            "text": .string("supported"),
            "minimum": .integer(.min),
            "maximum": .integer(.max),
            "real": .real(1.5),
            "true": .boolean(true),
            "false": .boolean(false),
            "data": .data(Data([0, 255])),
            "date": .date(Date(timeIntervalSince1970: 123.456)),
            "nested": .dictionary(["items": .array([.string("one"), .integer(2)])]),
        ]))
        let first = snapshot.makeError()
        let second = snapshot.makeError()

        #expect(first !== second)
        #expect(first.domain == "example.failure")
        #expect(first.code == -987_654)
        let recaptured = NSErrorSnapshot.capture(first)
        #expect(recaptured.snapshot == snapshot)
        #expect(recaptured.omissions.isEmpty)
    }

    @Test
    func `capture detaches mutable native information`() throws {
        let text = NSMutableString(string: "original")
        let bytes = NSMutableData(data: Data([1, 2]))
        let collection = NSMutableArray(array: ["original"])
        let error = NSError(domain: "example.failure", code: 1, userInfo: [
            "text": text, "bytes": bytes, "collection": collection,
        ])
        let snapshot = try #require(NSErrorSnapshot.capture(error).snapshot)

        text.setString("changed")
        bytes.setData(Data([3]))
        collection.add("changed")

        #expect(snapshot.userInfo["text"] == .string("original"))
        #expect(snapshot.userInfo["bytes"] == .data(Data([1, 2])))
        #expect(snapshot.userInfo["collection"] == .array([.string("original")]))
        #expect(NSErrorSnapshot.capture(snapshot.makeError()).snapshot == snapshot)
    }

    @Test(arguments: ["", String(repeating: "d", count: NSErrorSnapshot.maximumKeyBytes + 1)])
    func `capture rejects unrepresentable domains`(domain: String) {
        let captured = NSErrorSnapshot.capture(NSError(domain: domain, code: 1))
        #expect(captured.snapshot == nil)
        #expect(captured.omissions.isEmpty)
    }

    @Test
    func `captures bounded property list values and omits unsupported entries`() throws {
        let error = NSError(domain: "example.failure", code: 7, userInfo: [
            "boolean": true,
            "integer": 42,
            "real": 1.5,
            "text": "supported",
            "data": Data([1, 2, 3]),
            "date": Date(timeIntervalSince1970: 100),
            "nested": ["items": ["one", 2]],
            "unsupported": NSObject(),
        ])
        let captured = NSErrorSnapshot.capture(error)
        let failure = try #require(captured.snapshot)

        #expect(failure.domain == "example.failure")
        #expect(failure.code == 7)
        #expect(failure.userInfo["boolean"] == .boolean(true))
        #expect(failure.userInfo["integer"] == .integer(42))
        #expect(failure.userInfo["real"] == .real(1.5))
        #expect(failure.userInfo["text"] == .string("supported"))
        #expect(failure.userInfo["data"] == .data(Data([1, 2, 3])))
        #expect(failure.userInfo["date"] == .date(Date(timeIntervalSince1970: 100)))
        #expect(failure.userInfo["nested"] == .dictionary([
            "items": .array([.string("one"), .integer(2)]),
        ]))
        #expect(failure.userInfo["unsupported"] == nil)
        #expect(captured.omissions.map(\.key) == ["unsupported"])
        #expect(captured.omissions[0].runtimeType.contains("NSObject"))
    }

    @Test
    func `oversized and invalid values are omitted without rendering values`() throws {
        let secret = String(repeating: "s", count: NSErrorSnapshot.maximumStringBytes + 1)
        let error = NSError(domain: "example.failure", code: 1, userInfo: [
            "oversized": secret,
            "nonfinite": Double.infinity,
            "object": ["safe": "yes", "unsafe": NSObject()],
            "safe": "kept",
        ])
        let captured = NSErrorSnapshot.capture(error)
        let failure = try #require(captured.snapshot)
        #expect(failure.userInfo == ["safe": .string("kept")])
        #expect(captured.omissions.map(\.key) == ["nonfinite", "object", "oversized"])
        #expect(!String(describing: captured.omissions).contains(secret))
    }

    @Test
    func `strict failure rejects excessive depth counts and bytes`() {
        #expect(NSErrorSnapshot(domain: "", code: 1) == nil)
        #expect(NSErrorSnapshot(domain: "d", code: 1,
                                userInfo: ["bad": .real(.infinity)]) == nil)
        #expect(NSErrorSnapshot(domain: "d", code: 1,
                                userInfo: ["bad": .string(String(repeating: "x", count: 4097))]) == nil)
        var nested = NSErrorSnapshotValue.string("leaf")
        for _ in 0...NSErrorSnapshot.maximumDepth {
            nested = .array([nested])
        }
        #expect(NSErrorSnapshot(domain: "d", code: 1, userInfo: ["nested": nested]) == nil)
        #expect(NSErrorSnapshot(domain: "d", code: 1,
                                userInfo: ["array": .array(Array(repeating: .integer(1), count: 33))]) == nil)
        #expect(NSErrorSnapshot(domain: "d", code: 1,
                                userInfo: ["data": .data(Data(count: 16385))]) == nil)
    }

    @Test
    func `capture preserves safe siblings when nested or total limits are exceeded`() throws {
        let large = String(repeating: "a", count: NSErrorSnapshot.maximumStringBytes)
        let error = NSError(domain: "example.failure", code: 1, userInfo: [
            "a": Array(repeating: large, count: 16),
            "b": "retained",
            "c": ["nested": ["too": ["deep": ["for": ["capture": 1]]]]],
        ])
        let captured = NSErrorSnapshot.capture(error)
        let failure = try #require(captured.snapshot)
        #expect(failure.userInfo["b"] == .string("retained"))
        #expect(captured.omissions.map(\.key).contains("a"))
        #expect(captured.omissions.map(\.key).contains("c"))
    }
}
