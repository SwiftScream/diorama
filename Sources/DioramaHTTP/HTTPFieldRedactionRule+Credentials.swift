import Foundation
import HTTPTypes

public extension HTTPFieldRedactionRule {
    /// Safe Basic, Bearer, and Digest substitutes, with a warned fallback for other schemes.
    static let authorization = credential(CredentialSubstitutes.authorization)
    /// Replaces each cookie value while retaining supported names and order.
    static let cookies = credential(CredentialSubstitutes.cookies)
    /// Replaces a response cookie value while retaining supported attributes.
    static let setCookie = credential(CredentialSubstitutes.setCookie)
    /// Replaces authentication information with a safe nextnonce parameter.
    static let authenticationInfo = credential(CredentialSubstitutes.authenticationInfo)

    private static func credential(
        _ substitute: @escaping @Sendable (String) -> (value: String, fallback: Bool)) -> Self
    {
        Self(redact: { value in
            let replacement = substitute(value.text ?? "")
            let result = try HTTPFieldValue(replacement.value)
            if replacement.fallback {
                return .replaceWithWarning(result)
            }
            return result == value ? .safe : .replace(result)
        }, validate: { value in
            // Share the deterministic substitute invariant, never a consumer transform.
            let expected = try HTTPFieldValue(substitute(value.text ?? "").value)
            guard value == expected else { throw HTTPMessageError.invalidField }
        })
    }
}

private enum CredentialSubstitutes {
    static func cookies(_ value: String) -> (value: String, fallback: Bool) {
        let pairs = value.split(separator: ";", omittingEmptySubsequences: false)
        var values: [String] = []
        for pair in pairs {
            guard let name = cookieName(String(pair)) else { return ("redacted=redacted", true) }
            values.append("\(name)=redacted")
        }
        return (values.joined(separator: "; "), false)
    }

    static func authenticationInfo(_ value: String) -> (value: String, fallback: Bool) {
        (#"nextnonce="redacted""#, !validParameters(value))
    }

    static func authorization(_ value: String) -> (value: String, fallback: Bool) {
        let parts = value.split(separator: " ", maxSplits: 1)
        guard parts.count == 2 else { return ("Bearer redacted", true) }
        switch parts[0].lowercased() {
        case "basic":
            let data = Data(base64Encoded: String(parts[1]))
            return ("Basic cmVkYWN0ZWQ6cmVkYWN0ZWQ=", data?.contains(58) != true)
        case "bearer":
            return ("Bearer redacted", !matches(String(parts[1]), #"[A-Za-z0-9._~+/\-]+=*"#))
        case "digest":
            let replacement = #"Digest username="redacted", realm="redacted", nonce="redacted", "#
                + #"uri="/", response="00000000000000000000000000000000""#
            return (replacement, !validParameters(String(parts[1])))
        default: return ("Bearer redacted", true)
        }
    }

    static func setCookie(_ value: String) -> (value: String, fallback: Bool) {
        let parts = value.split(separator: ";", omittingEmptySubsequences: false)
        guard let first = parts.first, let name = cookieName(String(first)) else {
            return ("redacted=redacted", true)
        }
        // Retain only recognized attributes; unknown extension values may carry credentials.
        var attributes: [String] = []
        for part in parts.dropFirst() {
            let attribute = part.trimmingCharacters(in: .whitespaces)
            let key = attribute.split(separator: "=", maxSplits: 1).first?.lowercased() ?? ""
            guard validAttribute(attribute, key: key)
            else { return ("redacted=redacted", true) }
            attributes.append(attribute)
        }
        return ((["\(name)=redacted"] + attributes).joined(separator: "; "), false)
    }

    static func validAttribute(_ attribute: String, key: String) -> Bool {
        let parts = attribute.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        if ["secure", "httponly", "partitioned"].contains(key) {
            return parts.count == 1
        }
        guard parts.count == 2 else { return false }
        let value = String(parts[1])
        switch key {
        case "samesite": return ["strict", "lax", "none"].contains(value.lowercased())
        case "max-age": return matches(value, "-?[0-9]+")
        case "domain": return matches(value, #"\.?[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*"#)
        case "path": return value.hasPrefix("/") && !value.contains(",")
        case "expires":
            return matches(value, #"[A-Za-z]{3}, [0-9]{2} [A-Za-z]{3} [0-9]{4} [0-9]{2}:[0-9]{2}:[0-9]{2} GMT"#)
        default: return false
        }
    }

    static func cookieName(_ pair: String) -> String? {
        guard let equals = pair.firstIndex(of: "=") else { return nil }
        let name = pair[..<equals].trimmingCharacters(in: .whitespaces)
        var value = pair[pair.index(after: equals)...].trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
            value = String(value.dropFirst().dropLast())
        }
        guard value.utf8.allSatisfy({ byte in
            byte == 33 || (35...43).contains(byte) || (45...58).contains(byte)
                || (60...91).contains(byte) || (93...126).contains(byte)
        }) else { return nil }
        guard HTTPField.Name(name) != nil, !name.hasPrefix(":"), !name.isEmpty else { return nil }
        return name
    }

    static func matches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: "\\A(?:" + pattern + ")\\z", options: .regularExpression) != nil
    }

    static func validParameters(_ value: String) -> Bool {
        let token = #"[!#$%&'*+.^_`|~0-9A-Za-z-]+"#
        let quoted = #""(?:[\x20-\x21\x23-\x5B\x5D-\x7E]|\\[\x20-\x7E])*""#
        let parameter = token + #"[ \t]*=[ \t]*(?:"# + token + "|" + quoted + ")"
        return matches(value, parameter + #"(?:[ \t]*,[ \t]*"# + parameter + ")*")
    }
}
