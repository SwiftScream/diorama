# Execution logical time

Every successful scenario execution has one monotonic `ContinuousClock` origin.
The origin is captured after all configured systems activate, immediately before
startup returns. All attachments in that execution share the same time service
and one-to-one rate; a later execution has its own origin.

A system receives `ExecutionTime` through `SystemPreparationContext.time`. It
may retain the service in its per-execution dependency. `logicalNow()` returns
the `Duration` since completed startup. `capture()` reserves an observation's
monotonic time and execution-local order. Call it at the observation boundary,
before native extraction or stable conversion that may take time. Later, use
`logicalTime(at:)` or `elapsed(from:to:)` to derive the relative timing that the
system's stable model actually needs. `capturedBefore(_:_:)` compares observation
order even when conversions complete in another order.

Captures are runtime-only tokens. Consumers cannot construct them, and they
have no `Codable` conformance or stable representation. They cannot be combined
across executions. Their order is not a
persisted cross-track ordering constraint. Stable schemas retain only the
capability-specific durations needed to reproduce behavior; synchronous random
observations remain untimed. `logicalTime(after:from:)` adds a nonnegative delay
to a captured anchor with overflow checking, without scheduling delivery.

The service rejects new clock reads before completed startup and after execution admission
closes. A backward clock source, foreign or reversed captures, negative delay,
and unrepresentable duration produce typed failures and safe diagnostics.
Existing tokens can still be inspected after finish; new time observations
cannot be captured. The deadline engine and timed delivery arrive in later
Phase E units.
