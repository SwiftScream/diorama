import DioramaCore
import HTTPTypes

/// Opt-in recording selection, applied after preparation and before persistence.
public enum HTTPContentLength {
    /// Marks a proven request length as derived. Existing literals otherwise remain exact.
    public static func request(_ prepared: PreparedValue<HTTPRequestMessage>) -> HTTPRequestMessage {
        let message = prepared.value
        let derivesContentLength = message.derivesContentLength || (
            unambiguous(method: message.head.method) &&
                proves(message.head.headerFields, byteCount: message.body.byteCount))
        return HTTPRequestMessage(message, derivesContentLength: derivesContentLength)
    }

    /// Marks a complete response length using the effective request method.
    public static func response<Failure: Sendable>(
        _ prepared: PreparedValue<HTTPResponseNode<Failure>>,
        requestMethod: HTTPRequest.Method) throws -> HTTPResponseNode<Failure>
    {
        let response = prepared.value
        guard case .returned = response.body.conclusion,
              unambiguous(method: requestMethod),
              unambiguous(status: response.head.value.head.status.code),
              proves(response.head.value.head.headerFields, byteCount: response.body.content.byteCount)
        else { return response }
        let head = HTTPResponseHead(head: response.head.value.head, derivesContentLength: true)
        return try HTTPResponseNode(head: HTTPTimed(after: response.head.after, value: head), body: response.body)
    }

    static func unambiguous(method: HTTPRequest.Method) -> Bool {
        method != .head && method != .connect
    }

    static func unambiguous(status: Int) -> Bool {
        status >= 200 && ![204, 205, 206, 304].contains(status)
    }

    static func unambiguous(fields: HTTPFields) -> Bool {
        !fields.contains { [.contentEncoding, .transferEncoding, .contentRange].contains($0.name) }
    }

    private static func proves(_ fields: HTTPFields, byteCount: Int?) -> Bool {
        let lengths = fields.filter { $0.name == .contentLength }
        guard lengths.count == 1, let field = lengths.first, let byteCount,
              unambiguous(fields: fields) else { return false }
        let bytes = field.withUnsafeBytesOfValue { Array($0) }
        let asciiDigits = UInt8(ascii: "0")...UInt8(ascii: "9")
        // HTTP's decimal grammar permits leading zeros, but no signs or list syntax.
        return !bytes.isEmpty && bytes.allSatisfy(asciiDigits.contains) &&
            UInt64(field.value) == UInt64(byteCount)
    }
}
