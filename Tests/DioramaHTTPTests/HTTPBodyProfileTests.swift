import DioramaCore
import DioramaHTTP
import Foundation
import HTTPTypes
import Testing

struct HTTPBodyProfileTests {
    private enum Failure: String, Codable, Sendable { case timeout }
    private typealias Delivery = HTTPBodyDelivery<Failure>
    private typealias Response = HTTPResponseNode<Failure>

    private struct AllocationExample: Decodable {
        let weights: [Int64]
        let byteCount: Int
        let counts: [Int]
    }

    @Test
    func `independent allocation goldens cover rounding zero weights and large products`() throws {
        let examples = try decoder().decode(
            [AllocationExample].self, from: fixture("body-allocations"))
        for example in examples {
            let profile = try profile(example.weights)
            let allocations = try profile.allocate(byteCount: example.byteCount)
            #expect(allocations.map(\.byteRange.count) == example.counts)
            #expect(allocations.count == example.weights.count)
            #expect(allocations.first?.byteRange.lowerBound == 0)
            #expect(allocations.last?.byteRange.upperBound == example.byteCount)
            #expect(allocations.map(\.byteRange.count).reduce(0, +) == example.byteCount)
            for pair in zip(allocations, allocations.dropFirst()) {
                #expect(pair.0.byteRange.upperBound == pair.1.byteRange.lowerBound)
            }
        }
    }

    @Test
    func `unchanged observed weights reproduce original boundaries exactly`() throws {
        for weights: [Int64] in [[20, 80], [0, 7, 0, 3, 0], [1], [0, 0]] {
            let profile = try profile(weights)
            let allocations = try profile.allocate(byteCount: Int(profile.totalByteWeight))
            #expect(allocations.map { Int64($0.byteRange.count) } == weights)
        }
    }

    @Test
    func `small exhaustive allocations cover the body and preserve zero weight deliveries`() throws {
        for first: Int64 in 0...4 {
            for second: Int64 in 0...4 {
                let profile = try profile([first, 0, second])
                for count in 0...16 {
                    let values = try profile.allocate(byteCount: count)
                    #expect(values[0].byteRange.lowerBound == 0)
                    #expect(values[0].byteRange.upperBound == values[1].byteRange.lowerBound)
                    #expect(values[1].byteRange.isEmpty)
                    #expect(values[1].byteRange.upperBound == values[2].byteRange.lowerBound)
                    #expect(values[2].byteRange.upperBound == count)
                    #expect(values.allSatisfy { $0.byteRange.lowerBound >= 0 && $0.byteRange.upperBound <= count })
                }
            }
        }
    }

    @Test
    func `binary and UTF8 split boundaries neither decode nor duplicate bytes`() throws {
        let bytes: [UInt8] = [0xE2, 0x82, 0xAC, 0, 255]
        let allocations = try profile([1, 1, 3]).allocate(byteCount: bytes.count)
        let chunks = allocations.map { Array(bytes[$0.byteRange]) }
        #expect(chunks == [[0xE2], [0x82], [0xAC, 0, 255]])
        #expect(chunks.flatMap(\.self) == bytes)
        #expect(String(bytes: chunks[0], encoding: .utf8) == nil)
    }

    @Test
    func `timed profile golden normalizes effective overrides and omits derived values`() throws {
        let data = try fixture("body-profile")
        let value = try decoder().decode(Delivery.self, from: data)
        let profile = try #require(value.profile)
        #expect(value.content == .bytes(Array("€!".utf8)))
        #expect(profile.totalByteWeight == 4)
        #expect(profile.durationMilliseconds == 35)
        let allocations = try profile.allocate(byteCount: 7)
        #expect(allocations.map(\.byteRange) == [0..<1, 1..<3, 3..<7])
        #expect(allocations.map(\.offsetMilliseconds) == [10, 10, 35])
        #expect(allocations.map(\.after.milliseconds) == [.observed(10), .observed(0), .override(25)])
        #expect(try canonical(value) == data)
        let text = try #require(String(data: data, encoding: .utf8))
        let edited = text.replacingOccurrences(of: "\"override\" : \"25ms\"",
                                               with: "\"observed\" : \"-100ms\", \"override\" : \"0.025s\"")
        let normalized = try decoder().decode(Delivery.self, from: Data(edited.utf8))
        #expect(normalized == value)
        #expect(try canonical(normalized) == data)
    }

    @Test
    func `resource length edits allocate the same logical bytes as inline storage`() throws {
        let shape = try profile([2, 8])
        let resource = try HTTPResourceCodingFixtures.resource(path: "bodies/edited.bin", bytes: [1, 2, 3])
        let inline = try Delivery(content: .bytes([1, 2, 3]), profile: shape, conclusion: .openAtRecordingHorizon)
        let external = try Delivery(content: .resource(resource), profile: shape, conclusion: .openAtRecordingHorizon)
        #expect(try inline.profile?.allocate(byteCount: 3) == external.profile?.allocate(byteCount: 3))
        #expect(try external.profile?.allocate(byteCount: 100).map(\.byteRange.count) == [20, 80])
        #expect(try external.profile?.allocate(byteCount: 0).map(\.byteRange.count) == [0, 0])
        #expect(try decoder().decode(Delivery.self, from: canonical(external)) == external)
    }

    @Test
    func `profiles work for every conclusion including empty bodies and retained trailers`() throws {
        let shape = try profile([0, 0])
        let trailers = try HTTPTrailers(after: delay(4), fields: HTTPFields())
        let conclusions: [HTTPBodyConclusion<Failure>] = try [
            .returned(HTTPBodyCompletion(after: delay(5), trailers: trailers)),
            .failed(HTTPTimed(after: delay(6), value: .timeout)), .openAtRecordingHorizon,
        ]
        for conclusion in conclusions {
            let value = try Delivery(content: .bytes([]), profile: shape, conclusion: conclusion)
            #expect(value.conclusion == conclusion)
            #expect(try decoder().decode(Delivery.self, from: canonical(value)) == value)
            #expect(try value.profile?.allocate(byteCount: 5).map(\.byteRange.count) == [0, 5])
        }
        let unprofiled = Delivery(content: .bytes([]), conclusion: .openAtRecordingHorizon)
        #expect(unprofiled.profile == nil)
        #expect(try decoder().decode(Delivery.self, from: canonical(unprofiled)) == unprofiled)
    }

    @Test
    func `absent and unavailable bodies cannot acquire profiles through builders or decoding`() throws {
        for content: HTTPResponseBody in [.absent, .unavailable] {
            #expect(throws: HTTPLifecycleError.bodyProfileWithoutBytes) {
                try Delivery(content: content, profile: profile([0]), conclusion: .openAtRecordingHorizon)
            }
            let unprofiled = Delivery(content: content, conclusion: .openAtRecordingHorizon)
            var object = try object(unprofiled)
            object["segments"] = [["byteWeight": 0, "after": "0ms"]]
            try expectCorrupt(Delivery.self, object, path: ["segments"])
        }
    }

    @Test
    func `builders reject negative weights length and empty profiles`() throws {
        #expect(throws: HTTPLifecycleError.negativeByteWeight) {
            try HTTPBodySegment(byteWeight: -1, after: delay(0))
        }
        #expect(throws: HTTPLifecycleError.emptyBodyProfile) { try HTTPBodyProfile(segments: []) }
        #expect(throws: HTTPLifecycleError.negativeBodyLength) { try profile([1]).allocate(byteCount: -1) }
    }

    @Test
    func `weight totals and exact wide multiplication stay within validated integer bounds`() throws {
        let maximum = try profile([Int64.max - 1, 1])
        #expect(maximum.totalByteWeight == Int64.max)
        #expect(try maximum.allocate(byteCount: Int.max).map(\.byteRange.count) == [Int.max - 1, 1])
        #expect(throws: HTTPLifecycleError.byteWeightOverflow) { try profile([Int64.max, 1]) }
        #expect(throws: HTTPLifecycleError.byteWeightOverflow) { try profile([Int64.max, Int64.max]) }
    }

    @Test
    func `cumulative segment delays accept the inclusive bound and reject overflow`() throws {
        let maximum = try timedProfile([Int64.max - 1, 1, 0])
        #expect(maximum.durationMilliseconds == Int64.max)
        #expect(try maximum.allocate(byteCount: 1).map(\.offsetMilliseconds)
            == [Int64.max - 1, Int64.max, Int64.max])
        #expect(throws: HTTPLifecycleError.delayOverflow) { try timedProfile([Int64.max, 1]) }
        #expect(throws: HTTPLifecycleError.delayOverflow) { try timedProfile([Int64.max, Int64.max]) }
    }

    @Test
    func `cumulative timing includes head segments trailers completion and failure`() throws {
        let shape = try timedProfile([2, 3])
        let trailers = try HTTPTrailers(after: delay(4), fields: HTTPFields())
        let complete = try HTTPBodyCompletion(after: delay(Int64.max - 10), trailers: trailers)
        let body = try Delivery(content: .bytes([1]), profile: shape, conclusion: .returned(complete))
        _ = try response(headDelay: 1, body: body)
        #expect(throws: HTTPLifecycleError.delayOverflow) { try response(headDelay: 2, body: body) }
        #expect(throws: HTTPLifecycleError.delayOverflow) {
            try HTTPBodyCompletion(after: delay(Int64.max - 3), trailers: trailers)
        }
        #expect(throws: HTTPLifecycleError.delayOverflow) {
            try Delivery(content: .bytes([]), profile: shape,
                         conclusion: .failed(HTTPTimed(after: delay(Int64.max - 4), value: .timeout)))
        }
        #expect(throws: HTTPLifecycleError.delayOverflow) {
            try Delivery(content: .bytes([]), profile: shape,
                         conclusion: .returned(HTTPBodyCompletion(after: delay(Int64.max - 4))))
        }
        let open = try Delivery(content: .bytes([]), profile: timedProfile([Int64.max]),
                                conclusion: .openAtRecordingHorizon)
        _ = try response(headDelay: 0, body: open)
        #expect(throws: HTTPLifecycleError.delayOverflow) { try response(headDelay: 1, body: open) }
        let failed = try Delivery(
            content: .absent, conclusion: .failed(HTTPTimed(after: delay(Int64.max), value: .timeout)))
        _ = try response(headDelay: 0, body: failed)
        #expect(throws: HTTPLifecycleError.delayOverflow) { try response(headDelay: 1, body: failed) }
    }

    @Test(arguments: [
        "null", "[]", "{}", #"[{"byteWeight":-1,"after":"0ms"}]"#,
        #"[{"byteWeight":1.5,"after":"0ms"}]"#, #"[{"byteWeight":9223372036854775808,"after":"0ms"}]"#,
        #"[{"byteWeight":1,"after":"-1ms"}]"#, #"[{"byteWeight":null,"after":"0ms"}]"#,
        #"[{"byteWeight":0}]"#, #"[{"after":"0ms"}]"#,
        #"[{"byteWeight":0,"after":null}]"#, #"[{"byteWeight":0,"after":"0ms","bytes":[]}]"#,
        #"[{"byteWeight":9223372036854775807,"after":"0ms"},{"byteWeight":1,"after":"0ms"}]"#,
        #"[{"byteWeight":0,"after":"9223372036854775807ms"},{"byteWeight":0,"after":"1ms"}]"#,
    ])
    func `malformed profiles never construct runtime values`(_ json: String) {
        #expect(throws: (any Error).self) { try decoder().decode(HTTPBodyProfile.self, from: Data(json.utf8)) }
    }

    @Test
    func `nested decoding failures preserve paths without exposing body or failure content`() throws {
        let value = try decoder().decode(Delivery.self, from: fixture("body-profile"))
        var body = try object(value)
        body["segments"] = NSNull()
        #expect(throws: (any Error).self) {
            try decoder().decode(Delivery.self, from: JSONSerialization.data(withJSONObject: body))
        }
        body["segments"] = [["byteWeight": -1, "after": "0ms"]]
        try expectCorrupt(Delivery.self, body, path: ["segments", "Index 0", "byteWeight"])
        body["segments"] = [["byteWeight": 0, "after": "9223372036854775807ms"]]
        try expectCorrupt(Delivery.self, body, path: ["segments"])
        var received = try object(response(headDelay: 0, body: Delivery(
            content: .bytes([255]), conclusion: .failed(HTTPTimed(after: delay(Int64.max), value: .timeout)))))
        var head = try #require(received["head"] as? [String: Any])
        head["after"] = "1ms"
        received["head"] = head
        try expectCorrupt(Response.self, received, path: ["body"])
        let completion: [String: Any] = [
            "after": "9223372036854775807ms", "trailers": ["after": "1ms", "fields": []],
        ]
        try expectCorrupt(HTTPBodyCompletion.self, completion, path: ["after"])
    }

    private func profile(_ weights: [Int64]) throws -> HTTPBodyProfile {
        try HTTPBodyProfile(segments: weights.map { try HTTPBodySegment(byteWeight: $0, after: delay(0)) })
    }

    private func timedProfile(_ delays: [Int64]) throws -> HTTPBodyProfile {
        try HTTPBodyProfile(segments: delays.map { try HTTPBodySegment(byteWeight: 0, after: delay($0)) })
    }

    private func delay(_ value: Int64) throws -> HTTPDelay {
        try HTTPDelay(milliseconds: .observed(value))
    }

    private func response(headDelay: Int64, body: Delivery) throws -> Response {
        try Response(head: HTTPTimed(after: delay(headDelay), value: HTTPResponseHead(head: HTTPResponse(status: .ok))),
                     body: body)
    }

    private func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    private func canonical(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(value)
        data.append(10)
        return data
    }

    private func object(_ value: some Encodable) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: canonical(value)) as? [String: Any])
    }

    private func expectCorrupt(
        _ type: (some Decodable).Type, _ object: [String: Any], path: [String],
        sourceLocation: SourceLocation = #_sourceLocation) throws
    {
        let data = try JSONSerialization.data(withJSONObject: object)
        do {
            _ = try decoder().decode(type, from: data)
            Issue.record("Invalid lifecycle was accepted", sourceLocation: sourceLocation)
        } catch let DecodingError.dataCorrupted(context) {
            #expect(context.codingPath.map(\.stringValue) == path, sourceLocation: sourceLocation)
            #expect(!context.debugDescription.contains("timeout"), sourceLocation: sourceLocation)
        }
    }

    private func decoder() -> JSONDecoder {
        HTTPResourceCodingFixtures.decoder(resources: ["bodies/edited.bin": [1, 2, 3]])
    }
}
