# 003-C03: Single-document atomic file repository

- Date: 2026-09-17
- Plan: [003-C03](../plans/003-clean-slate-implementation.md#003-c03--single-document-atomic-file-repository)
- Status: Implementation and available local platform verification complete;
  owner review is the next checkpoint. The inherited Apple beta pin remains
  unverified on this machine, as detailed below.
- Authority: [Decision 7](../design-decisions/07-persistence-boundary.md),
  [Decision 8](../design-decisions/08-schema-compatibility.md), and the owner's
  scope and GPT-6 Astra / high reasoning confirmation on 2026-09-17.
- Base: C02 commit `e74c5c7`, atop C01 while both remain under owner review.

## Delivered boundary

`ScenarioDocumentStorage` stores one complete byte document independently of
the codec. `JSONScenarioRepository` composes that boundary with C02's
`JSONScenarioCodec`. Each load reads once and decodes a fresh immutable semantic
scenario; publishing encodes the entire candidate before storage is invoked.
These operations are synchronous and may block the caller. Runtime startup and
finalization orchestration remain with C04 and C05.

Load results retain the following distinctions:

| Result | Meaning |
| --- | --- |
| `loaded` | Fully decoded and prepared scenario, including an empty valid one. |
| `missing` | No document exists at the destination, including a missing parent. |
| `unreadable` | Storage cannot supply bytes; the backend error remains inspectable. |
| `invalidDocument` | Malformed structure, invalid versions, or system decoding/preparation failures. A zero-byte file is invalid. |
| `incompatibleEnvelope` | Unversioned envelope or explicitly unsupported envelope version, retaining the codec error. |
| `incompatibleSystem` | Unknown type, incompatible registration, or unsupported payload version, retaining the distinct dispatch error. |

`ScenarioPublicationError` distinguishes encoding from storage failure.
`DocumentPublication` proves that commit succeeded and separately retains any
subsequent cleanup failure. A custom storage implementation must follow that
contract: throwing means no commit; cleanup after commit returns in the receipt.
Repository error wrappers retain typed underlying errors without rendering
them. Consumer-provided errors need a safe rendering policy before diagnostics
display them. File errors retain only operation and bounded native error codes,
without native paths, descriptions, or arbitrary user info.

## Location and use

The caller explicitly maps its scenario identity to a `ScenarioFileLocation`.
An absolute local directory URL and literal relative path determine the same
destination without using test identity inference, the current working
directory, a locale, or filename sanitization. The root is lexically standardized.
The relative path rejects empty, dot, dot-dot, backslash, and control-character
components. Unicode, spaces, case, and percent text are preserved. No extension
is added and no directories are created implicitly.

```swift
let location = try ScenarioFileLocation(
    rootDirectory: fixturesDirectory,
    relativePath: "random/account-id.json")
let repository = JSONScenarioRepository(
    codec: JSONScenarioCodec(registry: try PersistentSystemRegistry([
        DioramaRandomPersistence.registration,
    ])),
    storage: FileScenarioStorage(location: location))

let baseline = repository.load()
// Inspect the exact load outcome before choosing execution behavior.
// After the caller constructs a complete prepared candidate:
let publication = try repository.publish(candidate)
// Publication succeeded; inspect publication.cleanupFailure separately.
```

`fixturesDirectory` is caller-selected, `candidate` is a `PersistedScenario`,
and the `random` parent directory must already exist before publication.
Storage construction and loading never create staging or require write access;
read-only fixtures and package resources can supply replay baselines.

## File transaction and atomicity evidence

For each publication, `FileScenarioStorage`:

1. Exclusively creates a private `.diorama-stage-<UUID>` directory in the
   destination's parent with mode `0700` (subject to the process umask).
2. Writes and closes the complete document within that directory.
3. Commits with one POSIX `rename` from the staged file to the destination.
4. Attempts to remove only its own staging directory on success or failure.

Exclusive `mkdir` makes ownership explicit; an existing directory is never
accepted as this writer's staging. Random staging names affect temporary
implementation state only, never canonical document bytes or destination names.
No writer removes the published file before replacement. There are no
recording-duration locks or revision comparisons. The last successful rename
wins, even when that writer started staging before another writer.

The [POSIX rename contract](https://pubs.opengroup.org/onlinepubs/9799919799/functions/rename.html)
specifies old-or-new destination visibility during replacement. The
[Linux rename documentation](https://www.man7.org/linux/man-pages/man2/rename.2.html)
also describes unchanged open descriptors and the remote-filesystem failure
caveat. Executable evidence exercises the actual rename on the supported local
test filesystems, alongside injected stage, commit, and cleanup failures.

Tests prove read-only access, initial creation, exact replacement bytes,
exclusive staging ownership, failed encoding with zero storage access, partial
staging cleanup, actual failed rename over a directory, and preservation of the
old destination on precommit failures. Separate storage instances race two
writers and two readers over differently sized documents. A semaphore-controlled
test holds one writer immediately before rename, verifies the old document,
allows a second writer to commit, verifies that document, and then proves the
delayed writer's later commit wins. Cleanup faults are tested both before and
after successful commit; another writer's staging is never swept.

## Backend limitations

- The contract covers local filesystems with POSIX atomic rename behavior.
  Network filesystems, remote commit ambiguity, filesystem corruption, and
  hardware I/O failure recovery are not verified guarantees.
- Atomic visibility is not crash or power-loss durability. This implementation
  does not synchronize file and directory contents to stable media.
- A failed writer does not modify the destination; another concurrent writer
  may still replace it. No conflict detection or preservation of an earlier
  writer's version is promised.
- Roots and ancestors are trusted and stable for an operation. Lexical path
  validation is not a symlink-containment or hostile-directory defense.
  Destination symlinks and in-place external edits are outside the contract.
  Filesystem case and Unicode equivalence can make distinct spellings alias.
- Replacement installs a new file. Existing ownership, permissions, ACLs,
  extended attributes, hard-link relationships, and native metadata are not
  preserved. New file permissions follow Foundation and the process umask.
- Cleanup is attempted on every returning publication path. Cleanup failure
  remains inspectable. Abrupt process termination can leave staging; the backend
  does not scan or delete other writers' directories. Offline removal of crash
  leftovers requires the caller to establish that their owners are no longer
  active. No public staged handle can be abandoned during ordinary use.
- Documents are eagerly encoded and read in memory. There are no resources,
  streaming writes, public flush, incremental append, or execution integration.

## Verification

- The 26 new repository, location, and storage tests pass across the available
  local macOS, iOS Simulator, and pinned Linux environments.
- `scripts/check` passes formatting, strict lint, 129 macOS tests, and main and
  examples release builds with warnings as errors.
- `scripts/coverage swiftpm macos` passes and exports LCOV. The five new
  production files cover 190 of 191 executable lines (99.48%).
- `scripts/coverage ios` passes the iOS 18 deployment build and all 129 tests
  on the selected iPhone 17 / iOS 27.0 simulator, then exports LCOV. The new
  files have the same 190/191 executable-line coverage as macOS. Xcode emits
  its tool-generated App Intents metadata-extraction notice for test bundles
  without AppIntents dependencies; there are no compiler or linter warnings.
- The policy's pinned x86_64 Apple Container command passes all 129 Linux
  tests, both release builds, and multi-binary LCOV export. It uses image
  `swiftlang/swift@sha256:15ae709b1d8eb1f8691b300f5721499d007e944694f2c0e9929a55580c9bf1a5`,
  two CPUs, 4 GiB memory, a read-only repository mount, and a writable copy of
  the package inputs. The compiler reports Swift `6.4.2-dev`, LLVM
  `15622a86b1749a9`, Swift `d2e983b81b18217`.
- Local Markdown link targets and the complete C03 diff whitespace check pass.

The actual local Apple toolchain is Xcode 27.0 stable, build `27A266a`, with
Apple Swift 6.4 (`swiftlang-6.4.0.34.1`, `clang-2100.3.34.1`). This branch still
inherits the beta-6 pin from C02. The separate stable-toolchain update is not
part of C03. Results from the installed stable toolchain do not claim to verify
the pinned beta. Hosted CI and Codecov upload evidence require the separately
authorized PR workflow; no remote changes are made by this unit.
