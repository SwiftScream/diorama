import CoreFoundation
import Foundation

/// Bounded property-list-like information shared by NSError-based adapters.
package indirect enum NSErrorSnapshotValue: Equatable, Sendable {
    /// A bounded UTF-8 string.
    case string(String)
    /// A signed 64-bit integer.
    case integer(Int64)
    /// A finite floating-point number.
    case real(Double)
    /// A Boolean, distinct from an integer.
    case boolean(Bool)
    /// Bounded binary data.
    case data(Data)
    /// A date in the shared representable wall range.
    case date(Date)
    /// A bounded ordered collection.
    case array([Self])
    /// A bounded string-keyed collection.
    case dictionary([String: Self])

    fileprivate var foundationValue: Any {
        switch self {
        case let .string(value): value
        case let .integer(value): NSNumber(value: value)
        case let .real(value): NSNumber(value: value)
        case let .boolean(value): NSNumber(value: value)
        case let .data(value): value
        case let .date(value): value
        case let .array(values): values.map(\.foundationValue)
        case let .dictionary(values): values.mapValues(\.foundationValue)
        }
    }
}

/// A validated error snapshot without a native object graph.
///
/// Systems own preparation, diagnostic reporting, and deliberate persistence
/// schemas. This helper neither redacts values nor preserves custom error identity.
package struct NSErrorSnapshot: Equatable, Sendable {
    /// Maximum nested collection depth; a scalar at the root has depth zero.
    package static let maximumDepth = 4
    /// Maximum number of values across one snapshot's user information.
    package static let maximumValues = 128
    /// Maximum number of entries in any one collection.
    package static let maximumCollectionEntries = 32
    /// Maximum UTF-8 bytes in one domain or user-information key.
    package static let maximumKeyBytes = 256
    /// Maximum UTF-8 bytes in one string value.
    package static let maximumStringBytes = 4096
    /// Maximum bytes in one data value.
    package static let maximumDataBytes = 16384
    /// Maximum combined string, key, and data bytes in user information.
    package static let maximumTotalBytes = 65536

    /// Native error domain.
    package let domain: String
    /// Native integer error code.
    package let code: Int
    /// Explicitly bounded supported user information.
    package let userInfo: [String: NSErrorSnapshotValue]

    /// Creates a snapshot only when its complete value tree is valid.
    package init?(domain: String, code: Int, userInfo: [String: NSErrorSnapshotValue] = [:]) {
        guard !domain.isEmpty, domain.utf8.count <= Self.maximumKeyBytes,
              userInfo.count <= Self.maximumCollectionEntries
        else { return nil }
        var budget = ValueBudget()
        for key in userInfo.keys.sorted() {
            guard let value = userInfo[key],
                  Self.validKey(key),
                  budget.addBytes(key.utf8.count),
                  Self.validate(value, depth: 0, budget: &budget)
            else { return nil }
        }
        self.domain = domain
        self.code = code
        self.userInfo = userInfo
    }

    /// Copies supported bounded values from an `NSError`. Unsupported entries
    /// are omitted individually and return key/type-only facts for system diagnostics.
    package static func capture(_ error: NSError) -> NSErrorSnapshotCapture {
        var values: [String: NSErrorSnapshotValue] = [:]
        var warnings: [NSErrorSnapshotOmission] = []
        var budget = ValueBudget()
        for key in error.userInfo.keys.sorted() {
            guard let object = error.userInfo[key] else { continue }
            var candidateBudget = budget
            if validKey(key), values.count < maximumCollectionEntries,
               candidateBudget.addBytes(key.utf8.count),
               let value = convert(object, depth: 0, budget: &candidateBudget)
            {
                values[key] = value
                budget = candidateBudget
            } else {
                warnings.append(NSErrorSnapshotOmission(
                    key: key, runtimeType: String(reflecting: type(of: object))))
            }
        }
        return NSErrorSnapshotCapture(
            snapshot: NSErrorSnapshot(domain: error.domain, code: error.code, userInfo: values),
            omissions: warnings)
    }

    /// Reconstructs a fresh native error with the supported snapshot values.
    /// Custom NSError subclasses and arbitrary Swift error identity are not restored.
    package func makeError() -> NSError {
        NSError(domain: domain, code: code, userInfo: userInfo.mapValues(\.foundationValue))
    }

    private static func validKey(_ key: String) -> Bool {
        !key.isEmpty && key.utf8.count <= maximumKeyBytes
    }

    private static func validate(
        _ value: NSErrorSnapshotValue,
        depth: Int,
        budget: inout ValueBudget) -> Bool
    {
        guard depth <= maximumDepth, budget.addValue() else { return false }
        switch value {
        case let .string(string):
            return string.utf8.count <= maximumStringBytes && budget.addBytes(string.utf8.count)
        case .integer, .boolean:
            return true
        case let .real(number):
            return number.isFinite
        case let .data(data):
            return data.count <= maximumDataBytes && budget.addBytes(data.count)
        case let .date(date):
            return StableTimeCodec.roundedToMillisecond(date) != nil
        case let .array(values):
            return validateArray(values, depth: depth, budget: &budget)
        case let .dictionary(values):
            return validateDictionary(values, depth: depth, budget: &budget)
        }
    }

    private static func validateArray(
        _ values: [NSErrorSnapshotValue],
        depth: Int,
        budget: inout ValueBudget) -> Bool
    {
        guard values.count <= maximumCollectionEntries else { return false }
        return values.allSatisfy { validate($0, depth: depth + 1, budget: &budget) }
    }

    private static func validateDictionary(
        _ values: [String: NSErrorSnapshotValue],
        depth: Int,
        budget: inout ValueBudget) -> Bool
    {
        guard values.count <= maximumCollectionEntries else { return false }
        for key in values.keys.sorted() {
            guard let child = values[key], validKey(key), budget.addBytes(key.utf8.count),
                  validate(child, depth: depth + 1, budget: &budget)
            else { return false }
        }
        return true
    }

    private static func convert(
        _ object: Any,
        depth: Int,
        budget: inout ValueBudget) -> NSErrorSnapshotValue?
    {
        guard depth <= maximumDepth, budget.addValue() else { return nil }
        if let value = convertScalar(object, budget: &budget) {
            return value
        }
        if let array = object as? [Any] {
            return convertArray(array, depth: depth, budget: &budget)
        }
        if let dictionary = object as? [String: Any] {
            return convertDictionary(dictionary, depth: depth, budget: &budget)
        }
        return nil
    }

    private static func convertScalar(
        _ object: Any,
        budget: inout ValueBudget) -> NSErrorSnapshotValue?
    {
        if let string = object as? String {
            guard string.utf8.count <= maximumStringBytes, budget.addBytes(string.utf8.count) else { return nil }
            return .string(string)
        }
        if let data = object as? Data {
            guard data.count <= maximumDataBytes, budget.addBytes(data.count) else { return nil }
            return .data(data)
        }
        if let date = object as? Date {
            guard StableTimeCodec.roundedToMillisecond(date) != nil else { return nil }
            return .date(date)
        }
        if let number = object as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .boolean(number.boolValue)
            }
            let encoding = String(cString: number.objCType)
            if ["f", "d"].contains(encoding) {
                return number.doubleValue.isFinite ? .real(number.doubleValue) : nil
            }
            return Int64(number.stringValue).map(NSErrorSnapshotValue.integer)
        }
        return nil
    }

    private static func convertArray(
        _ array: [Any],
        depth: Int,
        budget: inout ValueBudget) -> NSErrorSnapshotValue?
    {
        guard array.count <= maximumCollectionEntries else { return nil }
        var converted: [NSErrorSnapshotValue] = []
        for child in array {
            guard let value = convert(child, depth: depth + 1, budget: &budget) else { return nil }
            converted.append(value)
        }
        return .array(converted)
    }

    private static func convertDictionary(
        _ dictionary: [String: Any],
        depth: Int,
        budget: inout ValueBudget) -> NSErrorSnapshotValue?
    {
        guard dictionary.count <= maximumCollectionEntries else { return nil }
        var converted: [String: NSErrorSnapshotValue] = [:]
        for key in dictionary.keys.sorted() {
            guard let child = dictionary[key], validKey(key), budget.addBytes(key.utf8.count),
                  let value = convert(child, depth: depth + 1, budget: &budget)
            else { return nil }
            converted[key] = value
        }
        return .dictionary(converted)
    }
}

/// One omitted error-information entry, without rendering its value.
package struct NSErrorSnapshotOmission: Equatable, Sendable {
    /// Original user-information key.
    package let key: String
    /// Reflected runtime type name, never the value's description.
    package let runtimeType: String
}

/// The bounded snapshot and any user-information omission facts.
package struct NSErrorSnapshotCapture: Sendable {
    /// The snapshot, or nil if its domain cannot be represented.
    package let snapshot: NSErrorSnapshot?
    /// Entries omitted because their type or size was unsupported.
    package let omissions: [NSErrorSnapshotOmission]
}

private struct ValueBudget {
    var values = 0
    var bytes = 0

    mutating func addValue() -> Bool {
        guard values < NSErrorSnapshot.maximumValues else { return false }
        values += 1
        return true
    }

    mutating func addBytes(_ amount: Int) -> Bool {
        guard amount <= NSErrorSnapshot.maximumTotalBytes - bytes else { return false }
        bytes += amount
        return true
    }
}
