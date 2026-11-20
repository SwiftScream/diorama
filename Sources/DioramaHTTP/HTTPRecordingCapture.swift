import DioramaCore

/// An execution-local operation identity. Only the originating capture can resolve its observations.
public final class HTTPCaptureOperation: Sendable {
    /// Core's reserved track position.
    public let identity: RecordIdentity

    fileprivate init(_ identity: RecordIdentity) {
        self.identity = identity
    }

    /// Reservation made at invocation, before preparing the initial request.
    public var initial: HTTPCaptureReservation {
        .init(operation: self, index: 0)
    }
}

/// One observation's position, reserved before conversion. Complete it exactly once.
public struct HTTPCaptureReservation: Sendable {
    fileprivate let operation: HTTPCaptureOperation
    fileprivate let index: Int
}

/// A safe capture failure without observed values or underlying error descriptions.
public enum HTTPRecordingError: Error {
    /// The operation or reservation is missing, stale, or already completed.
    case invalidReservation
    /// An observation belongs to a different attempt.
    case wrongAttempt
    /// An observation is incompatible with the current phase.
    case incompatibleObservation
    /// A logical timestamp cannot be represented by the recording schema.
    case invalidTime

    var issue: DiagnosticIssue {
        switch self {
        case .invalidReservation: .system(DiagnosticLabel("http.capture.invalid-reservation"))
        case .wrongAttempt: .system(DiagnosticLabel("http.capture.wrong-attempt"))
        case .incompatibleObservation: .system(DiagnosticLabel("http.capture.incompatible-observation"))
        case .invalidTime: .conversionFailed
        }
    }
}

/// HTTP recording state embedded in a concrete system's Core-protected record mode state.
public struct HTTPRecordingCapture<Failure: Sendable>: Sendable {
    private let storage: HTTPBodyStoragePolicy
    private let preparation: ValuePreparation<HTTPInteraction<Failure>>
    private var drafts: [ObjectIdentifier: Draft] = [:]

    /// Selects storage for every newly captured request, response, and partial prefix.
    /// Core applies only the final validation stage of the interaction policy at freeze.
    public init(storage: HTTPBodyStoragePolicy = .default,
                preparation: ValuePreparation<HTTPInteraction<Failure>> = .init())
    {
        self.preparation = preparation
        self.storage = storage
    }

    /// Reserves the record and its invocation time before request conversion. The stem must be
    /// unique to this operation in its scenario, and is used only for newly selected resources.
    public static func begin<State: Sendable>(
        in state: inout State, at path: WritableKeyPath<State, Self> & Sendable,
        on lease: SequentialTrackLease<HTTPInteraction<Failure>, some Sendable>,
        resourceStem: (RecordIdentity) -> String, operation: inout SystemOperation<State>) throws
        -> HTTPCaptureOperation
    {
        let preparation = state[keyPath: path].preparation
        return try operation.beginRecord(on: lease, preparation: preparation, capturing: { identity in
            let handle = HTTPCaptureOperation(identity)
            let start = try milliseconds(operation.time)
            state[keyPath: path].drafts[ObjectIdentifier(handle)] = Draft(
                builder: HTTPInteractionBuilder(stem: resourceStem(identity), storage: state[keyPath: path].storage),
                slots: [0: Slot(attempt: 0, time: start)])
            return handle
        }, finalizing: { state, handle in
            guard let draft = state[keyPath: path].drafts.removeValue(forKey: ObjectIdentifier(handle)) else {
                return .notAdmitted
            }
            return draft.freeze()
        })
    }

    /// Reserves observation order and time. Number attempts from zero, advancing on each retry or follow.
    public mutating func reserve(
        _ handle: HTTPCaptureOperation, attempt: Int, operation: inout SystemOperation<some Sendable>) throws
        -> HTTPCaptureReservation
    {
        let key = ObjectIdentifier(handle)
        do {
            guard let first = drafts[key]?.first, let count = drafts[key]?.slots.count else {
                throw HTTPRecordingError.invalidReservation
            }
            let time = try Self.milliseconds(operation.time)
            drafts[key]?.slots[first + count] = Slot(attempt: attempt, time: time)
            return HTTPCaptureReservation(operation: handle, index: first + count)
        } catch {
            reject(handle, issue: (error as? HTTPRecordingError)?.issue ?? .conversionFailed, operation: &operation)
            throw error
        }
    }

    /// Commits prepared observations in reservation order, independent of conversion completion order.
    public mutating func complete(
        _ reservation: HTTPCaptureReservation, with event: PreparedValue<HTTPCaptureEvent<Failure>>,
        operation: inout SystemOperation<some Sendable>) throws
    {
        let key = ObjectIdentifier(reservation.operation)
        do {
            guard drafts[key]?.slots[reservation.index]?.event == nil,
                  drafts[key]?.slots[reservation.index] != nil else { throw HTTPRecordingError.invalidReservation }
            drafts[key]?.slots[reservation.index]?.event = event.value
            try drafts[key]?.drain()
        } catch {
            reject(reservation.operation, issue: (error as? HTTPRecordingError)?.issue ?? .conversionFailed,
                   operation: &operation)
            throw error
        }
    }

    /// Rejects publication after conversion fails. Pass the failure from recording preparation
    /// when it already reported the cause in the current execution. Only safe evidence is retained.
    public mutating func invalidate(
        _ handle: HTTPCaptureOperation, after failure: PreparationFailure? = nil,
        operation: inout SystemOperation<some Sendable>)
    {
        if let evidence = failure?.diagnostic, evidence.recordingImpact == .invalidatesCandidate,
           evidence.context == .record(handle.identity)
        {
            drafts.removeValue(forKey: ObjectIdentifier(handle))
            return
        }
        reject(handle, issue: failure?.diagnostic.issue ?? .conversionFailed, operation: &operation)
    }

    private mutating func reject(
        _ handle: HTTPCaptureOperation, issue: DiagnosticIssue, operation: inout SystemOperation<some Sendable>)
    {
        drafts.removeValue(forKey: ObjectIdentifier(handle))
        operation.report(Diagnostic(issue: issue, context: .record(handle.identity),
                                    recordingImpact: .invalidatesCandidate))
    }

    private struct Slot: Sendable {
        let attempt: Int
        let time: Int64
        var event: HTTPCaptureEvent<Failure>?
    }

    private struct Draft: Sendable {
        var builder: HTTPInteractionBuilder<Failure>
        var slots: [Int: Slot]
        var first = 0

        mutating func drain() throws {
            while let slot = slots[first], let event = slot.event {
                try builder.observe(event, attempt: slot.attempt, time: slot.time)
                slots.removeValue(forKey: first)
                first += 1
            }
        }

        func freeze() -> RecordFreeze<HTTPInteraction<Failure>> {
            guard slots.isEmpty else {
                return .rejected(.system(DiagnosticLabel("http.capture.pending-preparation")))
            }
            guard !builder.isAwaitingCompletion else {
                return .rejected(.system(DiagnosticLabel("http.capture.missing-completion")))
            }
            do {
                return try .captured(builder.freeze())
            } catch {
                return .rejected((error as? HTTPRecordingError)?.issue ?? .conversionFailed)
            }
        }
    }

    private static func milliseconds(_ time: ExecutionTime) throws -> Int64 {
        let components = try time.logicalTime(at: time.capture()).components
        let (whole, overflow) = components.seconds.multipliedReportingOverflow(by: 1000)
        let fraction = (components.attoseconds + 500_000_000_000_000) / 1_000_000_000_000_000
        let (result, sumOverflow) = whole.addingReportingOverflow(fraction)
        guard !overflow, !sumOverflow, result >= 0 else { throw HTTPRecordingError.invalidTime }
        return result
    }
}
