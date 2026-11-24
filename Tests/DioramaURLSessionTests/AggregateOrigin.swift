import Foundation
import Network
import Synchronization
import Testing

/// A loopback HTTP/1.1 echo server for bounded, Content-Length-framed requests.
final class AggregateOrigin: Sendable {
    struct Request: Sendable {
        let line: String
        let fields: [String: String]
        let body: Data
    }

    struct Observations: Sendable {
        var connections = 0
        var requests: [Request] = []
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "DioramaTests.AggregateOrigin")
    let observations = Mutex(Observations())

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    deinit {
        listener.cancel()
    }

    func start() async throws -> URL {
        let readiness = AsyncThrowingStream<Void, any Error>.makeStream()
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: readiness.continuation.finish()
            case let .failed(error): readiness.continuation.finish(throwing: error)
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            observations.withLock { $0.connections += 1 }
            connection.start(queue: queue)
            receive(connection, buffer: Data())
        }
        listener.start(queue: queue)
        for try await _ in readiness.stream {}
        let port = try #require(listener.port)
        return try #require(URL(string: "http://127.0.0.1:\(port.rawValue)/echo"))
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, eof, error in
            guard let self, error == nil else { connection.cancel(); return }
            let bytes = buffer + (data ?? Data())
            if let request = Self.parse(bytes) {
                observations.withLock { $0.requests.append(request) }
                respond(to: request, on: connection)
            } else if eof || bytes.count > 8192 {
                connection.cancel()
            } else {
                receive(connection, buffer: bytes)
            }
        }
    }

    private static func parse(_ bytes: Data) -> Request? {
        guard let split = bytes.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: bytes[..<split.lowerBound], encoding: .utf8)
        else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        var fields: [String: String] = [:]
        for line in lines.dropFirst() {
            if let colon = line.firstIndex(of: ":") {
                fields[line[..<colon].lowercased()] = line[line.index(after: colon)...]
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        let body = bytes[split.upperBound...]
        guard body.count == (fields["content-length"].flatMap(Int.init) ?? 0) else { return nil }
        return Request(line: lines[0], fields: fields, body: Data(body))
    }

    private func respond(to request: Request, on connection: NWConnection) {
        let type = request.fields["content-type"] ?? "application/octet-stream"
        let encoding = type == "application/json" ? "" : "Content-Encoding: identity\r\n"
        let head = "HTTP/1.1 200 OK\r\nConnection: close\r\n"
            + "Content-Type: \(type)\r\nContent-Length: \(request.body.count)\r\n\(encoding)\r\n"
        connection.send(content: Data(head.utf8) + request.body, isComplete: true,
                        completion: .contentProcessed { _ in connection.cancel() })
    }
}
