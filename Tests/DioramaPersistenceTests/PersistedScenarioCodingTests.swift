import DioramaCore
@testable import DioramaPersistence
import Foundation
import Testing

struct PersistedScenarioCodingTests {
    @Test
    func `format-neutral coding requires an explicitly configured registry`() throws {
        let registry = try PersistentSystemRegistry([
            PersistentSystemRegistryTests.numberRegistration(current: 1),
        ])
        let original = try ScenarioDefinition(attachments: [
            PersistentSystemRegistryTests.numberAttachment(
                key: "registry-required",
                values: [7]),
        ])

        let unconfiguredEncoder = PropertyListEncoder()
        #expect(throws: EncodingError.self) {
            _ = try unconfiguredEncoder.encode(PersistedScenarioEnvelope(original))
        }

        let configuredEncoder = PropertyListEncoder()
        configuredEncoder.userInfo[persistentSystemRegistryUserInfoKey] = registry
        let data = try configuredEncoder.encode(PersistedScenarioEnvelope(original))

        let unconfiguredDecoder = PropertyListDecoder()
        #expect(throws: DecodingError.self) {
            _ = try unconfiguredDecoder.decode(PersistedScenarioEnvelope.self, from: data)
        }
    }

    @Test
    func `codable object model round trips through a non JSON format`() throws {
        let registry = try PersistentSystemRegistry([
            PersistentSystemRegistryTests.numberRegistration(current: 1),
        ])
        let original = try ScenarioDefinition(attachments: [
            PersistentSystemRegistryTests.numberAttachment(
                key: "property-list",
                values: [7, 11]),
        ])

        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        encoder.userInfo[persistentSystemRegistryUserInfoKey] = registry
        let data = try encoder.encode(PersistedScenarioEnvelope(original))

        let decoder = PropertyListDecoder()
        decoder.userInfo[persistentSystemRegistryUserInfoKey] = registry
        let decoded = try decoder.decode(PersistedScenarioEnvelope.self, from: data).scenario

        #expect(decoded.attachments.map(\.id.key.rawValue) == ["property-list"])
        #expect(try PersistentSystemRegistryTests.values(
            in: decoded.attachments[0],
            as: Int.self) == [7, 11])
    }
}
