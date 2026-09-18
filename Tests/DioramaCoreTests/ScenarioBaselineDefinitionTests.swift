import DioramaCore
import Testing

struct ScenarioBaselineDefinitionTests {
    @Test
    func `repository baseline replaces content while setup retains order modes and layout`() throws {
        let firstID = attachment("first")
        let secondID = attachment("second")
        let extraID = attachment("extra")
        let firstTrack = track(firstID)
        let secondTrack = track(secondID)
        let extraTrack = track(extraID)
        let configuredFirst = try ScenarioAttachment(id: firstID, modeOverride: .record).adding(
            SequentialTrack(id: firstTrack, values: preparedValues([999])))
        let configuredSecond = try ScenarioAttachment(id: secondID, modeOverride: .passthrough).adding(
            SequentialTrack(id: secondTrack, values: preparedValues([888])))
        let setup = try ScenarioDefinition(
            id: ScenarioID(rawValue: "baseline"),
            defaultMode: .replay,
            attachments: [configuredSecond, configuredFirst])
        let loadedFirst = try ScenarioAttachment(id: firstID).adding(
            SequentialTrack(id: firstTrack, values: preparedValues([1, 2])))
        let loadedExtra = try ScenarioAttachment(id: extraID).adding(
            SequentialTrack(id: extraTrack, values: preparedValues([3, 4, 5])))

        let definition = try setup.replacingBaseline(with: [loadedFirst, loadedExtra])

        #expect(definition.attachments.map(\.id) == [secondID, firstID])
        #expect(definition.effectiveMode(for: secondID.key) == .passthrough)
        #expect(definition.effectiveMode(for: firstID.key) == .record)
        #expect(try definition.attachments[0].track(secondTrack, as: Int.self)?.records.isEmpty == true)
        #expect(try definition.attachments[1].track(firstTrack, as: Int.self)?.records.map(\.value) == [1, 2])
        #expect(definition.attachment(for: extraID.key) == nil)

        let empty = try setup.removingBaseline()
        #expect(try empty.attachments[0].track(secondTrack, as: Int.self)?.records.isEmpty == true)
        #expect(try empty.attachments[1].track(firstTrack, as: Int.self)?.records.isEmpty == true)
    }

    @Test
    func `repository baseline rejects a configured key owned by another system`() throws {
        let key = AttachmentKey(rawValue: "shared")
        let configuredType = SystemTypeID(rawValue: "configured")
        let loadedType = SystemTypeID(rawValue: "loaded")
        let setup = try ScenarioDefinition(
            id: ScenarioID(rawValue: "baseline-mismatch"),
            defaultMode: .replay,
            attachments: [ScenarioAttachment(id: AttachmentID(systemTypeID: configuredType, key: key))])

        #expect(throws: ScenarioDefinitionError.incompatibleAttachmentSystem(
            key: key,
            existing: configuredType,
            proposed: loadedType))
        {
            _ = try setup.replacingBaseline(with: [
                ScenarioAttachment(id: AttachmentID(systemTypeID: loadedType, key: key)),
            ])
        }
    }

    @Test
    func `removing unusable baseline retains configured ignore policy`() throws {
        let ignoredID = attachment("ignored")
        let ignoredTrack = track(ignoredID)
        let ignoredAttachment = try ScenarioAttachment(id: ignoredID).adding(
            SequentialTrack(id: ignoredTrack, values: preparedValues([1])))
        let setup = try ScenarioDefinition(
            id: ScenarioID(rawValue: "ignored-baseline"),
            defaultMode: .record,
            attachments: [ignoredAttachment],
            ignoredAttachments: [ignoredID.key])

        let removed = try setup.removingBaseline()

        #expect(removed.ignoredAttachments == [ignoredID.key])
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
