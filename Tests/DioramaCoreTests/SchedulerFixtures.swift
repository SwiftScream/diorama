@testable import DioramaCore
import Synchronization
import Testing

final class SchedulerTestClock: Sendable {
    struct Sleep: Sendable {
        let deadline: Duration
        let tolerance: Duration
        let resume: AsyncStream<Void>.Continuation
    }

    private struct State {
        var now: Duration = .zero
        var nextID = 0
        var sleepers: [Int: Sleep] = [:]
        var maximumWaits = 0
    }

    private let origin = ContinuousClock().now
    private let state = Mutex(State())
    private let registrations = AsyncStream<Sleep>.makeStream()
    private let cancellations = AsyncStream<Duration>.makeStream()

    var source: ExecutionClock {
        ExecutionClock(now: { self.origin.advanced(by: self.state.withLock { $0.now }) },
                       sleep: { try await self.sleep(until: $0, tolerance: $1) })
    }

    var maximumWaits: Int {
        state.withLock { $0.maximumWaits }
    }

    var activeWaits: Int {
        state.withLock { $0.sleepers.count }
    }

    func advance(to now: Duration, waking: Bool = true, early: Bool = false) {
        let ready = state.withLock { state in
            state.now = now
            return state.sleepers.sorted { $0.key < $1.key }.compactMap { _, sleep in
                waking && (early || sleep.deadline <= now) ? sleep.resume : nil
            }
        }
        for continuation in ready {
            continuation.finish()
        }
    }

    func nextSleep() async throws -> Sleep {
        var iterator = registrations.stream.makeAsyncIterator()
        return try #require(await iterator.next())
    }

    func nextCancellation() async throws -> Duration {
        var iterator = cancellations.stream.makeAsyncIterator()
        return try #require(await iterator.next())
    }

    private func sleep(until deadline: ContinuousClock.Instant, tolerance: Duration) async throws {
        let signal = AsyncStream<Void>.makeStream()
        let sleep = Sleep(deadline: origin.duration(to: deadline), tolerance: tolerance, resume: signal.continuation)
        let id = state.withLock { state in
            let id = state.nextID
            state.nextID += 1
            state.sleepers[id] = sleep
            state.maximumWaits = max(state.maximumWaits, state.sleepers.count)
            if sleep.deadline <= state.now {
                signal.continuation.finish()
            }
            return id
        }
        registrations.continuation.yield(sleep)
        var iterator = signal.stream.makeAsyncIterator()
        _ = await iterator.next()
        state.withLock { $0.sleepers[id] = nil }
        if Task.isCancelled {
            cancellations.continuation.yield(sleep.deadline)
        }
        try Task.checkCancellation()
    }
}

final class SchedulerJournal: Sendable {
    private let storage = Mutex<[String]>([])
    private let stream = AsyncStream<String>.makeStream()

    var values: [String] {
        storage.withLock { $0 }
    }

    func append(_ value: String) {
        storage.withLock { $0.append(value) }
        stream.continuation.yield(value)
    }

    func take(_ count: Int) async -> [String] {
        var iterator = stream.stream.makeAsyncIterator()
        var values: [String] = []
        for _ in 0..<count {
            if let value = await iterator.next() {
                values.append(value)
            }
        }
        return values
    }
}

enum SchedulerFixtures {
    struct Dependency: Sendable {
        let time: ExecutionTime
        let scheduling: SchedulingLease
    }

    static func record(_ attachment: String = "a", track: String = "z-first", sequence: UInt64 = 0) -> RecordIdentity {
        RecordIdentity(trackID: TrackID(attachmentID: ExecutionFixtures.attachment(attachment),
                                        key: TrackKey(rawValue: track)), sequence: sequence)
    }

    static func setup(_ keys: [String] = ["a"], clock: ExecutionClock = .continuous(),
                      sink: DiagnosticSink? = nil) throws -> (ScenarioExecution, [Dependency])
    {
        var attachments: [ScenarioAttachment] = []
        var systems: [AnyScenarioSystem] = []
        for key in keys {
            let attachment = try ScenarioAttachment(id: ExecutionFixtures.attachment(key))
                .adding(HeaderlessSequentialTrack<Int>(id: record(key).trackID))
                .adding(HeaderlessSequentialTrack<Int>(id: record(key, track: "a-second").trackID))
            attachments.append(attachment)
            let system = try ScenarioSystem(type: ExecutionFixtures.type, attachment: attachment) { context in
                _ = try context.lease(for: record(key).trackID, preparation: ValuePreparation<Int>())
                _ = try context.lease(for: record(key, track: "a-second").trackID,
                                      preparation: ValuePreparation<Int>())
                let dependency = Dependency(time: context.time, scheduling: context.scheduling)
                return PreparedSystem { ActivatedSystem(dependency: dependency, deactivate: {}) }
            }
            systems.append(AnyScenarioSystem(system))
        }
        let execution = try ScenarioExecution.start(
            definition: ScenarioDefinition(attachments: attachments),
            scenarioID: ScenarioID(rawValue: "scheduler"), defaultMode: .replay,
            systems: systems.reversed(), sink: sink, clock: clock)
        let dependencies = try keys.map {
            try execution.dependency(ExecutionFixtures.dependencyKey($0, as: Dependency.self))
        }
        return (execution, dependencies)
    }
}

/// A controlled suspension inside one delivery, with no elapsed-time inference.
final class SchedulerDeliveryGate: Sendable {
    private let entry = AsyncStream<Void>.makeStream()
    private let releaseSignal = AsyncStream<Void>.makeStream()

    func suspend() async {
        entry.continuation.finish()
        for await _ in releaseSignal.stream {}
    }

    func waitForEntry() async {
        for await _ in entry.stream {}
    }

    func release() {
        releaseSignal.continuation.finish()
    }
}
