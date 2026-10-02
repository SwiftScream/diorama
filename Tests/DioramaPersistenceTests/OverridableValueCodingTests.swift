import DioramaCore
import DioramaPersistence
import Foundation
import Testing

struct OverridableValueCodingTests {
    private struct StableObject: Codable, Equatable, Sendable {
        let count: Int
    }

    @Test
    func `scalar fields normalize edited forms to one effective value`() throws {
        let decoder = JSONDecoder()
        let observed = try decoder.decode(OverridableValue<String>.self, from: Data(#""5s""#.utf8))
        #expect(observed == .observed("5s"))

        let explicit = try decoder.decode(
            OverridableValue<String>.self, from: Data(#"{"observed":"5s"}"#.utf8))
        #expect(explicit == .observed("5s"))

        let edited = try decoder.decode(
            OverridableValue<String>.self, from: Data(#"{"observed":"5s","override":"-1s"}"#.utf8))
        #expect(edited == .override("-1s"))
        let canonical = try JSONEncoder().encode(edited)
        #expect(String(bytes: canonical, encoding: .utf8) == #"{"override":"-1s"}"#)
    }

    @Test
    func `structured fields retain raw observations and explicit overrides`() throws {
        let decoder = JSONDecoder()
        let observed = try decoder.decode(OverridableValue<StableObject>.self, from: Data(#"{"count":2}"#.utf8))
        #expect(observed == .observed(StableObject(count: 2)))

        let overridden = try decoder.decode(
            OverridableValue<StableObject>.self, from: Data(#"{"override":{"count":3}}"#.utf8))
        #expect(overridden == .override(StableObject(count: 3)))
        let canonical = try JSONEncoder().encode(OverridableValue.observed(StableObject(count: 2)))
        #expect(String(bytes: canonical, encoding: .utf8) == #"{"count":2}"#)
    }

    @Test
    func `tagged fields reject undeclared keys`() throws {
        #expect(throws: PersistedScenarioCodingError.unknownField(
            codingPath: [], field: "extra"))
        {
            _ = try JSONDecoder().decode(
                OverridableValue<String>.self, from: Data(#"{"observed":"5s","extra":0}"#.utf8))
        }
    }
}
