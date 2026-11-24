import DioramaHTTP
import DioramaURLSession
import Foundation
import Testing

struct URLSessionResponseDispositionTests {
    @Test
    func `native answers convert without callbacks and unsupported transitions fail`() throws {
        #expect(try HTTPResponseDispositionDecision(urlSessionDisposition: .allow) == .allow)
        #expect(try HTTPResponseDispositionDecision(urlSessionDisposition: .cancel) == .cancel)
        #expect(throws: HTTPResponseDispositionError.unsupportedTransition) {
            try HTTPResponseDispositionDecision(urlSessionDisposition: .becomeDownload)
        }
        #expect(throws: HTTPResponseDispositionError.unsupportedTransition) {
            try HTTPResponseDispositionDecision(urlSessionDisposition: .becomeStream)
        }
    }
}
