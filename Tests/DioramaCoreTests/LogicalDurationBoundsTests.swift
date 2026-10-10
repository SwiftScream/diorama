@testable import DioramaCore
import Testing

struct LogicalDurationBoundsTests {
    private let attosecond = Duration(secondsComponent: 0, attosecondsComponent: 1)

    @Test
    func `checked addition rejects oversized operands before component extraction`() {
        let limit = Duration.maximumLogicalTime
        for outside in [limit + attosecond, .seconds(Int64.max) * 2] {
            #expect(Duration.zero.checkedLogicalTime(adding: outside) == nil)
            #expect(outside.checkedLogicalTime(adding: .zero) == nil)
            #expect(outside.checkedLogicalTime(adding: outside) == nil)
        }
        #expect(limit.checkedLogicalTime(adding: .zero) == limit)
        #expect(Duration.zero.checkedLogicalTime(adding: limit) == limit)
        #expect((limit - attosecond).checkedLogicalTime(adding: attosecond) == limit)
        #expect(limit.checkedLogicalTime(adding: attosecond) == nil)
        #expect(Duration.seconds(1).checkedLogicalTime(adding: .milliseconds(125)) == .milliseconds(1125))
        #expect(Duration.zero.checkedLogicalTime(adding: .zero) == .zero)
        #expect(Duration.seconds(-1).checkedLogicalTime(adding: .seconds(1)) == nil)
        #expect(Duration.zero.checkedLogicalTime(adding: .seconds(-1)) == nil)
    }

    @Test
    func `elapsed checks bound operands even when their difference would fit`() {
        let limit = Duration.maximumLogicalTime
        for outside in [limit + attosecond, .seconds(Int64.max) * 2] {
            #expect(outside.checkedElapsed(since: .zero) == nil)
            #expect(outside.checkedElapsed(since: outside) == nil)
            #expect(outside.checkedElapsed(since: outside - attosecond) == nil)
            #expect(Duration.zero.checkedElapsed(since: outside) == nil)
        }
        #expect(limit.checkedElapsed(since: limit - attosecond) == attosecond)
        #expect(limit.checkedElapsed(since: .zero) == limit)
        #expect(Duration.zero.checkedElapsed(since: .zero) == .zero)
        #expect(Duration.seconds(1).checkedElapsed(since: .milliseconds(125)) == .milliseconds(875))
        #expect(Duration.zero.checkedElapsed(since: .seconds(-1)) == nil)
        #expect(Duration.seconds(-1).checkedElapsed(since: .zero) == nil)
    }
}
