# Diorama

Diorama is a Swift library for recording and replaying deterministic
representations of nondeterministic dependencies during tests.

The name reflects its purpose: a carefully authored, static representation of
a complex environment. A scenario may contain several independently named
systems, including multiple instances of the same system, and consumers may add
their own systems alongside the first-party implementations.

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

Development currently uses Xcode 27.0 beta 6 and its Swift 6.4 toolchain under
the recorded bootstrap exception. Install
[Mint 0.18.0](https://github.com/yonaskolb/Mint/releases/tag/0.18.0), then install
the repository's exact SwiftFormat and SwiftLint versions:

```sh
mint bootstrap
```

Use `scripts/format` to apply formatting, `scripts/lint` for non-mutating format
and lint checks, `scripts/test` for debug tests and a release build, and
`scripts/check` for the complete non-mutating local gate. A missing or different
Mint version fails without downloading code; a missing executable also prints
the exact version and installation URL.
Use `scripts/coverage swiftpm macos` for local SwiftPM coverage or
`scripts/coverage ios` for the pinned iOS Simulator build, test, and coverage
run. Coverage artifacts stay under the ignored `.build` directory.

All work takes place on feature branches. The owner confirms each atomic slice's
scope before implementation; feature-branch commits and history rewrites,
including published history, are permitted within that scope. The complete
branch diff is reviewed before approval to push and create a PR. Merging
requires passing required CI and a separate explicit owner request.
See [AGENTS.md](AGENTS.md) for repository operating rules and the
[implementation plan](docs/plans/003-clean-slate-implementation.md) for the
review units and workflow.

The initial platform objective is macOS 15 and later, iOS 18 and later, and Linux.
Individual systems may have narrower live-recording availability while retaining
portable stable models and replay behavior.

## License

See [LICENSE](LICENSE).
