import DioramaCore
import Testing

struct OverridableValueTests {
    private struct NonEquatable: Sendable {
        let value: Int
    }

    @Test
    func `effective value and authorship remain distinct`() {
        let observed = OverridableValue<Int>.observed(5)
        let overridden = OverridableValue<Int>.override(5)

        #expect(observed.value == 5)
        #expect(!observed.isOverride)
        #expect(overridden.value == 5)
        #expect(overridden.isOverride)
        #expect(observed != overridden)
    }

    @Test
    func `mapping preserves authorship without requiring equatable values`() {
        let observed = OverridableValue.observed(NonEquatable(value: 3))
        let overridden = OverridableValue.override(NonEquatable(value: 7))

        #expect(observed.map { String($0.value) } == .observed("3"))
        #expect(overridden.map { String($0.value) } == .override("7"))
    }
}
