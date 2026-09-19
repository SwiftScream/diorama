import DioramaCore
import Testing

struct ScenarioBaselineDefinitionTests {
    @Test
    func `repository baseline replaces content while layout retains order and track types`() throws {
        let firstID = attachment("first")
        let secondID = attachment("second")
        let extraID = attachment("extra")
        let firstTrack = track(firstID)
        let secondTrack = track(secondID)
        let extraTrack = track(extraID)
        let configuredFirst = try ScenarioAttachment(id: firstID).adding(
            SequentialTrack(id: firstTrack, values: preparedValues([999])))
        let configuredSecond = try ScenarioAttachment(id: secondID).adding(
            SequentialTrack(id: secondTrack, values: preparedValues([888])))
        let setup = try ScenarioDefinition(attachments: [configuredSecond, configuredFirst])
        let loadedFirst = try ScenarioAttachment(id: firstID).adding(
            SequentialTrack(id: firstTrack, values: preparedValues([1, 2])))
        let loadedExtra = try ScenarioAttachment(id: extraID).adding(
            SequentialTrack(id: extraTrack, values: preparedValues([3, 4, 5])))

        let definition = try setup.replacingBaseline(with: ScenarioDefinition(attachments: [loadedFirst, loadedExtra]))

        #expect(definition.attachments.map(\.id) == [secondID, firstID])
        #expect(try definition.attachments[0].track(secondTrack, as: Int.self)?.records.isEmpty == true)
        #expect(try definition.attachments[1].track(firstTrack, as: Int.self)?.records.map(\.value) == [1, 2])
        #expect(definition.attachment(for: extraID.key) == nil)

        let empty = setup.removingRecords()
        #expect(try empty.attachments[0].track(secondTrack, as: Int.self)?.records.isEmpty == true)
        #expect(try empty.attachments[1].track(firstTrack, as: Int.self)?.records.isEmpty == true)
    }

    @Test
    func `repository baseline rejects a configured key owned by another system`() throws {
        let key = AttachmentKey(rawValue: "shared")
        let configuredType = SystemTypeID(rawValue: "configured")
        let loadedType = SystemTypeID(rawValue: "loaded")
        let configuredID = AttachmentID(systemTypeID: configuredType, key: key)
        let setup = try ScenarioDefinition(attachments: [ScenarioAttachment(id: configuredID)])

        #expect(throws: ScenarioDefinitionError.incompatibleAttachmentSystem(
            key: key,
            existing: configuredType,
            proposed: loadedType))
        {
            _ = try setup.replacingBaseline(with: ScenarioDefinition(attachments: [
                ScenarioAttachment(id: AttachmentID(systemTypeID: loadedType, key: key)),
            ]))
        }
    }

    @Test
    func `removing records preserves the original baseline`() throws {
        let ignoredID = attachment("ignored")
        let ignoredTrack = track(ignoredID)
        let ignoredAttachment = try ScenarioAttachment(id: ignoredID).adding(
            SequentialTrack(id: ignoredTrack, values: preparedValues([1])))
        let setup = try ScenarioDefinition(attachments: [ignoredAttachment])

        let removed = setup.removingRecords()

        #expect(try setup.attachments[0].track(ignoredTrack, as: Int.self)?.records.map(\.value) == [1])
        #expect(try removed.attachments[0].track(ignoredTrack, as: Int.self)?.records.isEmpty == true)
    }

    private func attachment(_ key: String) -> AttachmentID {
        AttachmentID(
            systemTypeID: SystemTypeID(rawValue: "example"),
            key: AttachmentKey(rawValue: key))
    }

    private func track(_ attachmentID: AttachmentID) -> TrackID {
        TrackID(attachmentID: attachmentID, key: TrackKey(rawValue: "values"))
    }
}
