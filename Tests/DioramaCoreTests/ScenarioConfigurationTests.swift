import DioramaCore
import Testing

struct ScenarioConfigurationTests {
    @Test(arguments: [false, true])
    func `unknown policy keys fail before preparation`(ignored: Bool) throws {
        let journal = ExecutionFixtures.Journal()
        let definition = try ExecutionFixtures.definition(["a"])
        let unknown = AttachmentKey(rawValue: "missing")
        let configuration = ScenarioConfiguration(
            id: ScenarioID(rawValue: "policy"), defaultMode: .replay,
            modeOverrides: ignored ? [:] : [unknown: .record],
            ignoredAttachments: ignored ? [unknown] : [])
        #expect(throws: ScenarioStartupFailure.self) {
            try ScenarioExecution.start(
                definition: definition, configuration: configuration,
                systems: [ExecutionFixtures.system("a", journal: journal)])
        }
        #expect(journal.events.withLock { $0.isEmpty })
    }

    @Test
    func `unknown overrides are reported in lexical order`() throws {
        let first = AttachmentKey(rawValue: "a")
        let last = AttachmentKey(rawValue: "z")
        let configuration = ScenarioConfiguration(
            id: ScenarioID(rawValue: "policy"), defaultMode: .record,
            modeOverrides: [last: .replay, first: .passthrough])
        #expect(throws: ScenarioConfigurationError.unknownModeOverride(first)) {
            try configuration.validate(against: ScenarioDefinition())
        }
    }
}
