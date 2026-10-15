import DioramaCore
import Synchronization
import Testing

/// A cancellation-independent gate; tests explicitly release every suspension.
final class ResourceGate: Sendable {
    private struct State: Sendable {
        var open = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())
    private let entered = AsyncStream<Void>.makeStream()

    func suspend() async {
        await withCheckedContinuation { continuation in
            let open = state.withLock { state in
                if state.open {
                    return true
                }
                state.waiters.append(continuation)
                return false
            }
            entered.continuation.finish()
            if open {
                continuation.resume()
            }
        }
    }

    func waitForEntry() async {
        for await _ in entered.stream {}
    }

    func release() {
        let waiters = state.withLock { state in
            state.open = true
            let waiters = state.waiters
            state.waiters = []
            return waiters
        }
        for waiter in waiters {
            waiter.resume()
        }
    }
}

final class ResourceJournal: Sendable {
    let events = Mutex<[String]>([])
    func append(_ event: String) {
        events.withLock { $0.append(event) }
    }

    var values: [String] {
        events.withLock { $0 }
    }
}

@MainActor final class ResourceNative {
    let name: String
    let journal: ResourceJournal
    let work: ResourceGate?
    let cleanup: ResourceGate?
    let failure: Bool
    private(set) var stopped = false
    var capture: ResourceReleaseWitness?
    var stopCallback: (@MainActor @Sendable () -> Void)?

    init(_ name: String, journal: ResourceJournal, work: ResourceGate? = nil,
         cleanup: ResourceGate? = nil, failure: Bool = false)
    {
        self.name = name
        self.journal = journal
        self.work = work
        self.cleanup = cleanup
        self.failure = failure
        journal.append("create-" + name)
    }

    func inspect() -> Bool {
        !stopped
    }

    func callback() async -> Bool {
        await work?.suspend()
        return !stopped
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        journal.append("stop-" + name)
        work?.release()
        stopCallback?()
        stopCallback = nil
    }

    func end() async -> SystemCleanupResult {
        #expect(stopped)
        journal.append("end-enter-" + name)
        await cleanup?.suspend()
        journal.append("end-" + name)
        return failure ? .failed(DiagnosticLabel("resource-cleanup-failed")) : .completed
    }

    deinit { journal.append("release-" + name) }
}

@MainActor final class ResourceWeakBox {
    weak var first: ResourceNative?
    weak var second: ResourceNative?
}

struct ResourceState: Sendable {
    let first: ResourceNative
    let second: ResourceNative
    var observations = 0
}

enum ResourceTestFailure: Error { case expected }

struct ResourceDefinition: SystemDefinition {
    let systemType = ScenarioSystemType("consumer.resources")
    let events = TrackDefinition<Int, Void>("events")
    var tracks: [AnyTrackDefinition] {
        [events.erased]
    }

    let journal: ResourceJournal
    let weak: ResourceWeakBox
    var construction: ResourceGate?
    var work: ResourceGate?
    var cleanup: ResourceGate?
    var failValidation = false
    var failConstruction = false
    var failDependency = false
    var failCleanup = false
    var checkConstructionCancellation = false

    func validate(in _: borrowing SystemValidationContext) throws {
        journal.append("validate")
        if failValidation {
            throw ResourceTestFailure.expected
        }
    }

    var record: SystemModeDefinition<ResourceState, SystemExecution<ResourceState>> {
        .init(makeState: makeRecordState, makeDependency: makeRecordDependency,
              requestStop: requestStopRecord, cleanUp: cleanUpRecord)
    }

    var replay: SystemModeDefinition<ResourceState, SystemExecution<ResourceState>> {
        .init(makeState: makeReplayState, makeDependency: makeReplayDependency,
              requestStop: requestStopReplay, cleanUp: cleanUpReplay)
    }

    var passthrough: SystemModeDefinition<Void, SystemExecution<ResourceState>> {
        .init(makeDependency: makePassthroughDependency)
    }

    @MainActor
    func makeRecordState(in context: borrowing SystemStateContext) async throws -> ResourceState {
        let key = context.attachmentID.key.rawValue
        let first = ResourceNative(key + "-a", journal: journal)
        let second = ResourceNative(key + "-b", journal: journal, work: work, cleanup: cleanup, failure: failCleanup)
        weak.first = first
        weak.second = second
        do {
            await construction?.suspend()
            if checkConstructionCancellation {
                try Task.checkCancellation()
            }
            if failConstruction {
                throw ResourceTestFailure.expected
            }
            return ResourceState(first: first, second: second)
        } catch {
            // Ordinary throwing-factory responsibility, with no Core registration.
            second.stop()
            first.stop()
            _ = await second.end()
            _ = await first.end()
            throw error
        }
    }

    @MainActor
    func makeReplayState(in context: borrowing SystemStateContext) async throws -> ResourceState {
        try await makeRecordState(in: context)
    }

    @MainActor
    func makeRecordDependency(using systemExecution: SystemExecution<ResourceState>) throws
        -> SystemExecution<ResourceState>
    {
        #expect(try systemExecution.state.withTrackedValue(\.first) { $0.inspect() })
        if case .performed = try systemExecution.state.withTrackedValueIfOpen(\.first, { $0.inspect() }) {
            Issue.record("Quiet callbacks entered before publication")
        }
        if case .performed = try systemExecution.state.withLockIfOpen({ _, _ in () }) {
            Issue.record("Quiet state observations entered before publication")
        }
        if failDependency {
            throw ResourceTestFailure.expected
        }
        return systemExecution
    }

    @MainActor
    func makeReplayDependency(using systemExecution: SystemExecution<ResourceState>) throws
        -> SystemExecution<ResourceState>
    {
        try makeRecordDependency(using: systemExecution)
    }

    @MainActor
    func requestStopRecord(using lifecycle: borrowing SystemLifecycleContext<ResourceState>,
                           dependency _: SystemExecution<ResourceState>?)
    {
        guard let natives = try? lifecycle.state.withLock({ ($0.second, $0.first) }) else { return }
        natives.0.stop()
        natives.1.stop()
    }

    @MainActor
    func cleanUpRecord(using lifecycle: borrowing SystemLifecycleContext<ResourceState>,
                       dependency _: SystemExecution<ResourceState>?) async -> SystemCleanupResult
    {
        guard let natives = try? lifecycle.state.withLock({ ($0.second, $0.first) }) else { return .completed }
        let result = await natives.0.end()
        _ = await natives.1.end()
        return result
    }

    @MainActor
    func requestStopReplay(using lifecycle: borrowing SystemLifecycleContext<ResourceState>,
                           dependency: SystemExecution<ResourceState>?)
    {
        requestStopRecord(using: lifecycle, dependency: dependency)
    }

    @MainActor
    func cleanUpReplay(using lifecycle: borrowing SystemLifecycleContext<ResourceState>,
                       dependency: SystemExecution<ResourceState>?) async -> SystemCleanupResult
    {
        await cleanUpRecord(using: lifecycle, dependency: dependency)
    }

    func makePassthroughDependency(using _: SystemExecution<Void>) throws -> SystemExecution<ResourceState> {
        throw ResourceTestFailure.expected
    }
}

func startResource(_ definition: ResourceDefinition, mode: ScenarioMode = .record) async throws
    -> (ScenarioExecution, SystemExecution<ResourceState>)
{
    let system = try ScenarioSystem(named: "native", definition: definition)
    let execution = try await ScenarioExecution.start(
        definition: ScenarioDefinition(attachments: [system.attachment]),
        scenarioID: .init(rawValue: "resources"), defaultMode: mode, systems: [AnyScenarioSystem(system)])
    return try (execution, execution.dependency(system))
}

final class ResourceReleaseWitness: Sendable {
    let action: @Sendable () -> Void
    init(_ action: @escaping @Sendable () -> Void) {
        self.action = action
    }

    deinit { action() }
}
