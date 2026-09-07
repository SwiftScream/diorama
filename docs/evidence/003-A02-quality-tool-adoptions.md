# 003-A02: Quality-tool adoption proposal

- Date: 2026-09-07
- Plan: [003-A02](../plans/003-clean-slate-implementation.md#003-a02--quality-tool-adoption-records)
- Status: Complete; owner approved the development-tool and GitHub Actions source records on 2026-09-07.
- Authority: [Dependency approval policy](../dependency-policy.md), [quality gates and CI policy](../quality-gates-and-ci.md), and 003-A02.

## Scope and disposition

This is an approval proposal. It does not add a `Mintfile`, `Package.swift`
dependency, formatter/linter configuration, executable installation, GitHub
Actions workflow, Dependabot configuration, or Codecov configuration. Those
belong to 003-A04 after approval and 003-A03's minimal package skeleton.

The proposed tools are development and CI inputs only. They do not become
Diorama library products, runtime dependencies, or transitive dependencies of
consuming applications.

## Proposed development-tool adoption

| Tool | Source, product, and initial immutable revision | Version policy | License and maintenance | Platform and toolchain impact |
| --- | --- | --- | --- | --- |
| Mint | [yonaskolb/Mint](https://github.com/yonaskolb/Mint), `mint` executable; release `0.18.0`, `7bc67a0b925b949c8becc327bc08f56eeadc0051` | Bootstrap exactly `0.18.0`; any change is an ordinary reviewed maintenance change. | MIT; repository active on the evidence date. | `swift-tools-version: 5.9`; supports Linux with cache invalidation when Swift changes. Build against the selected Swift 6.4 toolchain before use. |
| SwiftFormat | [nicklockwood/SwiftFormat](https://github.com/nicklockwood/SwiftFormat), `swiftformat` executable; release `0.63.0`, `0256422f1a5e967c68dc923f1905c0a155dca188` | Pin `0.63.0` in `Mintfile`; permit reviewed updates `>= 0.63.0, < 0.64.0`. | MIT; repository active on the evidence date. | `swift-tools-version: 5.7`; documented for macOS, Linux, and Windows. Diorama runs it only in the macOS quality job, with Swift 6.4 and language mode 6 configured explicitly. |
| SwiftLint | [realm/SwiftLint](https://github.com/realm/SwiftLint), `swiftlint` executable; release `0.65.1`, `488642e6fc30e5ffc2b5eb24707bf1c7801f3f19` | Pin `0.65.1` in `Mintfile`; permit reviewed updates `>= 0.65.1, < 0.66.0`. | MIT; repository active on the evidence date. | `swift-tools-version: 5.9`; package declares macOS 13 and includes Linux-specific dependencies. The executable is built with selected Swift 6.4; lint runs in the macOS quality job. |

Mint supplies the executable resolver and cache that makes one exact
`Mintfile` authoritative for SwiftFormat and SwiftLint. It is preferable to
Homebrew because Homebrew selects one mutable global tool version, and to Swift
package plugins because those would enter Diorama's production manifest. Direct
per-developer installation would not give local and CI the same resolver.

SwiftFormat is the automatic formatter selected by the quality policy. It is
separate from SwiftLint, whose rule set covers documentation, correctness, and
style checks that formatting does not. Apple `swift-format` was considered but
is not the accepted policy choice; replacing either selected tool would require
a policy amendment rather than a convenience substitution.

## Resolved transitive graph

The following is the release-lock graph reviewed for these initial pins. It
describes tool-build inputs only; it is not a Diorama package dependency graph.

### Mint 0.18.0

Mint directly declares PathKit 1.0.1, Rainbow 4.0.1, SwiftCLI 6.0.3, and
Version 2.0.1. Its release lock also contains test dependency Spectre 0.10.1.

| Package | Resolved version | Revision |
| --- | --- | --- |
| PathKit | 1.0.1 | `3bfd2737b700b9a36565a8c94f4ad2b050a5e574` |
| Rainbow | 4.0.1 | `e0dada9cd44e3fa7ec3b867e49a8ddbf543e3df3` |
| Spectre (test only) | 0.10.1 | `26cc5e9ae0947092c7139ef7ba612e34646086c7` |
| SwiftCLI | 6.0.3 | `2e949055d9797c1a6bddcda0e58dada16cc8e970` |
| Version | 2.0.1 | `1fe824b80d89201652e7eca7c9252269a1d85e25` |

### SwiftFormat 0.63.0

SwiftFormat has no external SwiftPM package dependencies in its release
manifest. The selected product is its command-line executable; its library and
command plugin are not adopted.

### SwiftLint 0.65.1

SwiftLint directly declares swift-argument-parser 1.6.1 or newer within major
1, exact prerelease swift-syntax `605.0.0-prerelease-2026-06-26`, SourceKitten
0.38.0 or newer within major 0, Yams 6.0.2 or newer within major 6,
SwiftyTextTable 0.9.0 or newer within major 0, CollectionConcurrencyKit 0.2.0
or newer within major 0, CryptoSwift 1.9.0 or newer within major 1, and
swift-filename-matcher 2.0.1 or newer within minor 2.0. The release lock resolves:

| Package | Resolved version | Revision |
| --- | --- | --- |
| CollectionConcurrencyKit | 0.2.0 | `b4f23e24b5a1bff301efc5e70871083ca029ff95` |
| CryptoSwift | 1.10.0 | `f2a627b84c1ff96f21ac2fcb623ab36142dd5512` |
| SourceKitten | 0.38.0 | `821fc0eaa7c07fc98df1e9d3d43371cace697644` |
| swift-argument-parser | 1.8.2 | `6a52f3251125d74daf04fcbd5e6f08a75d074382` |
| swift-filename-matcher | 2.0.1 | `eef5ac0b6b3cdc64b3039b037bed2def8a1edaeb` |
| swift-syntax | 605.0.0-prerelease-2026-06-26 | `a8b1c535647243d603b6772e7e8306c993a0c188` |
| SwiftyTextTable | 0.9.0 | `c6df6cf533d120716bff38f8ff9885e1ce2a4ac3` |
| SWXMLHash | 7.0.2 | `a853604c9e9a83ad9954c7e3d2a565273982471f` |
| Yams | 6.2.2 | `a27b21e0c81e5bf42049b897a62aaf387e80f279` |

The prerelease swift-syntax transitive package is acceptable only as a
development-tool input under this proposal. Its selected release and Swift 6.4
build remain an explicit 003-A04 verification requirement. It does not grant
permission to add a prerelease dependency to Diorama products.

## URITemplate baseline review

The baseline is [SwiftScream/URITemplate at
`69617832445c1a928e07366d0a68966e5326cea4`](https://github.com/SwiftScream/URITemplate/tree/69617832445c1a928e07366d0a68966e5326cea4).
It pins SwiftLint 0.63.2 and SwiftFormat 0.61.1 in a Mintfile, excludes build
directories, and keeps formatter and linter responsibilities distinct.

003-A04 should use it as a starting point, with these deliberate Diorama
adjustments:

- Use the approved newer pins and set SwiftFormat's Swift version to 6.4 and
  language mode to 6.
- Retain the `.build` exclusion and add only generated paths that actually
  exist. Do not copy URITemplate's `Benchmarks/.build` exclusion because this
  repository has no benchmark package.
- Retain SwiftLint's strict invocation, build-directory exclusion, maximum two
  consecutive blank lines, mandatory trailing commas, and documentation-rule
  posture once the first public declaration exists.
- Resolve formatter/linter overlap deliberately in one configuration. Carry no
  disabled rule forward merely because it appears in URITemplate; test each
  candidate against Diorama's first real source.

No `.swiftformat` or `.swiftlint.yml` is added in this unit, because 003-A04
owns the pinned tool declarations, configuration, and intentional failure
checks.

## Proposed GitHub Actions sources and immutable pins

Only the actions required by the quality policy are proposed. 003-A04 should
use full revisions with the shown release comments, least-privilege job
permissions, and concurrency cancellation. `setup-mint` owns Mint caching;
`actions/cache` owns cache keys for Diorama SwiftPM artifacts, including the
platform, architecture, selected toolchain, and relevant manifests.

| Source | Proposed immutable pin | Purpose | License |
| --- | --- | --- | --- |
| [actions/checkout](https://github.com/actions/checkout) | `3d3c42e5aac5ba805825da76410c181273ba90b1` (`v7.0.1`) | Check out Diorama for every job. | MIT |
| [actions/cache](https://github.com/actions/cache) | `55cc8345863c7cc4c66a329aec7e433d2d1c52a9` (`v6.1.0`) | Cache Diorama SwiftPM artifacts after a complete cache-key design exists. | MIT |
| [irgaly/setup-mint](https://github.com/irgaly/setup-mint) | `8566ee44b3a79d20642d1924db21c8ab0402859f` (`v1`) | Install the exact Mint version recorded in `Mintfile`, bootstrap declared tools, and cache Mint on macOS and Linux. | Apache-2.0 |
| [codecov/codecov-action](https://github.com/codecov/codecov-action) | `fb8b3582c8e4def4969c97caa2f19720cb33a72f` (`v7.0.0`) | Upload required macOS, iOS, and Linux coverage with separate flags; fail uploads. | MIT |

The Codecov v7 pin includes a GitHub Script v8 step that requires the runner
environment to support Node 24; 003-A04 must verify that against the selected
hosted runner rather than assume it from a floating label. OIDC or tokenless
upload remains preferred when the SwiftScream organization supports it;
otherwise its token is a GitHub secret and never appears in workflow source or
fork logs.

URITemplate's current floating tags are evidence of its workflow shape only;
they are not copied. Its CodeQL and DocC workflows are outside the accepted
003-A04 scope.

The originally recorded Codecov value
`e53489f4d376d79066609109e7a95a29eb3740b1` is the signed annotated-tag object,
not a commit. Before executable use, 003-A04 peeled the approved `v7.0.0` tag to
its underlying immutable commit
`fb8b3582c8e4def4969c97caa2f19720cb33a72f`. This correction preserves the
approved source and release while satisfying the full commit-SHA policy.

`irgaly/setup-mint` is Apache-2.0 licensed; GitHub's missing SPDX metadata was
insufficient evidence to classify it as unlicensed. Its `v1` tag resolves to
`8566ee44b3a79d20642d1924db21c8ab0402859f`. The action caches its Mint binary
by runner operating system, architecture, action identity, and Mint version;
its Mint-installed-tool cache also includes the `Mintfile` hash.

The owner has selected `setup-mint` as the Mint bootstrap and cache owner.
Mint is a build tool, so its cache need not include Diorama's selected product
toolchain. 003-A04 must record `yonaskolb/mint@0.18.0` with that lowercase
repository spelling in `Mintfile`; without the exact form recognized by the
action, it falls back to mutable `mint@master`. It must set an explicit
installation directory rather than depend on the default
`/usr/local/bin`, and decide whether the default cleanup and `--link` behavior
are needed. The action uses Node 24, so 003-A04 must verify that runtime on the
selected hosted runner.

The proposed `actions/cache` source does not cache Mint. It caches Diorama
SwiftPM artifacts with keys that include the platform, architecture, selected
toolchain, and relevant manifest or lock input.

## Owner decision

The owner approved all three development-tool records and all four GitHub
Actions sources on 2026-09-07. The approval authorizes only their stated
versions, executable products, purposes, and update ranges. It does not
authorize a Mintfile, tool installation, workflow, manifest dependency, other
action, or future major-version update; those remain 003-A04 work.

## Source material

- [Mint 0.18.0 release](https://github.com/yonaskolb/Mint/releases/tag/0.18.0)
- [SwiftFormat 0.63.0 release](https://github.com/nicklockwood/SwiftFormat/releases/tag/0.63.0)
- [SwiftLint 0.65.1 release](https://github.com/realm/SwiftLint/releases/tag/0.65.1)
- [Mint installation and Linux notes](https://github.com/yonaskolb/Mint/tree/0.18.0#linux)
- [SwiftFormat installation and Swift-version configuration](https://github.com/nicklockwood/SwiftFormat/tree/0.63.0#swift-version)
- [SwiftLint installation and multiple-Swift-version notes](https://github.com/realm/SwiftLint/tree/0.65.1#working-with-multiple-swift-versions)
- [setup-mint cache implementation](https://github.com/irgaly/setup-mint/blob/8566ee44b3a79d20642d1924db21c8ab0402859f/src/main.ts)
- [GitHub Actions SHA pinning guidance](https://docs.github.com/en/actions/security-for-github-actions/security-guides/security-hardening-your-deployments#using-third-party-actions)
