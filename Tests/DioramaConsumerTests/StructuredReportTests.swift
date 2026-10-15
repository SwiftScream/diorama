import Diorama
import DioramaCore
import DioramaRandom
import Testing

struct StructuredReportTests {
    private enum BodyFailure: Error { case stopped }
    private struct Counter: RandomNumberGenerator, Sendable {
        var value: UInt64 = 10
        mutating func next() -> UInt64 {
            defer { value += 1 }
            return value
        }
    }

    @Test
    func `success and original body failure expose identical evaluable Random facts`() async throws {
        let random = try DioramaRandomSystem.instance(named: "random") { Counter() }
        let recording = try await Diorama(scenarioID: "record", mode: .record, systems: random)
            .execute { _, random in
                var random = random
                return [random.next(), random.next()]
            }
        let definition = try #require(recording.definition)
        let setup = try Diorama(definition: definition, scenarioID: "replay", mode: .replay, systems: random)
        let first = try await setup.execute { _, random in
            var random = random
            return random.next()
        }
        #expect(first.body == recording.body[0])
        let saved = try #require(setup.report)
        #expect(saved == first.report)
        #expect(saved.evaluated(.noDiagnostics).isSatisfied)
        let unused = RecordIdentity(trackID: random.attachment.trackIDs[0], sequence: 1)
        #expect(saved.evaluated(.allRecordsClaimed).failures == [.unclaimedRecord(unused)])
        #expect(saved.evaluated(.allClaimedRecordsConsumed).isSatisfied)
        #expect(saved.finalization.usage[0].tracks[0].unclaimedRecords == [unused])
        #expect(saved.evaluated(.allRecordsClaimed, attachments: []).isSatisfied)
        #expect(saved.evaluated(.allRecordsClaimed, attachments: [random.attachment.id.key]).failures == [
            .unclaimedRecord(unused),
        ])
        #expect(saved.evaluated(.noDiagnostics, attachments: [AttachmentKey(rawValue: "unknown")]).failures == [
            .unknownAttachment(AttachmentKey(rawValue: "unknown")),
        ])

        do {
            _ = try await setup.execute { _, random async throws(BodyFailure) in
                var random = random
                #expect(random.next() == recording.body[0])
                throw .stopped
            }
            Issue.record("Expected the original body error")
        } catch {
            #expect(error as? BodyFailure == .stopped)
            #expect(setup.report == saved)
            #expect(setup.report?.evaluated(.allRecordsClaimed) == saved.evaluated(.allRecordsClaimed))
        }
        let full = try await setup.execute { _, random in
            var random = random
            return [random.next(), random.next()]
        }
        #expect(full.body == recording.body)
        #expect(full.definition != nil)
        #expect(full.report.evaluated(.allRecordsClaimed).isSatisfied)
        #expect(setup.report == full.report)
        #expect(!saved.evaluated(.allRecordsClaimed).isSatisfied)
        #expect(saved.rendered() == first.report.rendered())
        #expect(saved.rendered().contains("Unclaimed record 1"))
    }
}
