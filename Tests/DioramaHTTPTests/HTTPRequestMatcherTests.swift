@testable import DioramaCore
import DioramaHTTP
import HTTPTypes
import Testing

struct HTTPRequestMatcherTests {
    private func request(
        _ fields: [(String, String)] = [], path: String = "/items?a=1&b=2",
        body: HTTPRequestBody = .absent) throws -> PreparedValue<HTTPRequestMessage>
    {
        var headers = HTTPFields()
        for (name, value) in fields {
            try headers.append(HTTPField(name: #require(HTTPField.Name(name)), value: value))
        }
        let value = try HTTPRequestMessage(head: HTTPRequest(
            method: .get, scheme: "https", authority: "example.test", path: path, headerFields: headers), body: body)
        return try ValuePreparation<HTTPRequestMessage>().admitPrepared(value)
    }

    @Test
    func `field names ignore case and interleaving but preserve repeated order`() throws {
        let matcher = HTTPRequestMatcher()
        let lhs = try matcher.project(request([("X-Mode", "a"), ("Accept", "text/plain"), ("x-mode", "b")]))
        let rhs = try matcher.project(request([("X-MODE", "a"), ("x-mode", "b"), ("accept", "text/plain")]))
        #expect(matcher.matches(lhs, rhs))
        let reordered = try matcher.project(request([("X-Mode", "b"), ("Accept", "text/plain"), ("X-Mode", "a")]))
        #expect(matcher.differences(lhs, reordered) == [.fields])
    }

    @Test(arguments: [
        "Host", "Content-Length", "Connection", "Keep-Alive", "Proxy-Connection",
        "Transfer-Encoding", "User-Agent",
    ])
    func `default exclusions can each be opted back in`(_ field: String) throws {
        let name = try #require(HTTPField.Name(field))
        let lhs = try request([(field, "one")])
        let rhs = try request([(field, "two")])
        let standard = HTTPRequestMatcher()
        #expect(try standard.matches(standard.project(lhs), standard.project(rhs)))
        let included = HTTPRequestMatcher(fields: .excluding(HTTPMatchFields.defaultExclusions.subtracting([name])))
        #expect(try included.differences(included.project(lhs), included.project(rhs)) == [.fields])
    }

    @Test(arguments: [
        "Accept", "Content-Type", "Accept-Language", "Content-Encoding", "Range",
        "If-None-Match", "Authorization", "Cookie", "X-API-Version",
    ])
    func `meaningful fields participate unless configured otherwise`(_ field: String) throws {
        let name = try #require(HTTPField.Name(field))
        let lhs = try request([(field, "fixture-one")])
        let rhs = try request([(field, "fixture-two")])
        let standard = HTTPRequestMatcher()
        #expect(try !standard.matches(standard.project(lhs), standard.project(rhs)))
        let excluded = HTTPRequestMatcher(fields: .excluding(HTTPMatchFields.defaultExclusions.union([name])))
        #expect(try excluded.matches(excluded.project(lhs), excluded.project(rhs)))
        let strict = HTTPRequestMatcher(fields: .including([.accept]))
        #expect(try strict.matches(strict.project(lhs), strict.project(rhs)) == (name != .accept))
    }

    @Test(arguments: [
        HTTPMatchFields.including([.userAgent]), .excluding([.accept]), .excluding([]),
    ])
    func `explicit field selections do not inherit default exclusions`(_ fields: HTTPMatchFields) throws {
        let matcher = HTTPRequestMatcher(fields: fields)
        let lhs = try matcher.project(request([("User-Agent", "one")]))
        let rhs = try matcher.project(request([("User-Agent", "two")]))
        #expect(matcher.differences(lhs, rhs) == [.fields])
    }

    @Test
    func `empty inclusion ignores all fields and empty exclusion matches all fields`() throws {
        let lhs = try request([("Accept", "text/plain"), ("User-Agent", "one")])
        let rhs = try request([("Accept", "application/json"), ("User-Agent", "two")])
        let including = HTTPRequestMatcher(fields: .including([]))
        #expect(try including.matches(including.project(lhs), including.project(rhs)))
        let excluding = HTTPRequestMatcher(fields: .excluding([]))
        #expect(try excluding.differences(excluding.project(lhs), excluding.project(rhs)) == [.fields])
    }

    @Test
    func `bodies compare bytes independent of resource paths and preserve presence`() throws {
        let matcher = HTTPRequestMatcher()
        let absent = try matcher.project(request())
        let empty = try matcher.project(request(body: .bytes([])))
        #expect(matcher.differences(absent, empty) == [.body])
        let inline = try matcher.project(request(body: .bytes([0, 255, 42])))
        for path in ["body/a", "body/b"] {
            let resource = try request(body: .resource(HTTPBodyResource(path: path)))
            let resolved = try matcher.project(resource) { _ in [0, 255, 42] }
            #expect(matcher.matches(inline, resolved))
            #expect(throws: HTTPMatchProjectionError.resourceUnavailable) { try matcher.project(resource) }
            #expect(throws: HTTPMatchProjectionError.resourceUnavailable) {
                try matcher.project(resource) { _ in throw HTTPMessageError.invalidBody }
            }
        }
        let changed = try matcher.project(request(body: .bytes([0, 255, 43])))
        #expect(matcher.differences(inline, changed) == [.body])
        let reordered = try matcher.project(request(path: "/items?b=2&a=1"))
        #expect(matcher.differences(absent, reordered) == [.path])
    }

    @Test
    func `method scheme authority and opaque field bytes compare literally`() throws {
        let matcher = HTTPRequestMatcher()
        let base = try request()
        let original = try matcher.project(base)
        for (head, difference) in [
            (HTTPRequest(method: .post, scheme: "https", authority: "example.test", path: base.value.head.path),
             HTTPRequestDifference.method),
            (HTTPRequest(method: .get, scheme: "http", authority: "example.test", path: base.value.head.path), .scheme),
            (HTTPRequest(method: .get, scheme: "https", authority: "other.test", path: base.value.head.path),
             .authority),
        ] {
            let changed = try ValuePreparation<HTTPRequestMessage>().admitPrepared(HTTPRequestMessage(head: head))
            #expect(try matcher.differences(original, matcher.project(changed)) == [difference])
        }
        var first = base.value.head
        first.headerFields.append(HTTPField(name: .accept, value: [0xFF]))
        var second = base.value.head
        second.headerFields.append(HTTPField(name: .accept, value: [0xFE]))
        let policy = ValuePreparation<HTTPRequestMessage>()
        let lhs = try matcher.project(policy.admitPrepared(HTTPRequestMessage(head: first)))
        let rhs = try matcher.project(policy.admitPrepared(HTTPRequestMessage(head: second)))
        #expect(matcher.differences(lhs, rhs) == [.fields])
    }

    @Test
    func `credential preparation precedes projection without changing originals`() throws {
        let reporter = try DiagnosticReporter(
            scenarioID: ScenarioID(rawValue: "http-preparation"), definition: ScenarioDefinition())
        let policy = HTTPPreparation().request(reporter: reporter)
        let matcher = HTTPRequestMatcher()
        let first = try request([("Authorization", "Bearer secret-marker-one")]).value
        let second = try request([("Authorization", "Bearer secret-marker-two")]).value
        let lhs = try matcher.project(policy.prepare(capturing: { first }, purpose: .recording, reporter: reporter))
        let rhs = try matcher.project(policy.prepare(capturing: { second }, purpose: .replay, reporter: reporter))
        #expect(matcher.matches(lhs, rhs))
        #expect(lhs.fields[.authorization] == [Array("Bearer redacted".utf8)])
        #expect(first.head.headerFields.first?.value == "Bearer secret-marker-one")
        #expect(matcher.differences(lhs, rhs).isEmpty)
    }

    @Test
    func `typed custom comparison controls equivalence and safe component differences`() throws {
        let matcher = HTTPRequestMatcher(matches: { $0.method == $1.method })
        let lhs = try matcher.project(request(path: "/one"))
        let rhs = try matcher.project(request(path: "/two"))
        #expect(matcher.matches(lhs, rhs))
        #expect(matcher.differences(lhs, rhs).isEmpty)
        let rejecting = HTTPRequestMatcher(matches: { _, _ in false })
        #expect(rejecting.differences(lhs, lhs) == [.custom])
    }

    @Test
    func `selector reorders claims advances equivalents and retains safe exhaustion and miss facts`() async throws {
        let matcher = HTTPRequestMatcher()
        let one = try matcher.project(request(path: "/secret-marker-one"))
        let two = try matcher.project(request(path: "/secret-marker-two"))
        let type = ScenarioSystemType("http-matcher")
        let attachmentID = AttachmentID(systemTypeID: type.id, key: AttachmentKey(rawValue: "client"))
        let trackID = TrackID(attachmentID: attachmentID, key: TrackKey(rawValue: "requests"))
        let policy = ValuePreparation<HTTPRequestMatchProjection>()
        let attachment = try ScenarioAttachment(id: attachmentID).adding(SequentialTrack(
            id: trackID, values: [one, two, one].map { try policy.admitPrepared($0) }))
        let system = try ScenarioSystem(type: type, attachment: attachment) { context in
            let lease = try context.lease(for: trackID, preparation: policy)
            return PreparedSystem { ActivatedSystem(dependency: lease, deactivate: {}) }
        }
        let execution = try await ScenarioExecution.start(
            definition: ScenarioDefinition(attachments: [attachment]),
            scenarioID: ScenarioID(rawValue: "http-match"), defaultMode: .replay,
            systems: [AnyScenarioSystem(system)])
        let lease = try execution.dependency(system)
        let selector = matcher.selector(recordedInput: { $0 })
        #expect(try lease.claim(matching: two, using: selector).record.identity.sequence == 1)
        #expect(try lease.claim(matching: one, using: selector).record.identity.sequence == 0)
        #expect(try lease.claim(matching: one, using: selector).record.identity.sequence == 2)
        #expect(throws: SequentialOperationFailure.self) { try lease.claim(matching: one, using: selector) }
        let miss = try matcher.project(request(path: "/secret-marker-miss"))
        #expect(throws: SequentialOperationFailure.self) { try lease.claim(matching: miss, using: selector) }
        let ambiguous = ReplaySelector<HTTPRequestMatchProjection, HTTPRequestMatchProjection>(
            rule: DiagnosticLabel("http.custom"), select: { _, records in .ambiguous(records.map(\.identity)) })
        #expect(throws: SequentialOperationFailure.self) { try lease.claim(matching: one, using: ambiguous) }
        let result = await execution.finish()
        let rendered = result.rendered()
        #expect(!rendered.contains("secret-marker"))
        #expect(rendered.contains("http.request.path"))
        #expect(result.report.diagnostics.map(\.diagnostic.issue) == [
            .sequential(.selection(.exhausted([0, 2].map { RecordIdentity(trackID: trackID, sequence: $0) }))),
            .sequential(.selection(.noMatch)),
            .sequential(.selection(.ambiguous([0, 1, 2].map { RecordIdentity(trackID: trackID, sequence: $0) }))),
        ])
    }
}
