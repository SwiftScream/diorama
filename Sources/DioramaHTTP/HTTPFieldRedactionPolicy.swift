import DioramaCore
import HTTPTypes

/// Immutable field rules, including credential defaults and consumer overrides.
public struct HTTPFieldRedactionPolicy: Sendable {
    private let rules: [HTTPField.Name: HTTPFieldRedactionRule]

    /// Overlays supplied rules on the six credential defaults.
    ///
    /// Names compare case-insensitively. Each occurrence uses exactly one rule;
    /// unspecified fields remain exact. Consumers own custom-rule confidentiality.
    public init(rules: [HTTPField.Name: HTTPFieldRedactionRule] = [:]) {
        var selected: [HTTPField.Name: HTTPFieldRedactionRule] = [
            .authorization: .authorization,
            .proxyAuthorization: .authorization,
            .cookie: .cookies,
            .setCookie: .setCookie,
            .authenticationInfo: .authenticationInfo,
            .proxyAuthenticationInfo: .authenticationInfo,
        ]
        selected.merge(rules) { _, override in override }
        self.rules = selected
    }

    /// The six credential defaults without consumer overrides.
    public static let `default` = Self()

    func redact(_ fields: HTTPFields, reporter: DiagnosticReporter,
                context: DiagnosticContext) throws -> HTTPFields
    {
        var result = HTTPFields()
        for field in fields {
            guard let rule = rules[field.name] else {
                result.append(field)
                continue
            }
            let value = try HTTPFieldValue(bytes: field.withUnsafeBytesOfValue { Array($0) })
            switch try rule.redact(value) {
            case .safe: result.append(field)
            case .remove: break
            case let .replace(value):
                result.append(replacing(field, with: value))
            case let .replaceWithWarning(value):
                result.append(replacing(field, with: value))
                reporter.record(Diagnostic(
                    issue: .system(DiagnosticLabel("http.redaction.replacement-warning")),
                    context: context, fieldPath: [DiagnosticLabel("fields")]))
            }
        }
        return result
    }

    func validate(_ fields: HTTPFields) throws {
        for field in fields {
            if let rule = rules[field.name] {
                try rule.validate(HTTPFieldValue(bytes: field.withUnsafeBytesOfValue { Array($0) }))
            }
        }
    }

    private func replacing(_ field: HTTPField, with value: HTTPFieldValue) -> HTTPField {
        var result = HTTPField(name: field.name, value: value.bytes)
        result.indexingStrategy = field.indexingStrategy
        return result
    }
}
