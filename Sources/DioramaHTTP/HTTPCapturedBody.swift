import DioramaCore
import HTTPTypes

struct HTTPCapturedBody: Sendable {
    private enum Content: Sendable {
        case pending, whole(HTTPResponseBody), segmented
    }

    private var content = Content.pending
    private var bytes: [UInt8] = []
    private var segments: [HTTPBodySegment] = []
    var trailers: HTTPTrailers?

    mutating func append(_ chunk: [UInt8], delay: HTTPDelay) throws {
        guard trailers == nil else { throw HTTPRecordingError.incompatibleObservation }
        if case .whole = content {
            throw HTTPRecordingError.incompatibleObservation
        }
        content = .segmented
        bytes.append(contentsOf: chunk)
        try segments.append(HTTPBodySegment(byteWeight: Int64(chunk.count), after: delay))
    }

    mutating func setContent(_ value: HTTPResponseBody) throws {
        guard case .pending = content, trailers == nil else { throw HTTPRecordingError.incompatibleObservation }
        content = .whole(value)
    }

    func delivery<Failure>(head: HTTPResponseHead, conclusion: HTTPBodyConclusion<Failure>,
                           storage: HTTPBodyStoragePolicy, stem: String) throws -> HTTPBodyDelivery<Failure>
    {
        if trailers != nil {
            guard case .returned = conclusion else { throw HTTPRecordingError.incompatibleObservation }
        }
        let value: HTTPResponseBody = switch content {
        case .pending: .absent
        case let .whole(value): value
        case .segmented: .bytes(bytes)
        }
        let selected = try storage.response(ValuePreparation().admitPrepared(value),
                                            head: ValuePreparation().admitPrepared(head), resourceStem: stem)
        guard !segments.isEmpty else { return HTTPBodyDelivery(content: selected, conclusion: conclusion) }
        return try HTTPBodyDelivery(content: selected, profile: HTTPBodyProfile(segments: segments),
                                    conclusion: conclusion)
    }
}

extension HTTPInteractionBuilder {
    private func bodyContext() throws -> (Response, BodyEdge) {
        switch phase {
        case let .body(response, edge): (response, edge)
        case let .head(response): (response, { try response.finish(.deliverBody($0)) })
        case let .refused(response, edge): (response, { try edge(.deliverBody($0)) })
        case let .nativeHandling(response, edge): (response, { try edge(.deliverBody($0)) })
        default: throw HTTPRecordingError.incompatibleObservation
        }
    }

    func conclude(_ conclusion: HTTPBodyConclusion<Failure>) throws -> Result {
        let (response, edge) = try bodyContext()
        return try edge(body.delivery(head: response.head.value, conclusion: conclusion,
                                      storage: storage, stem: resourceStem("response")))
    }

    mutating func observeBody(_ event: HTTPCaptureEvent<Failure>, delay: HTTPDelay) throws -> Bool {
        if case let .failed(value) = event {
            let failure = HTTPTimed(after: delay, value: value)
            try fail(failure)
        } else {
            let (response, edge) = try bodyContext()
            phase = .body(response, edge)
            switch event {
            case let .segment(bytes): try body.append(bytes, delay: delay)
            case let .content(value):
                try body.setContent(value)
                return false
            case let .trailers(fields):
                guard body.trailers == nil else { throw HTTPRecordingError.incompatibleObservation }
                body.trailers = HTTPTrailers(after: delay, fields: fields)
            case .returned:
                phase = try .ended(conclude(.returned(HTTPBodyCompletion(after: delay, trailers: body.trailers))))
            default: throw HTTPRecordingError.incompatibleObservation
            }
        }
        if case .ended = phase {
            body = HTTPCapturedBody()
        }
        return true
    }

    private mutating func fail(_ failure: HTTPTimed<Failure>) throws {
        switch phase {
        case .attempt: phase = .ended(.failed(failure))
        case let .canceled(edge): phase = try .ended(edge(failure))
        case let .nativeHandling(_, edge): phase = try .ended(edge(.failed(failure)))
        default: phase = try .ended(conclude(.failed(failure)))
        }
    }
}
