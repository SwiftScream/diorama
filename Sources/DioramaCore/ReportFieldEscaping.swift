/// Shared quoting for setup-authored fields in human-readable reports.
package enum ReportFieldEscaping {
    /// Escapes quotes, controls, and direction controls using report text notation.
    /// The `\\u{...}` form is human-readable and is not JSON string syntax.
    package static func quote(_ text: String) -> String {
        var result = "\""
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x22: result += "\\\""
            case 0x5C: result += "\\\\"
            case 0...0x1F, 0x7F...0x9F, 0x2028...0x202E, 0x2066...0x2069:
                result += "\\u{\(String(scalar.value, radix: 16))}"
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result + "\""
    }
}
