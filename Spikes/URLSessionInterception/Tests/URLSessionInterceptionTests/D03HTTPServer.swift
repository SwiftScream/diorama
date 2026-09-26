import Foundation
#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

struct D03WireRequest {
    let target: String
    let method: String
    let headers: [String: String]
    let body: Data
}

struct D03HTTPReply {
    var status = 200
    var location: String?
    var body = "final"

    var wire: Data {
        let location = location.map { "Location: \($0)\r\n" } ?? ""
        return Data(("HTTP/1.1 \(status) Probe\r\n\(location)" +
                "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)").utf8)
    }
}

/// Test-task-owned, nonblocking loopback fixture. Each response closes its
/// connection so the next redirect attempt is observable as a new request.
/// This intentionally supports only Content-Length requests used by D03.
final class D03HTTPServer {
    let listener: D02LoopbackListener
    private var connection: Int32 = -1
    private var buffer = Data()
    private(set) var requests: [D03WireRequest] = []
    private(set) var sendsSucceeded = true

    init() throws {
        listener = try D02LoopbackListener()
    }

    deinit {
        if connection >= 0 {
            close(connection)
        }
    }

    func url(_ path: String = "/start", host: String = "127.0.0.1") -> URL {
        URL(string: "http://\(host):\(listener.port)\(path)")!
    }

    func poll(_ reply: (D03WireRequest) -> D03HTTPReply) {
        if connection < 0 {
            connection = accept(listener.descriptor, nil, nil)
            guard connection >= 0 else { return }
            _ = fcntl(connection, F_SETFL, O_NONBLOCK)
            #if canImport(Darwin)
                var enabled: Int32 = 1
                _ = setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
            #endif
        }
        var bytes = [UInt8](repeating: 0, count: 4096)
        let count = recv(connection, &bytes, bytes.count, 0)
        if count > 0 {
            buffer.append(contentsOf: bytes.prefix(count))
        }
        guard let request = parsedRequest() else { return }
        requests.append(request)
        let response = reply(request).wire
        #if canImport(Darwin)
            let flags: Int32 = 0
        #else
            let flags = Int32(MSG_NOSIGNAL)
        #endif
        let written = response.withUnsafeBytes { bytes in
            #if canImport(Darwin)
                Darwin.send(connection, bytes.baseAddress, bytes.count, flags)
            #else
                Glibc.send(connection, bytes.baseAddress, bytes.count, flags)
            #endif
        }
        sendsSucceeded = sendsSucceeded && written == response.count
        close(connection)
        connection = -1
        buffer = Data()
    }

    private func parsedRequest() -> D03WireRequest? {
        guard let boundary = buffer.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: buffer[..<boundary.lowerBound], encoding: .utf8)
        else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines[0].split(separator: " ")
        guard requestLine.count == 3 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            let pair = line.split(separator: ":", maxSplits: 1)
            guard pair.count == 2 else { continue }
            headers[pair[0].lowercased()] = pair[1].trimmingCharacters(in: .whitespaces)
        }
        let body = Data(buffer[boundary.upperBound...])
        guard body.count == Int(headers["content-length"] ?? "0") else { return nil }
        return D03WireRequest(target: String(requestLine[1]), method: String(requestLine[0]),
                              headers: headers, body: body)
    }
}
