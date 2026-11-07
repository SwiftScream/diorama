import DioramaCore
import HTTPTypes

/// Immutable typed HTTP preparation selected by consumer setup.
///
/// Capture and live replay inputs run redaction before normalization. Stored
/// values use `admitPrepared` on the returned policies, which validates without
/// rerunning transforms. Callers retain the original live values on failure.
public struct HTTPPreparation: Sendable {
    /// Field redaction rules, including credential defaults and consumer overrides.
    public let fieldRedaction: HTTPFieldRedactionPolicy

    /// Creates a preparation configuration.
    public init(fieldRedaction: HTTPFieldRedactionPolicy = .default) {
        self.fieldRedaction = fieldRedaction
    }

    /// Creates request preparation, including typed body and target transforms.
    ///
    /// Custom redaction runs after field rules. Normalizers
    /// receive redacted values. Final validation rejects values incompatible with field rules.
    public func request(
        reporter: DiagnosticReporter,
        context: DiagnosticContext = .scenario,
        redact: @escaping @Sendable (HTTPRequestMessage) throws -> HTTPRequestMessage = { $0 },
        normalize: @escaping @Sendable (HTTPRequestMessage) throws -> HTTPRequestMessage = { $0 },
        validate: @escaping @Sendable (HTTPRequestMessage) throws -> Void = { _ in })
        -> ValuePreparation<HTTPRequestMessage>
    {
        ValuePreparation(redact: { value in
            var head = value.head
            head.headerFields = try fieldRedaction.redact(head.headerFields, reporter: reporter, context: context)
            return try redact(HTTPRequestMessage(head: head, body: value.body))
        }, normalize: normalize, validate: { value in
            try fieldRedaction.validate(value.head.headerFields)
            try validate(value)
        })
    }

    /// Creates response-head preparation while preserving ordered repeated fields.
    public func response(
        reporter: DiagnosticReporter,
        context: DiagnosticContext = .scenario,
        redact: @escaping @Sendable (HTTPResponseHead) throws -> HTTPResponseHead = { $0 },
        normalize: @escaping @Sendable (HTTPResponseHead) throws -> HTTPResponseHead = { $0 },
        validate: @escaping @Sendable (HTTPResponseHead) throws -> Void = { _ in })
        -> ValuePreparation<HTTPResponseHead>
    {
        ValuePreparation(redact: { value in
            var head = value.head
            head.headerFields = try fieldRedaction.redact(head.headerFields, reporter: reporter, context: context)
            return try redact(HTTPResponseHead(head: head))
        }, normalize: normalize, validate: { value in
            try fieldRedaction.validate(value.head.headerFields)
            try validate(value)
        })
    }

    /// Creates typed preparation for bodies or adapter-owned stable failures.
    ///
    /// Values remain exact by default. Adapters supply their own failure model
    /// and validation; this helper does not inspect native errors or load resources.
    public func value<Value: Sendable>(
        redact: @escaping @Sendable (Value) throws -> Value = { $0 },
        normalize: @escaping @Sendable (Value) throws -> Value = { $0 },
        validate: @escaping @Sendable (Value) throws -> Void = { _ in }) -> ValuePreparation<Value>
    {
        ValuePreparation(redact: redact, normalize: normalize, validate: validate)
    }
}
