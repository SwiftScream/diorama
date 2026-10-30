# Dependency approval policy

- Status: Accepted
- Last updated: 2026-10-30

## Rule

A third-party Swift package dependency requires explicit owner approval before
it becomes part of an accepted Diorama implementation.

Exploratory work may temporarily use an unapproved package when the work is
clearly identified as a spike. The dependency must be removed or approved
before the spike becomes an accepted implementation slice, informs production
architecture that requires that package, or is merged into the implementation
baseline.

An approved package is permission to use it for a demonstrated need, not a
requirement to add it.

## Approval unit

An adoption record must identify:

- the canonical source repository and package identity;
- the package products Diorama will use;
- the allowed major-version range;
- the concrete purpose and owning Diorama products or targets;
- the current direct transitive dependency graph;
- relevant license, maintenance, toolchain, and platform constraints;
- why the standard library or an already approved package is insufficient.

An additional package product, a fork, or a different source repository requires
separate adoption approval. Version updates follow the authorization rule below.

## Update authorization

Applying a dependency update requires an explicit owner instruction to update
or owner approval of a proposed update. Checking for available updates or
receiving an automated update proposal does not authorize applying it.

An instruction to update authorizes selecting the latest stable release within
the dependency's current major version, including minor-version updates of
`0.x` packages. Such updates do not require another confirmation. For example,
an instruction to update SwiftFormat authorizes moving from `0.63.0` to the
latest stable `0.x` release.

Before moving to a new major version, outline the version change, breaking
changes, and expected migration work, then obtain explicit owner confirmation.
An instruction that explicitly authorizes the target major version already
satisfies this confirmation requirement; a general instruction to update does
not. Moving from `0.x` to `1.x` is a major-version update.

Updates retain the approved source repository, products, and purpose. Keep
exact tool versions pinned, keep related bootstrap declarations consistent,
and run the applicable validation and review gates. Update authorization does
not grant permission to push, create a pull request, or merge.

Dependabot should propose SwiftPM updates within these boundaries. Its pull
requests receive the same CI and review as other changes and are not
automatically merged. A Dependabot proposal cannot grant approval for a new
dependency or broaden an existing adoption record.

Dependabot should also propose GitHub Actions updates. Because Dependabot does
not support `Mintfile`, a scheduled `mint outdated` workflow reports available
tool updates for maintainers to apply through reviewed pull requests. See the
[quality gates and CI policy](quality-gates-and-ci.md) for the complete
automation policy.

Current transitive packages are disclosed and reviewed with the direct package
but do not each require separate owner approval. Importing a transitive package
directly later makes it a direct dependency and requires its own adoption
record.

Repository-pinned development packages and build tools follow the same policy
as shipped library dependencies. A quality tool installed solely by the
developer or CI environment is governed by the forthcoming quality-gates
policy, including its pinning and reproducibility requirements.

## Approved candidates

The following sources are approved for detailed evaluation. Before a package is
added, its adoption record must still fix the products, purpose, and initial
major-version range described above.

| Source | Candidate use | Current disposition |
| --- | --- | --- |
| `apple/swift-http-types` | `HTTPTypes` and `HTTPTypesFoundation` for the shared HTTP domain and URLSession conversion | Approved candidate; exact compatible release range remains to be selected. |
| `apple/swift-algorithms` | General algorithms where a concrete implementation need justifies it | Approved candidate; do not add speculatively. |
| `apple/swift-async-algorithms` | Async sequence algorithms where a concrete stream or scheduling need justifies them | Approved candidate; do not add speculatively. |
| Packages published from the `SwiftScream` GitHub organization | Package-specific use to be stated when proposed | Trusted source; each adopted package still records products, purpose, and major-version range. |

The existing POC dependency on `apple/swift-docc-plugin` is grandfathered only
for maintaining the POC. The clean-slate plan should retain, remove, or approve
it deliberately rather than treating its current presence as architectural
approval.

## Adoption record

Each adopted direct dependency should receive a short entry in this document
before `Package.swift` or repository tooling begins to require it. The entry is
the reviewable approval boundary for agents working unattended.

An implementation task that proposes a new dependency must stop after any
non-committing spike, present the adoption record for approval, and wait. It
must not hide the dependency in generated files, build plugins, example
packages, test utilities, or vendored source.

## Approved development-tool records

The owner approved the following 003-A02 records on 2026-09-07. They are
development tools only and do not enter library targets or `Package.swift`.
003-A04 may add their reviewed declarations, configuration, and workflows after
003-A03. The supporting analysis, including exact source revisions, transitive
graphs, platform constraints, alternatives, and planned GitHub Actions pins, is in
[003-A02 quality-tool adoption evidence](evidence/003-A02-quality-tool-adoptions.md).

On 2026-10-30, the owner approves the update authorization rule above for Mint,
SwiftFormat, and SwiftLint. It replaces their original update restrictions;
the initial pins below remain historical adoption records.

| Tool | Canonical source and product | Initial pin and approved update range | Purpose and ownership |
| --- | --- | --- | --- |
| Mint | `yonaskolb/Mint`; `mint` executable only | Initial bootstrap pin `0.18.0` (`7bc67a0b925b949c8becc327bc08f56eeadc0051`); authorized updates may select the latest stable `0.x` release. New major versions require explicit confirmation. | Resolves and runs exact development-tool executables from `Mintfile`; used only by local quality commands and CI bootstrap. |
| SwiftFormat | `nicklockwood/SwiftFormat`; `swiftformat` executable only | Initial Mintfile pin `0.63.0` (`0256422f1a5e967c68dc923f1905c0a155dca188`); authorized updates may select the latest stable `0.x` release. New major versions require explicit confirmation. | Applies repository formatting locally and checks formatting without mutation in local/CI quality gates. |
| SwiftLint | `realm/SwiftLint`; `swiftlint` executable only | Initial Mintfile pin `0.65.1` (`488642e6fc30e5ffc2b5eb24707bf1c7801f3f19`); authorized updates may select the latest stable `0.x` release. New major versions require explicit confirmation. | Runs strict style, documentation, and correctness checks in local/CI quality gates. |

Each proposed source is MIT licensed and actively maintained as of the evidence
date. Mint itself is deliberately exact-pinned because `Mintfile` records tools
Mint installs, not Mint's own bootstrap release. The Mintfile remains the
source of truth for the formatter and linter; the weekly `mint outdated`
report required by the quality policy identifies available updates for review.

## Enforcement

The eventual implementation plan should make dependency review part of task
completion criteria. CI automation may compare direct Swift package
dependencies with this document, but automated enforcement is not required to
establish the policy.
