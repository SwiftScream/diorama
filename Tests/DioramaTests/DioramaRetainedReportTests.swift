import Diorama
import DioramaCore
import Synchronization
import Testing

struct DioramaRetainedReportTests {
    private enum BodyFailure: Error, Equatable { case stopped }

    @Test
    func `references share reports while sequential attempts replace only the stored snapshot`() async throws {
        let probe = DioramaSetupProbe()
        let setup = try Diorama(scenarioID: "reports", mode: .record, systems: probe.system("a"))
        let alias = setup
        #expect(alias === setup)
        #expect(setup.report == nil)
        let first = try await setup.execute { _, lease in
            #expect(alias.report == nil)
            _ = lease.report(.system(DiagnosticLabel("first")))
            return lease
        }
        let saved = try #require(alias.report)
        #expect(saved == first.report)
        #expect(saved.diagnostics.map(\.diagnostic.issue) == [.system(DiagnosticLabel("first"))])
        let second = try await alias.execute { _, _ in
            #expect(setup.report == nil)
        }
        #expect(setup.report == second.report)
        #expect(second.report.diagnostics.isEmpty)
        #expect(saved == first.report)
        _ = first.body.report(.system(DiagnosticLabel("late")))
        #expect(setup.report == second.report)
        #expect(saved == first.report)
    }

    @Test
    func `body errors retain cleanup diagnostics before escaping and allow reuse`() async throws {
        let system = try ScenarioSystem(named: "a", definition: LifecycleDefinition(
            factory: { 42 }, cleanup: { throw BodyFailure.stopped }))
        let setup = try Diorama(scenarioID: "failed-body", mode: .record, systems: system)
        do {
            _ = try await setup.execute { _, _ async throws(BodyFailure) -> Int in throw .stopped }
            Issue.record("The body error was lost")
        } catch {
            #expect(error as? BodyFailure == .stopped)
            #expect(setup.report?.diagnostics.map(\.diagnostic.issue) == [
                .system(DiagnosticLabel("fixture-cleanup-failed")), .lifecycle(.cleanupFailed),
            ])
        }
        let result = try await setup.execute { _, value in value }
        #expect(result.body == 42)
        #expect(setup.report == result.report)
    }

    @Test
    func `failed startup clears an older report and releases admission after rollback`() async throws {
        let probe = DioramaSetupProbe()
        let attempts = Mutex(0)
        let second = try ScenarioSystem(named: "b", definition: LifecycleDefinition(factory: {
            let attempt = attempts.withLock { count in
                count += 1
                return count
            }
            if attempt == 2 {
                throw BodyFailure.stopped
            }
            return true
        }))
        let setup = try Diorama(scenarioID: "retry", mode: .record, systems: probe.system("a"), second)
        let first = try await setup.execute { _, _, _ in }
        #expect(setup.report == first.report)
        do {
            _ = try await setup.execute { _, _, _ in Issue.record("Failed startup invoked the body") }
            Issue.record("Expected startup failure")
        } catch let failure as ScenarioStartupFailure {
            #expect(failure.report.diagnostics.map(\.diagnostic.issue) == [.lifecycle(.activationFailed)])
            #expect(failure.cleanup.map(\.disposition) == [.completed, .completed])
            #expect(setup.report == nil)
        }
        #expect(probe.events.withLock { $0.filter { $0 == "cleanup-a" }.count } == 2)
        let third = try await setup.execute { _, _, _ in }
        #expect(setup.report == third.report)
        #expect(attempts.withLock { $0 } == 3)
    }

    @Test
    func `retained reports release body values errors and activated dependencies`() async throws {
        let releases = Mutex(0)
        let descriptions = Mutex(0)
        let system = try ScenarioSystem(named: "a", definition: LifecycleDefinition(factory: {
            ReportLifetimeProbe(onRelease: { releases.withLock { $0 += 1 } })
        }))
        let setup = try Diorama(scenarioID: "lifetime", mode: .record, systems: system)
        do {
            let result = try await setup.execute { _, dependency in dependency }
            #expect(releases.withLock { $0 } == 0)
            #expect(setup.report == result.report)
            withExtendedLifetime(result) {}
        }
        #expect(releases.withLock { $0 } == 1)
        do {
            _ = try await setup.execute { _, dependency -> Int in
                throw RetainedBodyError(resource: dependency, onDescription: { descriptions.withLock { $0 += 1 } })
            }
            Issue.record("Expected body failure")
        } catch {
            #expect(error is RetainedBodyError)
            #expect(setup.report != nil)
        }
        #expect(releases.withLock { $0 } == 2)
        #expect(descriptions.withLock { $0 } == 0)
        #expect(setup.report?.rendered().contains("SECRET-BODY-ERROR") == false)
        withExtendedLifetime(setup) {}
    }
}

private final class ReportLifetimeProbe: Sendable {
    private let onRelease: @Sendable () -> Void

    init(onRelease: @escaping @Sendable () -> Void) {
        self.onRelease = onRelease
    }

    deinit { onRelease() }
}

private struct RetainedBodyError: Error, CustomStringConvertible {
    let resource: ReportLifetimeProbe
    let onDescription: @Sendable () -> Void

    var description: String {
        onDescription()
        return "SECRET-BODY-ERROR"
    }
}
