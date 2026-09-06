# Dependency approval policy

- Status: Accepted
- Last updated: 2026-09-05

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

Minor and patch upgrades within the approved major range do not require new
owner approval. A new major version, an additional package product, a fork, or
a different source repository does.

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

## Enforcement

The eventual implementation plan should make dependency review part of task
completion criteria. CI automation may compare direct Swift package
dependencies with this document, but automated enforcement is not required to
establish the policy.
