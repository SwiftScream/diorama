import DioramaCore
import Synchronization
import Testing

struct ScenarioSystemTypeTests {
    @Test(arguments: [false, true])
    func `core setup shares type metadata and never invokes optional persistence`(hasPersistence: Bool) async throws {
        let persistence = UnusedPersistence()
        let type = ScenarioSystemType("consumer.core-only", persistence: hasPersistence ? persistence : nil)
        let first = try system(type: type, key: "first")
        let second = try system(type: type, key: "second")
        #expect(first.type === second.type)
        #expect(first.type.id == first.attachment.id.systemTypeID)
        #expect((first.type.persistence != nil) == hasPersistence)
        let execution = try ScenarioExecution.start(
            definition: ScenarioDefinition(attachments: [first.attachment, second.attachment]),
            scenarioID: ScenarioID(rawValue: "type-metadata"), defaultMode: .record,
            systems: [AnyScenarioSystem(first), AnyScenarioSystem(second)])
        #expect(try execution.dependency(first) + execution.dependency(second) == "firstsecond")
        let result = await execution.finish()
        #expect(result.report.diagnostics.isEmpty)
        #expect(persistence.calls.withLock { $0 } == 0)
    }

    @Test
    func `system construction validates its descriptor against stable attachment identity`() {
        let type = ScenarioSystemType("consumer.expected")
        let key = AttachmentKey(rawValue: "instance")
        let otherID = SystemTypeID(rawValue: "consumer.other")
        #expect(throws: ScenarioDefinitionError.incompatibleAttachmentSystem(
            key: key, existing: type.id, proposed: otherID))
        {
            try ScenarioSystem(
                type: type, attachment: ScenarioAttachment(id: AttachmentID(systemTypeID: otherID, key: key)))
            { _ in
                Issue.record("Invalid setup must not prepare")
                return PreparedSystem { ActivatedSystem(dependency: true, deactivate: {}) }
            }
        }
    }

    private func system(type: ScenarioSystemType, key: String) throws -> ScenarioSystem<String> {
        try ScenarioSystem(type: type, attachment: ScenarioAttachment(id: AttachmentID(
            systemTypeID: type.id, key: AttachmentKey(rawValue: key))))
        { _ in
            PreparedSystem { ActivatedSystem(dependency: key, deactivate: {}) }
        }
    }
}

private final class UnusedPersistence: ScenarioSystemPersistence {
    let currentSchemaVersion: UInt32 = 1
    let supportedSchemaVersions: [UInt32] = [1]
    let calls = Mutex(0)

    func encode(_: ScenarioAttachment, to _: any Encoder) throws {
        calls.withLock { $0 += 1 }
        throw UnexpectedPersistenceUse()
    }

    func decode(attachmentID _: AttachmentID, version _: UInt32, from _: any Decoder) throws -> ScenarioAttachment {
        calls.withLock { $0 += 1 }
        throw UnexpectedPersistenceUse()
    }
}

private struct UnexpectedPersistenceUse: Error {}
