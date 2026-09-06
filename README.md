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

The next repository artifact is a clean-slate implementation plan divided into
small, independently reviewable changes.

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

All work takes place on feature branches. Changes are implemented as small
atomic slices, reviewed before commit, and merged only after explicit approval.
See [CONTRIBUTING.md](CONTRIBUTING.md) for the shared workflow and
[AGENTS.md](AGENTS.md) for agent-specific operating rules.

The initial platform objective is macOS, iOS 15 and later, and Linux. Individual
systems may have narrower live-recording availability while retaining portable
stable models and replay behavior.

## License

See [LICENSE](LICENSE).
