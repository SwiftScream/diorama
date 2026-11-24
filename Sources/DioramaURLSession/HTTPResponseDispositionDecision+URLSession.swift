import DioramaHTTP
import Foundation

public extension HTTPResponseDispositionDecision {
    /// Converts an observed URLSession delegate answer to a stable decision.
    init(urlSessionDisposition disposition: URLSession.ResponseDisposition)
        throws(HTTPResponseDispositionError)
    {
        switch disposition {
        case .allow: self = .allow
        case .cancel: self = .cancel
        default: throw .unsupportedTransition
        }
    }
}
