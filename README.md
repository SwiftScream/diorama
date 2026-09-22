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

## Modules

Import `Diorama` when writing tests, together with the systems you use, such as
`DioramaRandom`. Setup takes a string scenario ID and default mode, accepts a
file URL, and coordinates in-memory or file-backed runs.

`DioramaCore` provides the execution engine and system authoring contracts.
`DioramaPersistence` provides codecs, repositories, and storage over core
definitions. Both remain available independently. Importing the consumer module
links persistence internally; in-memory runs require neither a store nor
persistable systems.
System authors and callers constructing low-level tracks import `DioramaCore`.
Callers configuring codecs or custom storage import `DioramaPersistence`.

## Usage example

The repository includes a compiled, in-memory random record/replay example:

```sh
swift run --package-path Examples DioramaRandomUsage
```

It prints matching recorded and replayed values. The example imports
`DioramaCore` to construct its explicit in-memory replay baseline; ordinary
setup uses `Diorama` and `DioramaRandom`. Each scoped execution finalizes.
It lives in a separate examples package that depends on Diorama by a relative
path, so the Diorama library package remains library-only. Automatic publication and
record-to-replay transfer arrive in a later implementation phase.

## Development

Development uses Xcode 27.0 and its Swift 6.4 toolchain. Install
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
run. Every platform exports repository-relative LCOV for Codecov; coverage
artifacts stay under the ignored `.build` directory.

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
