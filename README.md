# Diorama

Diorama is a Swift library for recording and replaying deterministic
representations of nondeterministic dependencies during tests.

The name reflects its purpose: a carefully authored, static representation of
a complex environment. A scenario may contain several independently named
systems, including multiple instances of the same system, and consumers may add
their own systems alongside the first-party implementations.

## Status

Diorama is currently design-complete but not yet implemented. The repository
starts from a documentation-only baseline so that the production architecture
is built deliberately rather than inherited from the earlier network snapshot
proof of concept.

The owner approved the [design](docs/design-overview.md) and
[implementation plan](docs/plans/003-clean-slate-implementation.md) on 2026-09-07.
The plan divides implementation into small, independently reviewable changes;
each unit requires owner scope confirmation before work begins. Implementation
has not started.

## Initial scope

The accepted design covers:

- a concurrency-safe scenario execution with record, replay, and passthrough
  modes;
- heterogeneous, independently keyed system attachments;
- optional deterministic `Codable` persistence and external resources;
- structured diagnostics and opt-in test failure integration;
- one-to-one real-time replay scheduling;
- a small random-number proving system;
- wall-clock observation and monotonic sleeping;
- portable location replay with an Apple Core Location recording adapter;
- shared HTTP semantics and a URLSession adapter for Apple Foundation and
  FoundationNetworking.

Replay never contacts a live dependency when a recording is missing,
ambiguous, incompatible, or exhausted.

## Documentation

Start with the [documentation index](docs/README.md). The
[design decision index](docs/design-decisions/README.md) links the seventeen
accepted decisions, and the
[design overview](docs/design-overview.md) consolidates
their architecture and deferred scope.

Dependency adoption is governed by
[the dependency policy](docs/dependency-policy.md). Formatting, linting,
platform CI, strict concurrency, and coverage expectations are defined by
[the quality gates and CI policy](docs/quality-gates-and-ci.md).

## Development

All work takes place on feature branches. The owner confirms each atomic slice's
scope before implementation; feature-branch commits and history rewrites,
including published history, are permitted within that scope. The complete
branch diff is reviewed before approval to push and create a PR. Merging
requires passing required CI and a separate explicit owner request.
See [AGENTS.md](AGENTS.md) for repository operating rules and the
[implementation plan](docs/plans/003-clean-slate-implementation.md) for the
review units and workflow.

The initial platform objective is macOS 13 and later, iOS 16 and later, and Linux.
Individual systems may have narrower live-recording availability while retaining
portable stable models and replay behavior.

## License

See [LICENSE](LICENSE).
