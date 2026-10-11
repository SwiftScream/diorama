import DioramaCore
import DioramaDate
import Foundation
import Synchronization
import Testing

struct WallDiagnosticReentryTests {
    @Test func `conversion failure commits continuation before a sink rereads the same wall source`() async throws {
        let unsupported = Date(timeIntervalSince1970: 100_000_000_000_000)
        let source = ReentrantWallProbe(values: [
            unsupported, Date(timeIntervalSince1970: 17), Date(timeIntervalSince1970: 18),
        ])
        let callback = Mutex<(@Sendable () -> Void)?>(nil)
        let system = try DioramaDateSystem.instance(named: "reentry") { source }
        let execution = try ScenarioExecution.start(
            definition: ScenarioDefinition(attachments: [system.attachment]), scenarioID: .init(rawValue: "reentry"),
            defaultMode: .record, systems: [AnyScenarioSystem(system)], sink: DiagnosticSink { reported in
                guard reported.diagnostic.issue == .conversionFailed else { return }
                let reenter = callback.withLock { stored in
                    let detached = stored
                    stored = nil
                    return detached
                }
                reenter?()
            })
        let wall = try execution.dependency(system)
        callback.withLock { $0 = {
            // This source read reacquires the same Core state protection.
            #expect(wall.now == Date(timeIntervalSince1970: 17))
        } }
        #expect(wall.now == unsupported)
        #expect(wall.now == Date(timeIntervalSince1970: 18))
        let final = await execution.finish()
        #expect(final.report.diagnostics.map(\.diagnostic.issue) == [.conversionFailed])
        #expect(final.definition == nil)
        #expect(final.usage[0].tracks[0].activity == .record(recordedCount: 2, incompleteCount: 1))
        #expect(wall.now == Date(timeIntervalSince1970: 18))
        #expect(source.reads.withLock { $0 } == 3)
    }
}

private final class ReentrantWallProbe: DioramaDateSource {
    let reads = Mutex(0)
    let values: [Date]

    init(values: [Date]) {
        self.values = values
    }

    var now: Date {
        reads.withLock { count in
            defer { count += 1 }
            return values[count]
        }
    }
}
