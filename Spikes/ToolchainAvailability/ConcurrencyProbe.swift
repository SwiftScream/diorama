// Each feature is tested separately so disabling it must fail for its own reason.
#if CALLER_ISOLATION
    private final class CallerOwnedValue {
        var value = 0

        func increment() async {
            value += 1
        }
    }

    @MainActor
    private final class CallerOwner {
        private let value = CallerOwnedValue()

        func verify() async {
            await value.increment()
            precondition(value.value == 1)
        }
    }
#endif

#if ISOLATED_CONFORMANCE
    private protocol ValueSource {
        var value: Int { get }
    }

    @MainActor
    private final class MainActorSource: ValueSource {
        var value: Int {
            42
        }
    }

    @MainActor
    private func read(_ source: some ValueSource) -> Int {
        source.value
    }

    @MainActor
    private func verifyIsolatedConformance() {
        precondition(read(MainActorSource()) == 42)
    }
#endif

@concurrent
private func concurrentValue() async -> Int {
    7
}

/// This would require an actor hop if the module default were MainActor.
private final class OrdinaryValue {
    var value = 3
}

private nonisolated func readOrdinaryValue() -> Int {
    OrdinaryValue().value
}

@main
private enum ConcurrencyProbe {
    static func main() async {
        #if CALLER_ISOLATION
            await CallerOwner().verify()
        #endif
        #if ISOLATED_CONFORMANCE
            verifyIsolatedConformance()
        #endif
        let value = await concurrentValue()
        precondition(value == 7)
        precondition(readOrdinaryValue() == 3)
        print("PASS: caller isolation, inferred isolated conformance, @concurrent, nonisolated default")
    }
}
