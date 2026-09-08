import DioramaCore
import Testing

struct ScenarioDefinitionTests {
    private struct NonCodableValue: Equatable, Sendable {
        let value: Int
    }

    @Test
    func `preserves heterogeneous attachments and declaration order`() throws {
        let randomSystem = SystemTypeID(rawValue: "random")
        let firstID = AttachmentID(
            systemTypeID: randomSystem,
            key: AttachmentKey(rawValue: "first"))
        let secondID = AttachmentID(
            systemTypeID: randomSystem,
            key: AttachmentKey(rawValue: "second"))
        let textID = AttachmentID(
            systemTypeID: SystemTypeID(rawValue: "text"),
            key: AttachmentKey(rawValue: "messages"))

        let firstTrackID = TrackID(
            attachmentID: firstID,
            key: TrackKey(rawValue: "values"))
        let secondTrackID = TrackID(
            attachmentID: secondID,
            key: TrackKey(rawValue: "values"))
        let textTrackID = TrackID(
            attachmentID: textID,
            key: TrackKey(rawValue: "values"))

        let first = try ScenarioAttachment(id: firstID).adding(
            SequentialTrack(
                id: firstTrackID,
                values: preparedValues([NonCodableValue(value: 21)])))
        let second = try ScenarioAttachment(id: secondID).adding(
            SequentialTrack(id: secondTrackID, values: preparedValues([UInt64(34)])))
        let text = try ScenarioAttachment(id: textID).adding(
            SequentialTrack(id: textTrackID, values: preparedValues(["hello"])))

        let definition = try ScenarioDefinition(
            id: ScenarioID(rawValue: "heterogeneous"),
            defaultMode: .replay,
            attachments: [second, text, first])

        #expect(definition.attachments.map(\.id) == [secondID, textID, firstID])
        #expect(
            try definition.attachment(for: firstID.key)?
                .track(firstTrackID, as: NonCodableValue.self)?
                .records.map(\.value) == [NonCodableValue(value: 21)])
        #expect(
            try definition.attachment(for: secondID.key)?
                .track(secondTrackID, as: UInt64.self)?
                .records.map(\.value) == [34])
        #expect(
            try definition.attachment(for: textID.key)?
                .track(textTrackID, as: String.self)?
                .records.map(\.value) == ["hello"])
    }

    @Test
    func `preserves heterogeneous track declaration order`() throws {
        let attachmentID = AttachmentID(
            systemTypeID: SystemTypeID(rawValue: "example"),
            key: AttachmentKey(rawValue: "primary"))
        let numbersID = TrackID(
            attachmentID: attachmentID,
            key: TrackKey(rawValue: "numbers"))
        let labelsID = TrackID(
            attachmentID: attachmentID,
            key: TrackKey(rawValue: "labels"))

        let attachment = try ScenarioAttachment(id: attachmentID)
            .adding(SequentialTrack(id: numbersID, values: preparedValues([NonCodableValue(value: 1)])))
            .adding(SequentialTrack(id: labelsID, values: preparedValues(["first"])))

        #expect(attachment.trackIDs == [numbersID, labelsID])
        #expect(
            try attachment.track(numbersID, as: NonCodableValue.self)?
                .records.map(\.value) == [NonCodableValue(value: 1)])
        #expect(
            try attachment.track(labelsID, as: String.self)?
                .records.map(\.value) == ["first"])
    }

    @Test
    func `assigns stable record identities in deterministic order`() throws {
        let attachmentID = AttachmentID(
            systemTypeID: SystemTypeID(rawValue: "example"),
            key: AttachmentKey(rawValue: "primary"))
        let trackID = TrackID(
            attachmentID: attachmentID,
            key: TrackKey(rawValue: "events"))

        let track = try SequentialTrack(id: trackID, values: preparedValues(["first", "second", "third"]))

        #expect(track.records.map(\.value) == ["first", "second", "third"])
        #expect(track.records.map(\.identity.trackID) == [trackID, trackID, trackID])
        #expect(track.records.map(\.identity.sequence) == [0, 1, 2])
    }

    @Test
    func `accepts empty definitions attachments and tracks`() throws {
        let empty = try ScenarioDefinition(
            id: ScenarioID(rawValue: "empty"),
            defaultMode: .replay)
        #expect(empty.attachments.isEmpty)

        let attachmentID = AttachmentID(
            systemTypeID: SystemTypeID(rawValue: "example"),
            key: AttachmentKey(rawValue: "empty"))
        let trackID = TrackID(
            attachmentID: attachmentID,
            key: TrackKey(rawValue: "values"))
        let attachment = try ScenarioAttachment(id: attachmentID).adding(
            SequentialTrack<NonCodableValue>(id: trackID))

        #expect(attachment.trackIDs == [trackID])
        #expect(
            try attachment.track(trackID, as: NonCodableValue.self)?
                .records.isEmpty == true)
    }

    @Test
    func `resolves default and whole attachment modes`() throws {
        let systemTypeID = SystemTypeID(rawValue: "example")
        let inherited = ScenarioAttachment(
            id: AttachmentID(
                systemTypeID: systemTypeID,
                key: AttachmentKey(rawValue: "inherited")))
        let recording = ScenarioAttachment(
            id: AttachmentID(
                systemTypeID: systemTypeID,
                key: AttachmentKey(rawValue: "recording")),
            modeOverride: .record)
        let passthrough = ScenarioAttachment(
            id: AttachmentID(
                systemTypeID: systemTypeID,
                key: AttachmentKey(rawValue: "passthrough")),
            modeOverride: .passthrough)
        let definition = try ScenarioDefinition(
            id: ScenarioID(rawValue: "modes"),
            defaultMode: .replay,
            attachments: [inherited, recording, passthrough])

        #expect(definition.effectiveMode(for: inherited.id.key) == .replay)
        #expect(definition.effectiveMode(for: recording.id.key) == .record)
        #expect(definition.effectiveMode(for: passthrough.id.key) == .passthrough)
        #expect(definition.effectiveMode(for: AttachmentKey(rawValue: "missing")) == nil)
    }

    @Test
    func `rejects duplicate attachment identity`() {
        let id = AttachmentID(
            systemTypeID: SystemTypeID(rawValue: "example"),
            key: AttachmentKey(rawValue: "duplicate"))
        let attachment = ScenarioAttachment(id: id)

        #expect(throws: ScenarioDefinitionError.duplicateAttachment(id)) {
            _ = try ScenarioDefinition(
                id: ScenarioID(rawValue: "duplicates"),
                defaultMode: .replay,
                attachments: [attachment, attachment])
        }
    }

    @Test
    func `rejects one attachment key for incompatible systems`() {
        let key = AttachmentKey(rawValue: "shared")
        let firstSystem = SystemTypeID(rawValue: "first")
        let secondSystem = SystemTypeID(rawValue: "second")

        let expectedError = ScenarioDefinitionError.incompatibleAttachmentSystem(
            key: key,
            existing: firstSystem,
            proposed: secondSystem)
        #expect(throws: expectedError) {
            _ = try ScenarioDefinition(
                id: ScenarioID(rawValue: "incompatible"),
                defaultMode: .replay,
                attachments: [
                    ScenarioAttachment(
                        id: AttachmentID(systemTypeID: firstSystem, key: key)),
                    ScenarioAttachment(
                        id: AttachmentID(systemTypeID: secondSystem, key: key)),
                ])
        }
    }

    @Test
    func `rejects a track belonging to another attachment`() {
        let systemTypeID = SystemTypeID(rawValue: "example")
        let expectedID = AttachmentID(
            systemTypeID: systemTypeID,
            key: AttachmentKey(rawValue: "expected"))
        let otherID = AttachmentID(
            systemTypeID: systemTypeID,
            key: AttachmentKey(rawValue: "other"))
        let trackID = TrackID(
            attachmentID: otherID,
            key: TrackKey(rawValue: "values"))

        let expectedError = ScenarioDefinitionError.incompatibleTrackAttachment(
            track: trackID,
            expected: expectedID)
        #expect(throws: expectedError) {
            _ = try ScenarioAttachment(id: expectedID).adding(
                SequentialTrack(id: trackID, values: preparedValues([1])))
        }
        #expect(throws: expectedError) {
            _ = try ScenarioAttachment(id: expectedID).track(trackID, as: Int.self)
        }
    }

    @Test
    func `rejects duplicate and incompatible track identity`() throws {
        let attachmentID = AttachmentID(
            systemTypeID: SystemTypeID(rawValue: "example"),
            key: AttachmentKey(rawValue: "primary"))
        let trackID = TrackID(
            attachmentID: attachmentID,
            key: TrackKey(rawValue: "values"))
        let track = try SequentialTrack(id: trackID, values: preparedValues([1]))
        let attachment = try ScenarioAttachment(id: attachmentID).adding(track)

        #expect(throws: ScenarioDefinitionError.duplicateTrack(trackID)) {
            _ = try attachment.adding(track)
        }
        #expect(throws: ScenarioDefinitionError.incompatibleTrackRecordType(trackID)) {
            _ = try attachment.adding(SequentialTrack(id: trackID, values: preparedValues(["one"])))
        }
        #expect(throws: ScenarioDefinitionError.incompatibleTrackRecordType(trackID)) {
            _ = try attachment.track(trackID, as: String.self)
        }
    }
}
