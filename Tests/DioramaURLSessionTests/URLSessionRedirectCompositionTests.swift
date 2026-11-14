import DioramaHTTP
import DioramaURLSession
import Foundation
import HTTPTypes
import Testing

struct URLSessionRedirectCompositionTests {
    @Test
    func `redirect continuation retains URLSession failure identity without native objects`() throws {
        let failure = try URLSessionFailure(domain: NSURLErrorDomain, code: -1007)
        let request = try HTTPRequestMessage(head: HTTPRequest(
            method: .get, scheme: "https", authority: "example.invalid", path: "/next"))
        let delay = try HTTPDelay(milliseconds: .observed(15))
        let phase = HTTPRedirectPhase(after: delay, proposedRequest: request,
                                      outcome: .followProposed(.failed(.init(after: delay, value: failure))))
        let response = try HTTPResponseNode(
            head: .init(after: delay, value: HTTPResponseHead(head: HTTPResponse(status: .found))),
            next: .redirect(phase))
        let interaction = try HTTPInteraction(initialRequest: request, result: .received(response))
        let data = try JSONEncoder().encode(interaction)
        let decoded = try JSONDecoder().decode(HTTPInteraction<URLSessionFailure>.self, from: data)
        #expect(decoded == interaction)
        let selected = try phase.continuation(for: .follow(request), requestsMatch: ==)
        guard case let .attempt(effective, .failed(timed)) = selected else {
            Issue.record("Expected followed failure continuation")
            return
        }
        #expect(effective == request)
        #expect(timed.after == delay)
        #expect((timed.value.makeError() as NSError).code == URLError.httpTooManyRedirects.rawValue)
        #expect(response.body == nil)
    }
}
