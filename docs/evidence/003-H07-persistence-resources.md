# 003-H07 — Persistence resource foundation

- Base: H06 at `17004ca`.
- Review boundary: First of two H07 commits; HTTP integration completes the unit.
- Owner authorization: Split persistence support from its HTTP consumer on 2026-11-13.

## Delivered capability

Persistence owns portable resource paths, complete document/resource publications,
and read snapshots used within caller-established loading windows. Deliberate registered system codecs collect
prepared resources during repository publication and resolve them during load.
Conflicting or unresolved content fails before storage publication. Storage has
one snapshot-returning `load()` and one `publish(ScenarioDocument)` method.
Document-only backends construct snapshots explicitly and refuse resource
publication before writing.

The owner-approved DD07 amendment selects stable ordinary `name.json` and
`name-resources/` files. Publication is exclusive with loading (including resource
resolution), other publication, and manual edits of the same scenario. Staging,
backup, installation, and JSON replacement provide returning-failure rollback;
a failed rollback explicitly retains recovery data. Loaded semantic values own
bytes across publication and fixture removal. No symlinks, retained generations,
locks, crash durability, or automated recovery are part of the published layout.

This commit contains the `DioramaPersistence` implementation, storage tests,
system-independent codec/repository tests, and the
[persistence contract](../persistence-schema-v1.md#document-and-resource-files).
It introduces no HTTP changes or new dependencies. H07 completion status remains
in the following HTTP integration commit.

## Independent behavioral evidence

`FileResourceStorageTests` proves stable names and replacement, independent-scenario
publication, failure preservation, rollback/cleanup evidence, read-only access,
path validation, and namespace conflicts. Existing repository and single-document tests
remain regression coverage.

Four `ScenarioResourceRepositoryTests` use a test-only registered resource codec
without importing HTTP. They prove exact binary round trips, identical-reference
sharing, complete direct codec encoding, encoding-stage rejection of conflicting
or unresolved content before storage writes, and whole-document rejection when a
resource is missing.

## Earlier verification — 2026-11-13

The following checkpoints describe the earlier generation-based layout; the
stable-layout review below supersedes that layout and its concurrency claims.

On the selected Xcode 27.2 / Swift 6.4.2 macOS toolchain:

- Focused storage/repository gate passes 34 tests across four suites with compiler
  warnings treated as errors.
- `scripts/check` passes strict formatting/lint, all 690 host tests, compiler
  probes, coverage-export fixtures, release builds, and usage examples.
- `git diff --check` passes. Documentation file links and section anchors resolve.
- At the split checkpoint, every persistence production file matches the
  original H07 implementation; the split adds only independent tests and documentation.

Initial new-test typed-error scope and line-length issues are corrected before
these passing checks. Only macOS validation runs for this review update, as
requested by the owner. No new iOS, Linux, or coverage result is claimed.

## Storage organization review — 2026-11-13

The owner requests consolidating `FileScenarioStorage` and extracting its
low-level reader. All storage methods now live inside `FileScenarioStorage`
in `FileScenarioStorage.swift`; `operations` and `cleanup` are private again.
`ResourceFileIO.swift` owns the unchanged descriptor-based file reader.
`FileScenarioStorage+Resources.swift` is removed. No public API, transaction,
resource lifetime, or file-reading behavior changes.

The 34 focused storage/repository tests and `scripts/check` pass on macOS,
including all 690 host tests, strict formatting/lint, compiler probes, release
builds, and usage examples. The moved declarations compare identically to the
previous commit apart from the two access-level reductions. The complete diff
passes `git diff --check`. No additional platform or coverage checks run.

The owner explicitly requests amending this review update into the persistence
commit without a fixup; the dependent HTTP integration commit is restacked.

## Storage interface review — 2026-11-13

The owner approves consolidating the storage protocol on two requirements:
`load() throws -> ScenarioDocumentSnapshot?` and
`publish(_ document: ScenarioDocument) throws -> DocumentPublication`.
The public byte-only operations and default adapters are removed. File storage
keeps document-only publication as a private implementation path, with the same
atomic replacement and cleanup behavior. A missing document still returns nil;
an empty file remains a present snapshot with empty data.

Repository loading now uses `load()`. Storage callers, concurrent read/write
tests, and test backend conformers use snapshots and complete publications.
Document-only test backends construct snapshots explicitly and reject resource
publication before writing. The removed adapter's test fixture is removed;
its unrelated path-conflict assertion remains. Standalone JSON codec APIs and
repository-level public signatures are unchanged.

This is a source-breaking change for direct storage callers and custom storage
conformers, as explicitly requested during the clean-slate H07 review. The public
persistence schema documents migration to the sole method pair.

The 34 focused tests and `scripts/check` pass on macOS, including all 690 host
tests, strict formatting/lint, compiler probes, release builds, and usage
examples. `git diff --check` passes, and local documentation links resolve.
Only macOS validation runs. The owner approves the review update and requests
squashing its fixup into the persistence commit; the HTTP commit is restacked.

## Stable file layout review — 2026-11-14

The owner selects ordinary `{filename}.json` and sibling
`{filename}-resources/` files for Git-managed fixtures and approves exclusive
publication for the same scenario. [DD07's amendment](../design-decisions/07-persistence-boundary.md#stable-file-layout-and-publication-exclusivity--owner-approved-2026-11-14)
records the restriction and reconciles DD08; the overview, plan, and persistence
schema describe the resulting contract.

The file backend removes generation links, link-reading hooks, retained
UUID-named publications, and the 16-attempt retry loop. Random names occur only
in unpublished staging. Complete staged resources replace the companion directory;
obsolete resources disappear, and resource-free publication removes it.
JSON remains a regular file. Logical references, prepared bytes, schemas, and
repository public signatures do not change.

Callers coordinate loads through all resource resolution, publication, and edits.
Storage snapshots do not outlive that loading window; completed semantic values
own their bytes across replacement and fixture removal. Read-only loads and
independent scenarios with disjoint paths can overlap. No automatic locks enforce
this restriction.

Backups restore the old resource set after failures before the JSON commit.
`FileStorageError.rollbackFailure` is new public safe failure evidence: if rollback
also fails, no cleanup discards the backup, and callers must recover before reuse.
Post-commit cleanup errors remain successful publication receipts. Crash recovery
and recovery automation are not promised.

Validation on macOS passes 38 focused tests across four suites and `scripts/check`
with all 694 host tests, strict formatting/lint, compiler probes, release builds,
and usage examples. Tests cover stable regular-file paths, repeated replacements,
obsolete-file removal, final-extension naming, independent writers, concurrent
read-only loads, stage/backup/install/document failures, successful rollback,
failed withdrawal/restoration retaining backups, and post-commit cleanup failure.
The neutral registered codec proves loaded-value ownership after replacement and
fixture removal. Existing path/namespace and read-only containment tests remain.

The initial rollback test's injected fault is narrowed to the withdrawal step;
strict lint findings are resolved by explicit staging/rollback helpers and test
formatting. No quality rule is weakened. File links, new anchors, and
`git diff --check` pass. Only macOS checks run; no new iOS, Linux, or coverage
execution is claimed. The owner approves the stable-layout review update and
requests squashing its fixup into the persistence commit.

## Complete scenario encoding review — 2026-11-14

The owner approves one public `JSONScenarioCodec.encode(_:)` method returning
`ScenarioDocument`. It always collects exact prepared resource bytes alongside
canonical JSON; resource-free documents have an empty resource dictionary.
The separate internal `encodeDocument` and optional-collector JSON encoding
path are removed. Repository publication uses the public complete-document
encoder. Missing bytes, conflicting references, and invalid namespaces fail
before a complete encoded document is returned or storage writes occur.

The resource codec tests now assert the direct encoder's complete byte dictionary
and its rejection of conflicting and unresolved content. Resource-free golden
tests assert empty resource dictionaries and unchanged JSON. Existing codec
callers use `.data` where they inspect or store resource-free JSON. Public
byte decoding and repository resource resolution retain their existing APIs.
DD18 records the approved source-breaking result-type change; the decision index
and persistence contract describe it. Envelope and system payload schemas do not
change. This supersedes the earlier standalone reference-only encoding evidence.

Validation on macOS passes all 29 focused codec/repository tests and
`scripts/check`, including strict formatting/lint, all 695 host tests, compiler
probes, coverage-export fixtures, release builds, and usage examples.
`git diff --check` passes. No iOS, Linux, or new coverage collection runs.
The owner approves squashing this review fixup and the path-validation fixup into
the persistence commit, then restacking the H07 and H07A branches.

## POSIX file I/O review — 2026-11-14

The owner requests renaming `ResourceFileIO` to `POSIXFileIO` and centralizing
the shared POSIX filesystem operations. `POSIXFileIO.swift` now owns exclusive
directory creation, rename with Darwin/Glibc selection, and shared POSIX error
construction alongside the existing directory checks and descriptor-based reads.
`FileStorageOperations` retains its injectable closures and delegates their
POSIX defaults to that helper. `FileScenarioStorage` uses Foundation's typed
POSIX error code for missing files and no longer imports Darwin or Glibc.

This refactor preserves public APIs, file layout, publication/rollback semantics,
directory permissions, and resource-reading behavior. The owner retains the
optional sibling resource directory and defers shared-resource design.

Validation on macOS passes all 38 focused storage/repository tests and
`scripts/check`, including strict formatting/lint, all 694 host tests, compiler
probes, coverage-export fixtures, release builds, and usage examples.
`git diff --check` passes. Only macOS checks run; no iOS, Linux, or new coverage
collection is performed. The owner approves the review update and requests
squashing its fixup into the persistence commit; dependent branches are restacked.

## Resource path validation review — 2026-11-14

The owner approves simplifying `ScenarioResourcePath` to structural validation.
Empty, absolute, dot, dot-dot, and NUL-containing paths remain invalid. The numeric
ASCII whitelist, Windows device-name exclusions, and trailing-period restriction
are removed. Spaces, Unicode, and other literal filename characters are accepted;
filesystem-specific naming and length limits fail during I/O. Percent escapes
are never decoded. Existing case-alias, file/directory conflict, and symlink
checks remain. External read references and shared-resource design remain deferred.

The public path documentation and persistence contract describe the relaxed
naming rule. File storage tests prove round trips for spaces, Unicode, backslashes,
colons, trailing periods, Windows device names, and literal percent escapes;
negative cases cover absolute paths, empty/dot/dot-dot components, and NULs.
Namespace tests also cover Unicode case aliases and directory names with spaces.

Validation on macOS passes all 39 focused storage/repository tests and
`scripts/check`, including strict formatting/lint, all 695 host tests, compiler
probes, coverage-export fixtures, release builds, and usage examples. Two initial
test-formatting lint findings are corrected before the passing gate.
`git diff --check` passes. No iOS, Linux, or new coverage collection runs.
The owner approves squashing this review fixup and the complete-encoding fixup
into the persistence commit, then restacking the H07 and H07A branches.
