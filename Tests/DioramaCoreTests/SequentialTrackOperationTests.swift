@testable import DioramaCore
import Synchronization
import Testing

struct SequentialTrackOperationTests {
    private struct UnsafeValue: Error {}

    @Test
    func `record reservations preserve observation order across preparation completion`() async throws {
        let (execution, lease) = try makeExecution(mode: .record, values: [])
        let secondIdentity = Mutex<RecordIdentity?>(nil)
        let firstPreparation = ValuePreparation<Int>(normalize: { value in
            let identity = try lease.append(capturing: { 20 }, preparation: ValuePreparation<Int>())
            secondIdentity.withLock { $0 = identity }
            #expect(lease.recordedRecords().map(\.identity.sequence) == [1])
            #expect(lease.recordedRecords().map(\.value) == [20])
            return value
        })
        let firstIdentity = try lease.append(capturing: { 10 }, preparation: firstPreparation)
        #expect(firstIdentity.sequence == 0)
        #expect(secondIdentity.withLock { $0?.sequence } == 1)
        #expect(lease.recordedRecords().map(\.identity.sequence) == [0, 1])
        #expect(lease.recordedRecords().map(\.value) == [10, 20])
        #expect(await (execution.finish()).report.diagnostics.isEmpty)
    }

    @Test
    func `failed recording admission keeps its reserved position and health evidence`() async throws {
        let (execution, lease) = try makeExecution(mode: .record, values: [1, 2])
        let failing = ValuePreparation<Int>(validate: { _ in throw UnsafeValue() })
        do {
            _ = try lease.append(capturing: { 10 }, preparation: failing)
            Issue.record("Failed preparation unexpectedly entered the track")
        } catch {
            #expect(error.diagnostic.issue == .preparationFailed(.validation))
            #expect(error.diagnostic.context.recordIdentity?.sequence == 0)
        }

        let admitted = try lease.append(capturing: { 20 }, preparation: ValuePreparation<Int>())
        #expect(admitted.sequence == 1)
        #expect(lease.baselineRecords().map(\.value) == [1, 2])
        #expect(lease.recordedRecords().map(\.identity.sequence) == [1])
        #expect(lease.recordedRecords().map(\.value) == [20])
        let result = await execution.finish()
        #expect(result.report.recordingHealth.failures.map(\.diagnostic.context.recordIdentity?.sequence) == [0])
    }

    @Test
    func `concurrent replay claims every record once`() async throws {
        let values = Array(0..<100)
        let (execution, lease) = try makeExecution(mode: .replay, values: values)
        let claimed = try await withThrowingTaskGroup(
            of: SequentialRecord<Int>.self,
            returning: [SequentialRecord<Int>].self)
        { group in
            for _ in values {
                group.addTask { try lease.claimNext() }
            }
            var records: [SequentialRecord<Int>] = []
            for try await record in group {
                records.append(record)
            }
            return records
        }

        #expect(claimed.map(\.identity.sequence).sorted() == Array(0..<UInt64(values.count)))
        #expect(claimed.map(\.value).sorted() == values)
        #expect(Set(claimed.map(\.identity)).count == values.count)
        #expect(await (execution.finish()).report.diagnostics.isEmpty)
    }

    @Test
    func `exhausted replay requests retain distinct stable requested positions`() async throws {
        let (execution, lease) = try makeExecution(mode: .replay, values: [42])
        #expect(try lease.claimNext().value == 42)
        let attempts = await withTaskGroup(
            of: Result<SequentialRecord<Int>, SequentialOperationFailure>.self,
            returning: [Result<SequentialRecord<Int>, SequentialOperationFailure>].self)
        { group in
            for _ in 0..<20 {
                group.addTask { claimResult(from: lease) }
            }
            var results: [Result<SequentialRecord<Int>, SequentialOperationFailure>] = []
            for await result in group {
                results.append(result)
            }
            return results
        }
        let failures = attempts.compactMap { result -> SequentialOperationFailure? in
            if case let .failure(failure) = result {
                failure
            } else {
                nil
            }
        }
        #expect(failures.count == 20)
        #expect(failures.allSatisfy {
            $0.diagnostic.issue == .sequential(.replayExhausted(availableCount: 1))
        })
        #expect(failures.compactMap { $0.diagnostic.context.recordIdentity?.sequence }.sorted() == Array(1..<21))
        let result = await execution.finish()
        #expect(result.report.diagnostics.count == 20)
    }

    @Test
    func `operation diagnostics notify reentrant sinks outside the lease lock`() async throws {
        let leaseReference = Mutex<SequentialTrackLease<Int>?>(nil)
        defer { leaseReference.withLock { $0 = nil } }
        let observedCounts = Mutex<[Int]>([])
        let sink = DiagnosticSink { _ in
            let lease = try #require(leaseReference.withLock { $0 })
            observedCounts.withLock { $0.append(lease.baselineRecords().count) }
        }
        let (execution, lease) = try makeExecution(mode: .replay, values: [42], sink: sink)
        leaseReference.withLock { $0 = lease }

        #expect(try lease.claimNext().value == 42)
        #expect(throws: SequentialOperationFailure.self) { try lease.claimNext() }
        #expect(observedCounts.withLock { $0 } == [1])
        #expect(await (execution.finish()).report.diagnostics.count == 1)
    }

    @Test
    func `wrong mode and closed use diagnose without touching track content`() async throws {
        let (recordExecution, recordLease) = try makeExecution(mode: .record, values: [1, 2])
        #expect(throws: SequentialOperationFailure.self) { try recordLease.claimNext() }
        #expect(recordLease.baselineRecords().map(\.value) == [1, 2])
        #expect(recordLease.recordedRecords().isEmpty)
        #expect(await (recordExecution.finish()).report.diagnostics.map(\.diagnostic.issue) == [
            .sequential(.wrongMode(expected: .replay, actual: .record)),
        ])

        let (replayExecution, replayLease) = try makeExecution(mode: .replay, values: [1, 2])
        let captures = Mutex(0)
        #expect(throws: SequentialOperationFailure.self) {
            try replayLease.append(
                capturing: {
                    captures.withLock { $0 += 1 }
                    return 3
                },
                preparation: ValuePreparation<Int>())
        }
        #expect(captures.withLock { $0 } == 0)
        #expect(replayLease.baselineRecords().map(\.value) == [1, 2])
        #expect(replayLease.recordedRecords().isEmpty)
        _ = await replayExecution.finish()
        #expect(throws: SequentialOperationFailure.self) { try replayLease.claimNext() }
        #expect(throws: SequentialOperationFailure.self) {
            try replayLease.append(
                capturing: {
                    captures.withLock { $0 += 1 }
                    return 3
                },
                preparation: ValuePreparation<Int>())
        }
        #expect(captures.withLock { $0 } == 0)
        #expect(replayExecution.reporter.postFinishDiagnostics.map(\.diagnostic.issue) == [
            .lifecycle(.leaseClosed), .lifecycle(.leaseClosed),
        ])

        let (passthroughExecution, passthroughLease) = try makeExecution(mode: .passthrough, values: [1, 2])
        #expect(passthroughLease.baselineRecords().isEmpty)
        #expect(passthroughLease.recordedRecords().isEmpty)
        #expect(throws: SequentialOperationFailure.self) { try passthroughLease.claimNext() }
        #expect(throws: SequentialOperationFailure.self) {
            try passthroughLease.append(capturing: { 3 }, preparation: ValuePreparation<Int>())
        }
        #expect(passthroughLease.baselineRecords().isEmpty)
        #expect(passthroughLease.recordedRecords().isEmpty)
        #expect(await (passthroughExecution.finish()).report.diagnostics.map(\.diagnostic.issue) == [
            .sequential(.wrongMode(expected: .replay, actual: .passthrough)),
            .sequential(.wrongMode(expected: .record, actual: .passthrough)),
        ])
    }

    @Test
    func `attachments keep independent replay cursors`() async throws {
        let first = ExecutionFixtures.attachment("first")
        let second = ExecutionFixtures.attachment("second")
        let definition = try ScenarioDefinition(
            id: ScenarioID(rawValue: "independent"),
            defaultMode: .replay,
            attachments: [
                ScenarioAttachment(id: first).adding(
                    SequentialTrack(id: ExecutionFixtures.track("first"), values: preparedValues([1, 2]))),
                ScenarioAttachment(id: second).adding(
                    SequentialTrack(id: ExecutionFixtures.track("second"), values: preparedValues([10, 20]))),
            ])
        let journal = ExecutionFixtures.Journal()
        let execution = try ScenarioExecution.start(
            definition: definition,
            systems: [
                ExecutionFixtures.system("second", journal: journal),
                ExecutionFixtures.system("first", journal: journal),
            ])
        let firstLease = try execution.dependency(
            for: first.key, as: SequentialTrackLease<Int>.self)
        let secondLease = try execution.dependency(
            for: second.key, as: SequentialTrackLease<Int>.self)

        #expect(try secondLease.claimNext().value == 10)
        #expect(try firstLease.claimNext().value == 1)
        #expect(try secondLease.claimNext().value == 20)
        #expect(try firstLease.claimNext().value == 2)
        #expect(await (execution.finish()).report.diagnostics.isEmpty)
    }

    private func makeExecution(
        mode: ScenarioMode,
        values: [Int],
        sink: DiagnosticSink? = nil) throws -> (ScenarioExecution, SequentialTrackLease<Int>)
    {
        let attachmentID = ExecutionFixtures.attachment("primary")
        let trackID = ExecutionFixtures.track("primary")
        let attachment = try ScenarioAttachment(id: attachmentID).adding(
            SequentialTrack(id: trackID, values: preparedValues(values)))
        let definition = try ScenarioDefinition(
            id: ScenarioID(rawValue: "sequential-operations"),
            defaultMode: mode,
            attachments: [attachment])
        let system = ScenarioSystem(attachmentID: attachmentID) { context in
            let lease = try context.lease(for: trackID, preparation: ValuePreparation<Int>())
            return PreparedSystem { SystemActivation(dependency: lease, deactivate: {}) }
        }
        let execution = try ScenarioExecution.start(definition: definition, systems: [system], sink: sink)
        let lease = try execution.dependency(for: attachmentID.key, as: SequentialTrackLease<Int>.self)
        return (execution, lease)
    }

    private func claimResult(
        from lease: SequentialTrackLease<Int>) -> Result<SequentialRecord<Int>, SequentialOperationFailure>
    {
        do {
            return try .success(lease.claimNext())
        } catch {
            return .failure(error)
        }
    }
}
