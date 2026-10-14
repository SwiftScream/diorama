import DioramaCore
import DioramaDate
import Foundation
import Synchronization
import Testing

struct WallDiagnosticTests {
    @Test func `conversion failure preserves live reads and completed diagnostic facts`() async throws {
        let unsupported = Date(timeIntervalSince1970: 100_000_000_000_000)
        let source = DiagnosticWallProbe(values: [
            unsupported, Date(timeIntervalSince1970: 17),
            Date(timeIntervalSince1970: 18), Date(timeIntervalSince1970: 19),
        ])
        let system = try DioramaDateSystem.instance(named: "conversion") { source }
        let execution = try await ScenarioExecution.start(
            definition: ScenarioDefinition(attachments: [system.attachment]), scenarioID: .init(rawValue: "conversion"),
            defaultMode: .record, systems: [AnyScenarioSystem(system)])
        let wall = try execution.dependency(system)
        #expect(wall.now == unsupported)
        #expect(execution.reporter.report == nil)
        #expect(wall.now == Date(timeIntervalSince1970: 17))
        #expect(wall.now == Date(timeIntervalSince1970: 18))
        let final = await execution.finish()
        #expect(final.report.diagnostics.map(\.diagnostic.issue) == [.conversionFailed])
        #expect(final.definition == nil)
        #expect(final.usage[0].tracks[0].activity == .record(recordedCount: 2, incompleteCount: 1))
        #expect(wall.now == Date(timeIntervalSince1970: 19))
        #expect(source.reads.withLock { $0 } == 4)
        #expect(execution.reporter.postFinishDiagnostics.map(\.diagnostic.issue) == [.lifecycle(.leaseClosed)])
        #expect(await execution.finish().report == final.report)
    }
}

private final class DiagnosticWallProbe: DioramaDateSource {
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
