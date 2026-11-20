import DioramaCore
import DioramaHTTP
import Foundation
import HTTPTypes
import Testing

struct HTTPResponseDispositionTests {
    typealias Phase = HTTPResponseDispositionPhase<String>

    @Test
    func `canonical observed allow owns the body and selects only current allow`() throws {
        let url = try #require(Bundle.module.url(
            forResource: "disposition", withExtension: "json", subdirectory: "Fixtures"))
        let golden = try Data(contentsOf: url)
        let phase = try JSONDecoder().decode(Phase.self, from: golden)
        let body = try #require(phase.body)
        #expect(body.content == .bytes(Array("ok".utf8)))
        #expect(try phase.continuation(for: .allow) == .deliverBody(body))
        #expect(throws: HTTPResponseDispositionError.incompatibleDecision) {
            try phase.continuation(for: .cancel)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        #expect(try encoder.encode(phase) == golden)
        let response = try HTTPResponseNode(head: head(2), next: .disposition(phase))
        #expect(response.body == body)
        #expect(try JSONDecoder().decode(HTTPResponseNode<String>.self,
                                         from: encoder.encode(response)) == response)
    }

    @Test
    func `cancel owns one failure and unanswered decisions never synthesize completion`() throws {
        let failure = try HTTPTimed(after: delay(5), value: "dependency-cancellation")
        let canceled = try Phase(after: delay(2), outcome: .cancel(failure))
        #expect(canceled.body == nil)
        #expect(try canceled.continuation(for: .cancel) == .failed(failure))
        #expect(throws: HTTPResponseDispositionError.incompatibleDecision) {
            try canceled.continuation(for: .allow)
        }
        let open = try Phase(after: delay(2), outcome: .openAtRecordingHorizon)
        for decision in [HTTPResponseDispositionDecision.allow, .cancel] {
            #expect(throws: HTTPResponseDispositionError.decisionBeyondRecordingHorizon) {
                try open.continuation(for: decision)
            }
        }
        for phase in [canceled, open] {
            #expect(try JSONDecoder().decode(Phase.self, from: JSONEncoder().encode(phase)) == phase)
        }
    }

    @Test
    func `decision anchors separate body timing and retain failed and open prefixes`() throws {
        let maximum = try delay(Int64.max)
        for conclusion in try [
            HTTPBodyConclusion<String>.openAtRecordingHorizon,
            .failed(HTTPTimed(after: maximum, value: "failure")),
            .returned(HTTPBodyCompletion(after: maximum)),
        ] {
            let body = HTTPBodyDelivery(content: .bytes([1, 2]), conclusion: conclusion)
            let phase = Phase(after: maximum, outcome: .allow(body))
            #expect(try phase.continuation(for: .allow) == .deliverBody(body))
            #expect(throws: HTTPLifecycleError.delayOverflow) {
                try HTTPResponseNode(head: head(1), next: .disposition(phase))
            }
            let response = try HTTPResponseNode(head: head(0), next: .disposition(phase))
            #expect(response.body == body)
        }
    }

    @Test
    func `ordinary body delivery encodes without a disposition`() throws {
        let body = HTTPBodyDelivery<String>(content: .absent, conclusion: .openAtRecordingHorizon)
        let ordinary = try HTTPResponseNode(head: head(0), body: body)
        let json = try JSONEncoder().encode(ordinary)
        #expect(try !#require(String(data: json, encoding: .utf8)).contains("disposition"))
    }

    @Test(arguments: [
        #"{}"#,
        #"{"after":null,"outcome":{"kind":"open"}}"#,
        #"{"after":"-1ms","outcome":{"kind":"open"}}"#,
        #"{"after":"0ms","outcome":{"kind":"allow"}}"#,
        #"{"after":"0ms","outcome":{"kind":"cancel","failure":null}}"#,
        #"{"after":"0ms","outcome":{"kind":"open","body":{}}}"#,
        #"{"after":"0ms","outcome":{"kind":"cancel","failure":{"after":"0ms","value":"cancel"},"body":{}}}"#,
        #"{"after":"0ms","outcome":{"kind":"secret-marker"}}"#,
        #"{"after":"0ms","outcome":{"kind":"becomeDownload"}}"#,
        #"{"after":"0ms","outcome":{"kind":"becomeStream"}}"#,
        #"{"after":"0ms","outcome":{"kind":"open"},"decisionLatency":"2ms"}"#,
    ])
    func `strict schema rejects unsupported conflicting missing and null fields`(_ json: String) throws {
        do {
            _ = try JSONDecoder().decode(Phase.self, from: Data(json.utf8))
            Issue.record("Invalid disposition accepted")
        } catch {
            #expect(!String(describing: error).contains("secret-marker"))
        }
    }

    @Test
    func `allowed resources retain derived lengths and effective method validation`() throws {
        let resource = try HTTPResourceCodingFixtures.resource(path: "allowed.bin", bytes: [1, 2, 3])
        let body = try HTTPBodyDelivery<String>(content: .resource(resource),
                                                conclusion: .returned(.init(after: delay(4))))
        let phase = try Phase(after: delay(2), outcome: .allow(body))
        let response = try HTTPResponseNode(head: .init(after: delay(1), value: HTTPResponseHead(head: HTTPResponse(
            status: .ok, headerFields: HTTPFields([.init(name: .contentLength, value: "3")])))),
        next: .disposition(phase))
        let derived = try HTTPContentLength.response(ValuePreparation().admitPrepared(response), requestMethod: .get)
        let edited = try HTTPResourceCodingFixtures.decoder(resources: ["allowed.bin": [4, 5, 6, 7]])
            .decode(HTTPResponseNode<String>.self, from: JSONEncoder().encode(derived))
        #expect(edited.head.value.head.headerFields[.contentLength] == "4")
        for method in [HTTPRequest.Method.head, .connect] {
            let request = try HTTPRequestMessage(head: HTTPRequest(
                method: method, scheme: "https", authority: "example.invalid", path: "/"), body: .absent)
            #expect(throws: HTTPMessageError.invalidField) {
                try HTTPInteraction(initialRequest: request, result: .received(edited))
            }
        }
        let canceled = try Phase(after: delay(2), outcome: .cancel(.init(after: delay(0), value: "cancel")))
        #expect(throws: HTTPMessageError.invalidField) {
            try HTTPResponseNode(head: derived.head, next: .disposition(canceled))
        }
    }

    private func delay(_ value: Int64) throws -> HTTPDelay {
        try HTTPDelay(milliseconds: .observed(value))
    }

    private func head(_ after: Int64) throws -> HTTPTimed<HTTPResponseHead> {
        try HTTPTimed(after: delay(after), value: HTTPResponseHead(head: HTTPResponse(status: .ok)))
    }
}
