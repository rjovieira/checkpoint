# Checkpoint

**A cross-platform game save manager for backing up, restoring, and managing
your emulator saves.**

Checkpoint finds the games your emulators have saves for, packs those saves into
a versioned, checksummed archive in a folder you choose, and puts them back when
you need them — without asking for a single broad storage permission.

> ### Status: early MVP
>
> The full backup and restore path works end to end on Android for three
> emulators. Everything in this document is marked either **Implemented** or
> **Planned**; nothing marked *Planned* exists yet.
>
> The app has been built (`flutter build apk` succeeds) and is covered by 145
> automated tests, but it has **not yet been exercised on a physical device**,
> so the Storage Access Framework code paths are unproven against a real
> `DocumentsProvider`. Treat your saves as precious and keep a manual copy until
> that changes.

---

## Table of contents

- [What Checkpoint is](#what-checkpoint-is)
- [Feature status](#feature-status)
- [Supported platforms](#supported-platforms)
- [Supported emulators](#supported-emulators)
- [How it works, from the user's side](#how-it-works-from-the-users-side)
- [Architecture](#architecture)
  - [Layers and the dependency rule](#layers-and-the-dependency-rule)
  - [Project layout](#project-layout)
  - [Ports and adapters](#ports-and-adapters)
  - [Emulator integration model](#emulator-integration-model)
  - [Backup format](#backup-format)
  - [State management](#state-management)
  - [Persistence](#persistence)
  - [Error handling](#error-handling)
  - [The Android platform layer](#the-android-platform-layer)
- [Security](#security)
- [Getting started](#getting-started)
  - [Prerequisites](#prerequisites)
  - [First run](#first-run)
  - [Setting up in Android Studio](#setting-up-in-android-studio)
  - [Setting up in VS Code](#setting-up-in-vs-code)
- [Building](#building)
  - [Debug builds](#debug-builds)
  - [Release builds and signing](#release-builds-and-signing)
- [Deploying](#deploying)
- [Testing](#testing)
- [Code quality](#code-quality)
- [Adding a new emulator](#adding-a-new-emulator)
- [Troubleshooting](#troubleshooting)
- [Toolchain versions](#toolchain-versions)
- [Current limitations](#current-limitations)
- [Roadmap](#roadmap)
- [Contributing](#contributing)
- [Licence and acknowledgements](#licence-and-acknowledgements)

---

## What Checkpoint is

Emulator save files are easy to lose and hard to find. Every emulator invents
its own folder layout, its own filenames, and its own split between "save data"
(the game's own saves — your actual progress) and "save states" (a snapshot of
the emulator's memory). On modern Android, those folders are also increasingly
awkward to reach: scoped storage means an app cannot simply read
`/storage/emulated/0` any more, and the apps that still do it ask for
**All Files Access**, a permission that grants them your entire device.

Checkpoint takes the opposite approach. It knows where each supported emulator
keeps its saves, it asks you to grant exactly those folders and nothing else,
and it turns what it finds into a list of *games* rather than a list of files.
Backing one up produces a single self-describing archive; restoring reads that
archive's own manifest, tells you precisely what is about to be overwritten and
where, and verifies every byte before writing it.

Three ideas shape the whole design:

1. **Least privilege.** The Android manifest declares **no permissions at all**.
   Every folder Checkpoint can touch is one you picked through the system
   folder picker.
2. **Backups are untrusted data.** A backup file is just a file — it may have
   been downloaded, shared, or crafted. Restore treats it accordingly, with
   validation that makes path traversal impossible to represent rather than
   merely unlikely.
3. **The user always knows what is happening.** Which game, which folders the
   saves come from, where the backup goes, and exactly what a restore will
   overwrite — shown before you confirm, not discovered afterwards.

There are no accounts, no cloud, no analytics, no telemetry, and no network
access of any kind.

---

## Feature status

| Capability | Status |
| --- | --- |
| Detect installed emulators (scoped package query) | **Implemented** |
| Grant save folders per emulator and per save kind | **Implemented** |
| Discover games by scanning granted folders | **Implemented** |
| Read real game titles from PPSSPP `PARAM.SFO` | **Implemented** |
| Distinguish save data from save states | **Implemented** |
| Browse discovered games, open one for detail | **Implemented** |
| Create a versioned, checksummed backup archive | **Implemented** |
| Store backups in a user-chosen folder | **Implemented** |
| List existing backups, all or per game | **Implemented** |
| Inspect a backup and confirm before restoring | **Implemented** |
| Restore a backup with integrity verification | **Implemented** |
| Progress reporting for backup and restore | **Implemented** |
| Loading, empty, success and error states throughout | **Implemented** |
| Delete or prune old backups from the app | *Planned* |
| Selective restore (pick sources or files) | *Planned* |
| Streaming archive read/write | *Planned* |
| iOS support | *Planned* |
| Emulators under `Android/data` (root or custom paths) | *Planned* |
| Cloud sync, accounts, analytics, telemetry, backend | **Out of scope** |

---

## Supported platforms

| Platform | Status | Notes |
| --- | --- | --- |
| **Android** | **Implemented** | minSdk 24 (Android 7.0), targetSdk 36. Storage via SAF. |
| **iOS** | *Planned* | The `ios/` project was generated by `flutter create`, but **an iOS build has not been attempted** and no storage adapter exists, so the app would have nothing to read. The architecture keeps all platform code behind ports specifically so this becomes an additional adapter rather than a rewrite. |
| Desktop (macOS/Windows/Linux) | Not started | No platform folders generated. |

---

## Supported emulators

| Emulator | System | Save data folder | Save state folder | Package ids |
| --- | --- | --- | --- | --- |
| **PPSSPP** | PlayStation Portable | `PSP/SAVEDATA` | `PSP/PPSSPP_STATE` | `org.ppsspp.ppsspp`, `org.ppsspp.ppssppgold` |
| **RetroArch** | Multi-system | `RetroArch/saves` | `RetroArch/states` | `com.retroarch`, `com.retroarch.aarch64`, `com.retroarch.ra32` |
| **mGBA** | Game Boy Advance | `mGBA/saves` | `mGBA/states` | `io.mgba` |

These three were chosen because all of them keep saves in ordinary shared
storage, which the Storage Access Framework can reach without any special
permission. Between them they also exercise both save-layout strategies, which
is the real test of whether the extension mechanism works.

PPSSPP additionally gets **real game titles**: Checkpoint parses the `PARAM.SFO`
metadata file that sits alongside each save, so `ULUS10041` is displayed as
*God of War: Chains of Olympus*.

### Not supported yet, and why

Emulators that keep saves under `Android/data/<package>/files` cannot be reached
by SAF at all on Android 11+ — the system picker explicitly blocks that path.
Reaching them requires either root access or the emulator's own
"custom save path" setting, and neither is designed yet:

- **Dolphin** (GameCube/Wii), **DuckStation** (PlayStation),
  **M64Plus FZ** (Nintendo 64), **NetherSX2** (PlayStation 2)
- **Citra** / **Azahar** (Nintendo 3DS)
- **Yuzu** / **Citron** / **Eden** (Nintendo Switch) — these do expose a custom
  save path setting, so they are the most likely next additions
- **DraStic**, **Flycast**, **Lemuroid**, **Pizza Boy**, **AetherSX2**,
  **Vita3K** — several of these use shared storage and are straightforward
  additions; they simply are not done yet

See [Adding a new emulator](#adding-a-new-emulator) and the
[Roadmap](#roadmap).

---

## How it works, from the user's side

The app has three tabs: **Games**, **Backups**, **Settings**.

**1. Settings — grant folders.** Checkpoint lists every emulator it supports and
marks the ones it detected on your device. Detection is a *hint*, not a gate:
you can configure any emulator whether or not it was detected, because an
emulator may have been uninstalled while its saves remain. For each one you tap
a save folder and the system picker opens — on Android 8+ it opens near the
expected path as a convenience, but you can pick anywhere. You also choose one
**backup folder**, which is where archives are written. Nothing works until this
is set, and the UI says so rather than failing later.

**2. Games — see what was found.** Checkpoint scans every granted folder and
merges the results into games. A game's save data and its save states live in
different folders, so the same title is found once per folder and merged on
(emulator, game id). Each row shows the emulator, file count, total size, when
it last changed, and icons for whether save data, save states, or both were
found. If a folder's grant was revoked, that is shown as a warning banner rather
than the games silently vanishing.

**3. Game details — understand before acting.** Opening a game shows, in order:
where each set of saves is read *from* (with the real folder path), where the
backup will be written *to*, a button that names exactly what it will do
("Back up 4 files (1.2 MB)"), and the existing backups of that game.

**4. Back up.** Every file is read and hashed, the manifest is assembled, and
the archive is written to your backup folder with a progress bar showing the
current file.

**5. Restore.** Tapping *Restore* first *inspects* the archive without changing
anything, then shows a confirmation dialog built from the archive's own
manifest: the game, the emulator, when the backup was made, how many files and
how large, which folders each part will be written to, and a plain-language note
that matching files will be replaced and everything else left alone. Only then
does anything get written — and only after every file's checksum has been
verified.

---

## Architecture

### Layers and the dependency rule

```text
┌─────────────────────────────────────────────────────────────┐
│  Presentation          Flutter widgets. No business logic.  │
│  lib/presentation/     Screens, state views, banners.       │
└───────────────────────────┬─────────────────────────────────┘
                            │ depends on
┌───────────────────────────▼─────────────────────────────────┐
│  Application           Use cases + Riverpod providers.      │
│  lib/application/      Orchestration only, no I/O detail.   │
└───────────────────────────┬─────────────────────────────────┘
                            │ depends on
┌───────────────────────────▼─────────────────────────────────┐
│  Domain                Entities, ports, emulator registry,  │
│  lib/domain/           backup format, path safety.          │
│                        PURE DART — no Flutter, no platform. │
└───────────────────────────▲─────────────────────────────────┘
                            │ implements
┌───────────────────────────┴─────────────────────────────────┐
│  Infrastructure        SAF adapter (Kotlin + channel),      │
│  lib/infrastructure/   ZIP archive, JSON persistence.       │
└─────────────────────────────────────────────────────────────┘
```

**The dependency rule:** `lib/domain/` must never import `package:flutter/`,
`dart:io`, or anything from `lib/infrastructure/`. The domain declares
*interfaces*; infrastructure implements them; `lib/application/providers.dart`
is the single composition root that binds the two together.

This is not architecture for its own sake — it is what makes the entire
discover → back up → restore path runnable in a plain unit test against
`test/support/in_memory_file_system.dart`, with no Android, no emulator, and no
real files. It is also what makes iOS support an additional adapter rather than
a rewrite.

### Project layout

```text
checkpoint/
├── lib/
│   ├── main.dart                        entry point: ProviderScope + app
│   ├── core/
│   │   ├── app_info.dart                checkpointVersion (matches pubspec)
│   │   ├── failure.dart                 sealed Failure hierarchy
│   │   ├── formatting.dart              bytes, timestamps, relative times
│   │   └── result.dart                  sealed Result<T> = Ok | Err
│   ├── domain/                          ← pure Dart, no Flutter
│   │   ├── backup/
│   │   │   ├── archive_limits.dart      zip-bomb bounds
│   │   │   ├── backup_archive_port.dart pack / readManifest / unpack
│   │   │   ├── backup_file_name.dart    naming scheme + slugging
│   │   │   └── backup_manifest.dart     versioned manifest + migration hook
│   │   ├── config/
│   │   │   └── app_configuration.dart   grants + ConfigurationRepository
│   │   ├── emulator/
│   │   │   ├── emulator_definition.dart EmulatorDefinition, SaveSource
│   │   │   ├── emulator_registry.dart   ← the emulator list lives here
│   │   │   ├── game_platform.dart       console families
│   │   │   ├── save_kind.dart           saveData | saveState
│   │   │   ├── save_layout.dart         layout strategies
│   │   │   └── title_reader.dart        PARAM.SFO parser
│   │   ├── game/
│   │   │   └── discovered_game.dart     DiscoveredGame, GameSaveSet
│   │   ├── platform/
│   │   │   └── installed_app_port.dart  scoped package query
│   │   └── storage/
│   │       ├── directory_picker_port.dart
│   │       ├── file_system_port.dart    the storage abstraction
│   │       ├── safe_path.dart           ← the security chokepoint
│   │       └── storage_root.dart        opaque granted-folder handle
│   ├── application/
│   │   ├── progress.dart                OperationProgress
│   │   ├── providers.dart               ← composition root
│   │   ├── transfer_controller.dart     backup/restore state machine
│   │   └── usecases/
│   │       ├── create_backup.dart
│   │       ├── detect_emulators.dart
│   │       ├── discover_games.dart
│   │       ├── list_backups.dart
│   │       └── restore_backup.dart      inspect() then apply()
│   ├── infrastructure/
│   │   ├── android/
│   │   │   ├── android_installed_apps.dart
│   │   │   ├── checkpoint_channel.dart  channel + error translation
│   │   │   ├── saf_directory_picker.dart
│   │   │   └── saf_file_system.dart
│   │   ├── archive/
│   │   │   └── zip_backup_archive.dart  ← safe extraction
│   │   └── persistence/
│   │       └── json_configuration_repository.dart
│   └── presentation/
│       ├── app.dart                     MaterialApp + 3-tab shell
│       ├── screens/
│       │   ├── backups_screen.dart
│       │   ├── game_detail_screen.dart
│       │   ├── games_screen.dart
│       │   ├── restore_flow.dart        inspect → confirm → apply
│       │   └── settings_screen.dart
│       └── widgets/
│           ├── state_views.dart         Loading / Empty / Error
│           └── transfer_banner.dart
├── android/
│   └── app/src/main/
│       ├── AndroidManifest.xml          ← zero permissions, scoped <queries>
│       └── kotlin/dev/checkpoint/checkpoint/
│           ├── MainActivity.kt          channel dispatch, activity results
│           └── SafStorage.kt            DocumentsContract operations
├── ios/                                 scaffold only; no storage adapter
├── test/
│   ├── application/
│   │   ├── backup_restore_round_trip_test.dart  ← the vertical slice
│   │   └── detect_emulators_test.dart
│   ├── domain/
│   │   ├── backup/backup_file_name_test.dart
│   │   ├── backup/backup_manifest_test.dart
│   │   ├── emulator/save_layout_test.dart
│   │   └── storage/safe_path_test.dart          ← most security-critical
│   ├── infrastructure/
│   │   ├── archive/zip_backup_archive_test.dart ← adversarial archives
│   │   └── persistence/json_configuration_repository_test.dart
│   ├── presentation/games_screen_test.dart
│   └── support/
│       ├── fake_configuration_repository.dart
│       └── in_memory_file_system.dart
├── analysis_options.yaml                strict analyzer configuration
├── pubspec.yaml                         version: is the single source of truth
├── CLAUDE.md                            contributor/agent guidance
└── README.md
```

### Ports and adapters

| Port (domain) | Android adapter | Purpose |
| --- | --- | --- |
| `FileSystemPort` | `SafFileSystem` | List, read, write, delete inside a granted root |
| `DirectoryPickerPort` | `SafDirectoryPicker` | Ask the user to grant a folder; persist the grant |
| `InstalledAppPort` | `AndroidInstalledApps` | Answer "is *this* package installed?" |
| `BackupArchivePort` | `ZipBackupArchive` | Pack, peek at, and safely unpack archives |
| `ConfigurationRepository` | `JsonConfigurationRepository` | Load and store the user's grants |

Every path parameter on `FileSystemPort` is a `SafePath`, never a `String`. An
adapter can therefore join a path to its root without further validation,
because the type already proves the result stays inside.

`StorageRoot.id` is an **opaque platform token** that the domain never parses.
On Android it is a persisted SAF tree URI; on iOS it will be a security-scoped
bookmark; on desktop, an absolute path. Keeping it opaque is what lets identical
discovery, backup and restore logic run everywhere.

### Emulator integration model

An emulator is a `const` entry in `EmulatorRegistry`:

```dart
EmulatorDefinition(
  id: 'ppsspp',                       // stable; written into manifests
  name: 'PPSSPP',
  platform: GamePlatform.playStationPortable,
  androidPackageIds: ['org.ppsspp.ppsspp', 'org.ppsspp.ppssppgold'],
  saveSources: [
    SaveSource(
      id: 'savedata',                 // stable; becomes an archive path segment
      label: 'PSP save data folder',  // shown when asking for the folder
      kind: SaveKind.saveData,
      androidPathHints: ['PSP/SAVEDATA'],
      layout: DirectoryPerGameLayout(
        id: 'ppsspp.savedata.v1',
        groupingSuffixes: ['DATA00', 'PROFILE00'],
        idPattern: RegExp(r'^([A-Z]{4}\d{5})'),
        acceptUnmatchedDirectories: false,
        titleReader: ParamSfoTitleReader(),
      ),
    ),
    SaveSource(
      id: 'states',
      label: 'PSP save state folder',
      kind: SaveKind.saveState,
      required: false,                // optional: absence is not an error
      androidPathHints: ['PSP/PPSSPP_STATE'],
      layout: FlatFilePerGameLayout(
        id: 'ppsspp.states.v1',
        extensionPattern: RegExp(r'^(ppst|ppss|jpg|png)$', caseSensitive: false),
        idPattern: RegExp(r'^([A-Z]{4}\d{5})'),
        acceptUnmatchedNames: false,
      ),
    ),
  ],
)
```

Each `SaveSource` pairs a **kind** with a **layout strategy**.

`SaveKind` — `saveData` or `saveState` — is a first-class value, not a folder
convention. This is a deliberate correction of the reference implementation
Checkpoint was studied against, which modelled the two only as different
directories and consequently could not tell the user whether a restore was about
to overwrite hours of in-game progress or a scratch snapshot.

`SaveLayout` implementations know how to enumerate games in a folder. They see
storage only through `FileSystemPort`, so they are pure with respect to the
platform and unit-testable against an in-memory fake. Two cover all three
emulators:

- **`DirectoryPerGameLayout`** — one directory per game; every file beneath it
  belongs to that game. Several directories can map to one game, which is how
  PPSSPP's `ULUS10041DATA00` and `ULUS10041PROFILE00` collapse onto
  `ULUS10041`. Optionally reads a title from a metadata file.
- **`FlatFilePerGameLayout`** — flat files in a shared folder, grouped by base
  name. Trailing extensions are stripped while they keep matching
  `extensionPattern`, so `Zelda.srm`, `Zelda.state1` and `Zelda.state.auto` are
  all one game — and `cover.jpg` is not a game at all. The optional `idPattern`
  recovers an id from a filename that carries more than the game name, which is
  what makes PPSSPP's `ULUS10041_1.00_0.ppst` merge with `ULUS10041`'s save data
  instead of forming a phantom entry.

**Adding an emulator whose saves fit an existing layout is one registry entry
plus its package ids in the Android manifest.** No `switch`, no manager class,
no changes to discovery, backup, restore, or UI. See
[Adding a new emulator](#adding-a-new-emulator).

### Backup format

A backup is a ZIP archive containing a versioned manifest and a payload:

```text
checkpoint__ppsspp__ULUS10041__20260816-120000.zip
├── checkpoint.json                              the manifest
└── files/
    ├── savedata/
    │   └── ULUS10041DATA00/SAVE.BIN             ← path relative to its source root
    └── states/
        └── ULUS10041_1.00_0.ppst
```

Nothing lives outside `files/` except the manifest, and each file sits under the
id of the save source it came from — which is exactly how restore knows which
folder to put it back in.

The manifest is real output from the code, not an illustration:

```json
{
  "formatVersion": 1,
  "appVersion": "0.1.0",
  "backupId": "checkpoint__ppsspp__ULUS10041__20260816-120000.zip",
  "createdAt": "2026-08-16T12:00:00.000Z",
  "emulator": {
    "id": "ppsspp",
    "name": "PPSSPP"
  },
  "game": {
    "id": "ULUS10041",
    "title": "God of War: Chains of Olympus"
  },
  "sources": [
    {
      "id": "savedata",
      "label": "PSP save data folder",
      "kind": "saveData",
      "layoutId": "ppsspp.savedata.v1",
      "originDisplayPath": "Internal storage/PSP/SAVEDATA"
    },
    {
      "id": "states",
      "label": "PSP save state folder",
      "kind": "saveState",
      "layoutId": "ppsspp.states.v1",
      "originDisplayPath": "Internal storage/PSP/PPSSPP_STATE"
    }
  ],
  "files": [
    {
      "sourceId": "savedata",
      "path": "ULUS10041DATA00/SAVE.BIN",
      "sizeBytes": 131072,
      "sha256": "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08"
    },
    {
      "sourceId": "states",
      "path": "ULUS10041_1.00_0.ppst",
      "sizeBytes": 4194304,
      "sha256": "2c26b46b68ffc68ff99b453c1d30413413422d706483bfa0f98a5e886266e7ae"
    }
  ]
}
```

This carries everything needed to identify the backup without guessing:
Checkpoint version, backup format version, emulator, game, the original save
locations, creation time in UTC, the complete file list, and a SHA-256 per file.

**Filenames** follow
`checkpoint__<emulatorId>__<gameSlug>__<yyyyMMdd-HHmmss>.zip`. `__` separates
fields and slugging collapses runs of `_`, so no field can contain the
separator and parsing is unambiguous. The name exists so the backup list can be
built from a single directory listing without opening every archive — but the
**manifest inside is always the authority**, and restore reads it.

**Versioning.** `formatVersion` is checked before anything in an archive is
trusted:

- A backup from a **newer** Checkpoint is refused with a clear message rather
  than half-restored.
- A backup older than `minimumSupportedFormatVersion` is refused explicitly.
- `BackupManifest._migrate` is the hook for upgrading older documents. Version 1
  is the first format so it does nothing yet; adding version 2 is a local change
  there rather than a rewrite of the parser.

### State management

**Riverpod** (`flutter_riverpod` 3.4.2), chosen for four reasons that map
directly onto this app's needs:

- **Testability.** Every dependency is a provider, so a test overrides
  `fileSystemProvider` with an in-memory fake and the whole stack above runs
  unchanged. The widget tests do exactly this.
- **Clear dependency boundaries.** `lib/application/providers.dart` is the only
  place that knows which concrete adapter implements which port.
- **Predictable state transitions.** `AsyncValue` maps directly onto the
  loading / data / error states the UI must render, so no screen invents its
  own. Backup and restore use a sealed `TransferState`
  (`idle | running | succeeded | failed`) so the UI is forced to handle every
  case and cannot render "loading and error" simultaneously.
- **Minimal boilerplate.** No `BuildContext` coupling, and deliberately **no
  code generation** — no `build_runner` step, no generated files to review.

### Persistence

Configuration — which folders you granted and where backups go — is a JSON
document written atomically to app-private storage, behind the
`ConfigurationRepository` interface.

A relational database is deliberately *not* used. The data is a handful of
grants that is always read and written whole; a database would add a schema,
migrations and a code generator to buy indexing and partial queries that nothing
here needs. Writes go to a temporary file and are renamed over the target, so an
interrupted write cannot lose your grants, and a corrupt file degrades to "empty"
rather than preventing the app from starting.

**Discovered games are not cached.** Rescanning is fast and always correct,
whereas a stale cache shows games whose saves have moved. Backups are likewise
not indexed — the directory listing plus the filename scheme is the index.

The interface is what makes all of this reversible: the first feature that needs
to genuinely *query* this data changes the implementation and nothing else.

### Error handling

Two mechanisms, used for different things:

- **`Result<T>`** (`Ok` | `Err`) at use-case boundaries, for failures that are
  expected in ordinary use — a revoked folder, a corrupt archive, a missing
  destination. Callers cannot forget these exist. Programming errors still
  throw, because a broken invariant is a bug, not a condition.
- **Typed exceptions** at the port boundary — `StorageException` and
  `StorageAccessDeniedException`. The two are distinguished because the remedy
  differs: one is an I/O problem, the other means the user must re-pick the
  folder.

`Failure` is a sealed hierarchy (`PermissionFailure`, `StorageFailure`,
`ArchiveFailure`, `ValidationFailure`, `NotFoundFailure`, `UnexpectedFailure`).
Every failure carries a `message` written for a person and an optional `detail`
carrying the technical text, which the UI keeps collapsed behind a *Details*
disclosure rather than showing by default.

### The Android platform layer

All Android-specific code lives in two Kotlin files behind a single
`MethodChannel` named `dev.checkpoint/storage`.

**`MainActivity.kt`** dispatches channel calls. SAF calls hit a content provider
and can block for a long time on a large folder, so everything except the folder
picker runs on a background executor, with replies posted back to the main
thread. Platform exceptions are mapped to stable error codes
(`access_denied`, `not_found`, `io_error`) which `CheckpointChannel` translates
back into the exception types the domain declares — so no other Dart file has to
know that `PlatformException` exists.

**`SafStorage.kt`** implements storage on `DocumentsContract` directly, with no
`androidx.documentfile` dependency. Paths are resolved **one component at a time**
from the granted tree root by exact display name, so a path component never
becomes part of a document id or a URI string, and the granted tree remains the
boundary even if the Dart-side guarantee were ever weakened.

One deliberate detail carried over from studying the reference implementation:
`SafStorage` queries `COLUMN_DISPLAY_NAME` directly instead of using
`DocumentFile.getName()`, which appends a MIME-derived extension to
extension-less files and would silently rename a save called `file0` to
`file0.bin` on its way into a backup.

---

## Security

Save backups are treated as untrusted data throughout, because a backup file is
just a file the user obtained somewhere.

### Permissions

`android/app/src/main/AndroidManifest.xml` declares **no permissions**. Not
`MANAGE_EXTERNAL_STORAGE` (All Files Access), not the legacy
`READ_EXTERNAL_STORAGE` / `WRITE_EXTERNAL_STORAGE`, not `INTERNET`.

- **Storage** is entirely SAF grants obtained through
  `ACTION_OPEN_DOCUMENT_TREE` and persisted with
  `takePersistableUriPermission`. Removing a folder in Settings calls
  `releasePersistableUriPermission`, so Checkpoint does not hold access it no
  longer needs.
- **Emulator detection** uses a scoped `<queries>` block naming the exact
  packages, not `QUERY_ALL_PACKAGES`. Checkpoint asks "is *this* installed?" and
  can never enumerate your apps.

Adding either broad permission would be a regression, not a convenience.

### Path safety

`lib/domain/storage/safe_path.dart` is the single chokepoint. It is the only
path type the archive layer and the filesystem ports accept, and it can only be
constructed through a validating parser. It rejects:

| Rejected | Why |
| --- | --- |
| Absolute paths (`/etc/passwd`), drive letters (`C:\x`), UNC (`//host/share`) | Would ignore the destination root entirely |
| Any `..` or `.` component (and `...`, longer runs) | Classic traversal |
| Empty components (`a//b`, trailing `/`) | Normalisation ambiguity |
| Backslashes anywhere | A legal filename character on POSIX, a separator on Windows — any interpretation is wrong somewhere, so we refuse rather than guess. Closes the "Windows separator smuggling" family of bugs. |
| Control characters, including NUL | Truncation attacks against native APIs |
| Components ending in `.` or ` `, or made only of dots | Windows silently strips these, so `evil. ` and `evil` can collide |
| Windows reserved device names (`CON`, `NUL`, `COM1`…) | Opening them has side effects rather than creating a file |
| Oversized components, paths, and depths | Defensive bounds |

Because a `SafePath` is relative and `..`-free **by construction**, containment
is a property of the type rather than a check that can be forgotten. Extraction
code needs no second "is it still inside?" test — the type already proves it.

Containment comparisons are segment-wise, so `files2/x` is correctly *not*
inside `files` (the classic string-prefix bug).

*Not attempted:* Unicode confusables and case-folding collisions. Those are a
display concern rather than an escape vector, and the filesystem is the
authority on collisions.

### Safe archive extraction

Restore never uses a library's "extract to disk" helper, because those trust
entry names. `ZipBackupArchive.unpack` instead:

1. **Treats the manifest as an allowlist.** It iterates `manifest.files`, not
   the ZIP's entries. An entry that is not in the manifest is never
   decompressed and never written, so an attacker cannot smuggle an extra file
   in by appending one.
2. **Rejects symbolic-link entries outright** — not skips them. A symlink is the
   standard way to turn a contained extraction into an arbitrary write, and no
   legitimate save backup needs one. Its presence means the archive is not
   something Checkpoint produced.
3. **Routes every path through `SafePath`** and additionally verifies each entry
   resolves under `files/`.
4. **Bounds sizes before decompressing** — entry count, per-file size, total
   uncompressed size, and total archive size (`ArchiveLimits`) — then re-checks
   the real size afterwards.
5. **Verifies SHA-256** for every file against the manifest before it is
   written, so a tampered payload fails before it reaches your save folder.
6. **Validates source ids as single path segments**, so a source id of `../..`
   cannot smuggle traversal in through the back door.

Additionally, restore is **refused outright** if any source in the backup has no
granted destination, and all destinations are resolved before a single byte is
written. A half-restored save is worse than none — the emulator may load a mix
of old and new state.

### Restore behaviour

Files in the backup **replace matching files** in the save folder; anything else
in that folder is **left untouched**. Wiping the destination first would be
tidier, but RetroArch and mGBA keep every game's saves in one flat folder, so it
would destroy other games' saves. This is stated in the confirmation dialog
rather than left for the user to discover.

### Other

- **No root access.** Not in the MVP. If it is added later it goes behind a
  port, like everything else platform-specific, and never becomes an ambient
  capability.
- **No shelling out.** The reference implementation builds `su` command lines by
  string interpolation; one missed quote there is command injection as root.
  Checkpoint has no equivalent surface.
- **No telemetry, no analytics, no crash reporting, no network access, no
  accounts, no hard-coded secrets.** The Flutter and Dart CLI analytics were
  disabled on the development machine as well.

---

## Getting started

### Prerequisites

| Requirement | Version | Notes |
| --- | --- | --- |
| **Flutter SDK** | 3.47.0+ (stable) | Includes Dart 3.13.0+ |
| **JDK** | 17 or newer | Android Studio bundles one; a standalone JDK works too |
| **Android SDK** | Platform 36, Build-Tools | Installed via Android Studio's SDK Manager |
| **Android NDK** | 28.2.13676358 | Only needed if a dependency requires native code |
| **Xcode** | 15+ | *macOS only, and only for the iOS target, which is scaffold-only and unverified* |

Install Flutter:

```bash
# macOS (Homebrew)
brew install --cask flutter

# Any platform: follow https://docs.flutter.dev/get-started/install
```

Verify the environment. Everything under *Android toolchain* must pass:

```bash
flutter doctor -v
```

If `flutter doctor` reports unaccepted Android licences:

```bash
flutter doctor --android-licenses
```

### First run

```bash
git clone https://github.com/rjovieira/checkpoint.git
cd checkpoint
flutter pub get
flutter devices          # confirm a device or emulator is attached
flutter run
```

**About `android/local.properties`:** this file is generated automatically by
the Flutter tool on first build and is **gitignored**, because it contains
machine-specific absolute paths. If you ever need to create it by hand:

```properties
sdk.dir=/absolute/path/to/Android/sdk
flutter.sdk=/absolute/path/to/flutter
```

On macOS the Android SDK is usually at `~/Library/Android/sdk`; on Linux
`~/Android/Sdk`; on Windows `%LOCALAPPDATA%\Android\Sdk`.

### Setting up in Android Studio

Checkpoint is a Flutter project, so Android Studio needs the Flutter plugin —
opening the `android/` folder alone will *not* give you a working setup.

**1. Install the plugins.**
*Settings → Plugins → Marketplace* → install **Flutter** (this pulls in **Dart**
automatically) → restart the IDE.

**2. Point the IDE at your Flutter SDK.**
*Settings → Languages & Frameworks → Flutter* → set **Flutter SDK path**.
With a Homebrew install this is typically `/opt/homebrew/share/flutter`; you can
confirm with `flutter --version` or `which flutter`.

**3. Open the project.**
*File → Open…* and select the repository root — the folder containing
`pubspec.yaml`. **Do not** open the `android/` subfolder; that is the Gradle
host project, and opening it directly loses all Dart tooling. Android Studio
will detect the Flutter project and offer to run `flutter pub get`; accept it.

**4. Let Gradle sync.**
The first sync downloads the Gradle distribution and Android SDK components and
can take several minutes. Watch the status bar. If it fails, see
[Troubleshooting](#troubleshooting).

**5. Select a device.**
Use the device dropdown in the toolbar. To create an emulator:
*Tools → Device Manager → Create Device* → pick a phone → choose a system image
of **API 24 or newer** (API 34+ recommended, since SAF behaviour on modern
Android is what this app is built around) → *Finish*.

**6. Run.**
Press **Run** (▶) or `Ctrl`/`Cmd` + `R`. The run configuration `main.dart` is
created automatically.

**Useful run configurations to add** (*Run → Edit Configurations… → +*):

- **Flutter** configuration, Dart entrypoint `lib/main.dart` — the app.
- **Flutter Test** configuration, test scope *All in directory* → `test/` — the
  whole suite, runnable and debuggable from the IDE gutter.

**Working with the Kotlin code.** Android Studio will index
`android/app/src/main/kotlin/` and give you full Kotlin support once the Gradle
sync completes. If `MainActivity.kt` shows unresolved Flutter imports, the sync
has not finished or has failed — run
*File → Sync Project with Gradle Files*.

**Recommended IDE settings.**

- *Settings → Languages & Frameworks → Flutter* → enable **Format code on save**
  and **Organize imports on save**. The codebase is `dart format`-clean and the
  analyzer enforces `directives_ordering`.
- *Settings → Editor → Code Style → Dart* → keep the default 80-column line
  length; the codebase adheres to it.

### Setting up in VS Code

1. Install the **Flutter** extension (it pulls in **Dart**).
2. Open the repository root.
3. `Ctrl`/`Cmd` + `Shift` + `P` → *Flutter: Select Device*.
4. `F5` to run and debug.

`flutter pub get` runs automatically when `pubspec.yaml` changes.

---

## Building

All commands run from the repository root.

### Debug builds

```bash
flutter run                        # build, install and attach with hot reload
flutter run -d <device-id>         # pick a device (see `flutter devices`)
flutter build apk --debug          # → build/app/outputs/flutter-apk/app-debug.apk
```

Debug APKs are large (~150 MB) because they bundle the Dart VM and debug
symbols for every ABI. This is expected.

### Release builds and signing

> **The release build currently signs with the debug key.** That is the Flutter
> scaffold default, left in place so `flutter run --release` works out of the
> box — it is not a decision. **Set up a real signing config before distributing
> anything.**

**1. Generate a keystore.** Keep it outside the repository and back it up — if
you lose it you cannot ship an update to an app already published under it.

```bash
keytool -genkey -v -keystore ~/checkpoint-upload-key.jks \
  -keyalg RSA -keysize 2048 -validity 10000 -alias upload
```

**2. Create `android/key.properties`** (already gitignored — never commit it):

```properties
storePassword=<password from step 1>
keyPassword=<password from step 1>
keyAlias=upload
storeFile=/absolute/path/to/checkpoint-upload-key.jks
```

**3. Wire it into `android/app/build.gradle.kts`.** Above the `android { }`
block:

```kotlin
val keystoreProperties = java.util.Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystorePropertiesFile.inputStream().use { keystoreProperties.load(it) }
}
```

Inside `android { }`, replace the debug-signing line:

```kotlin
signingConfigs {
    create("release") {
        keyAlias = keystoreProperties["keyAlias"] as String
        keyPassword = keystoreProperties["keyPassword"] as String
        storeFile = (keystoreProperties["storeFile"] as String?)?.let { file(it) }
        storePassword = keystoreProperties["storePassword"] as String
    }
}

buildTypes {
    release {
        signingConfig = signingConfigs.getByName("release")
        isMinifyEnabled = true
        isShrinkResources = true
    }
}
```

**4. Build.**

```bash
flutter build apk --release            # single fat APK
flutter build apk --split-per-abi      # smaller per-architecture APKs
flutter build appbundle --release      # → build/app/outputs/bundle/release/app-release.aab
```

Use the **App Bundle** (`.aab`) for Google Play; use an APK for direct
distribution, F-Droid, or sideloading.

**5. Bump the version** in `pubspec.yaml` before each release — it is the single
source of truth for `versionName` and `versionCode`:

```yaml
version: 0.2.0+2      # <versionName>+<versionCode>
```

> **Keep `checkpointVersion` in `lib/core/app_info.dart` in step with it.** That
> constant is written into every backup manifest as `appVersion`.

---

## Deploying

**Sideloading / direct install:**

```bash
adb install -r build/app/outputs/flutter-apk/app-release.apk
```

**Google Play.** Upload the `.aab` from
`build/app/outputs/bundle/release/`. Two things make the store listing unusually
simple:

- Checkpoint declares **no permissions**, so there is no sensitive-permission
  declaration form to fill in — in particular none of the
  `MANAGE_EXTERNAL_STORAGE` justification that comparable apps must provide, and
  which is a common cause of review rejection.
- There is no network access, no data collection, and no advertising ID, so the
  **Data safety** form is a straightforward "no data collected, no data shared".

**F-Droid.** The project has no proprietary dependencies and no telemetry, so it
is a reasonable candidate. Reproducible builds have not been configured.

---

## Testing

Testing is part of the implementation, not a later task. **145 tests**, all
passing.

```bash
flutter test                                            # everything
flutter test test/domain/storage/safe_path_test.dart    # one file
flutter test --plain-name "rejects a symbolic link"     # one test by name
flutter test --coverage                                 # → coverage/lcov.info
flutter test --reporter expanded                        # verbose output
```

To view coverage as HTML (requires `lcov`):

```bash
flutter test --coverage
genhtml coverage/lcov.info -o coverage/html
open coverage/html/index.html
```

### What is covered, and why

Coverage is concentrated on security-critical and business-critical behaviour
rather than spread for its own sake.

| Test file | What it proves |
| --- | --- |
| `domain/storage/safe_path_test.dart` | Every rejection rule — traversal, absolute paths, drive letters, backslashes, control characters, reserved device names, trailing dots — plus segment-wise containment and the `files2` vs `files` prefix bug |
| `infrastructure/archive/zip_backup_archive_test.dart` | Hand-built **malicious** archives: path traversal, absolute paths, traversal in a source id, symlink entries, undeclared entries, tampered payloads, size lies, missing files, non-ZIP input, and every resource limit |
| `domain/backup/backup_manifest_test.dart` | Round trip, version gating in **both** directions, and every malformed-input rejection path |
| `domain/backup/backup_file_name_test.dart` | Slugging hostile game ids so a generated filename is always a valid `SafePath`; round trip; rejecting foreign filenames |
| `domain/emulator/save_layout_test.dart` | Both layout strategies against an in-memory filesystem, including `PARAM.SFO` title parsing and its fallback |
| `application/backup_restore_round_trip_test.dart` | **The vertical slice:** discover → back up → corrupt the saves → restore → verify byte-for-byte; that neighbouring games are untouched; revoked folders; missing destinations; progress reporting |
| `application/detect_emulators_test.dart` | Detection by any package id, missing-folder reporting, graceful degradation when the platform cannot answer, and registry invariants |
| `infrastructure/persistence/json_configuration_repository_test.dart` | Round trip, no duplicate grants, corrupt-file tolerance, partial-corruption recovery, atomic writes leaving no temp file |
| `presentation/games_screen_test.dart` | Loading, empty/onboarding, populated, error, and degraded (revoked-folder) states |

Two tests earned their keep during development by finding real defects:

- The **round-trip test** exposed that PPSSPP save states (`ULUS10041_1.00_0.ppst`)
  formed a phantom "game" instead of merging with the same title's save data.
  That is why `FlatFilePerGameLayout.idPattern` exists.
- Building the **symlink fixture** revealed that `ZipEncoder` always stamps an
  MS-DOS `versionMadeBy`, while the decoder only honours symlink mode bits on
  UNIX-made archives — so a fixture built with the package's own encoder could
  never actually *be* a symlink archive. The test patches the central directory
  to reproduce a genuine one, and the helper explains why.

**Test support.** `test/support/in_memory_file_system.dart` is a complete
in-memory `FileSystemPort` with a write log, seedable files and timestamps, and
the ability to simulate a revoked grant. Its existence is the payoff of the port
abstraction: it lets the entire application layer be tested with no Android
present.

**Not covered by automated tests:** the Kotlin `SafStorage` and `MainActivity`
code, which needs an instrumented test on a real device or emulator. That is the
largest gap in the suite.

---

## Code quality

```bash
flutter analyze          # must report "No issues found!"
dart format .            # formatter; the codebase is format-clean
dart fix --apply         # apply mechanical lint fixes
```

`analysis_options.yaml` is deliberately stricter than the Flutter default:

- `strict-casts`, `strict-inference` and `strict-raw-types` are all on, so
  implicit `dynamic` cannot creep in.
- **`unawaited_futures` is promoted from a lint to an error**, because an
  unawaited future in this codebase is almost always a backup or restore
  sequencing bug rather than a style choice.
- Additional rules including `always_declare_return_types`,
  `avoid_dynamic_calls`, `avoid_slow_async_io`, `directives_ordering`,
  `prefer_final_locals`, and `prefer_single_quotes`.

Keep `flutter analyze` at zero issues. Conventions the codebase follows:

- Use cases return `Result<T>` for expected failures; ports throw typed
  exceptions which use cases translate into `Failure`s.
- `Failure.message` is user-facing prose; technical text goes in
  `Failure.detail`.
- Use-case dependencies are public `final` fields with initializing formals.
- No business logic in widgets; no global mutable state; no platform-specific
  logic outside `lib/infrastructure/`.

`CLAUDE.md` documents the load-bearing invariants for contributors (and coding
agents) in more detail.

---

## Adding a new emulator

If the emulator's saves fit an existing layout, this is a small, contained
change.

**1. Check it is reachable.** The save folder must be in shared storage — not
under `Android/data/<package>`, which SAF cannot grant on Android 11+. If it is
under `Android/data`, stop: that needs root or the emulator's custom-save-path
setting, neither of which is designed yet.

**2. Add the registry entry** in `lib/domain/emulator/emulator_registry.dart`:

```dart
static final EmulatorDefinition _drastic = EmulatorDefinition(
  id: 'drastic',                                  // stable forever
  name: 'DraStic',
  platform: GamePlatform.nintendoDs,              // add to the enum if new
  androidPackageIds: const ['com.dsemu.drastic'],
  saveSources: [
    SaveSource(
      id: 'saves',
      label: 'DraStic backup folder',
      kind: SaveKind.saveData,
      androidPathHints: const ['DraStic/backup'],
      layout: FlatFilePerGameLayout(
        id: 'drastic.saves.v1',
        extensionPattern: RegExp(r'^dsv$', caseSensitive: false),
      ),
    ),
    SaveSource(
      id: 'states',
      label: 'DraStic savestates folder',
      kind: SaveKind.saveState,
      required: false,
      androidPathHints: const ['DraStic/savestates'],
      layout: FlatFilePerGameLayout(
        id: 'drastic.states.v1',
        extensionPattern: RegExp(r'^dss\d*$', caseSensitive: false),
      ),
    ),
  ],
);
```

…and add `_drastic` to the `_builtIn` list.

**3. Add the package ids to `<queries>`** in
`android/app/src/main/AndroidManifest.xml`:

```xml
<package android:name="com.dsemu.drastic" />
```

Without this the app still works — the emulator just will not be auto-detected,
and the user configures it manually.

**4. Add a test** in `test/domain/emulator/save_layout_test.dart` seeding an
`InMemoryFileSystem` with representative filenames, so the grouping rules are
pinned down.

**5. Update the [Supported emulators](#supported-emulators) table.**

**Rules of thumb.**

- `id` and every `SaveSource.id` are **stable forever** — they are written into
  backup manifests, and a source id becomes a path segment inside the archive.
  Never reuse one for a different meaning.
- Give `layout.id` a version suffix (`.v1`). If the grouping rules change in a
  way that alters which files belong to which game, bump it so old manifests
  remain interpretable.
- Mark save-state sources `required: false`. Their absence is normal and should
  not be reported as a missing-folder problem.
- If the emulator's layout genuinely does not fit `DirectoryPerGameLayout` or
  `FlatFilePerGameLayout`, write a new `SaveLayout` implementation. It only
  needs `id` and `discover(fs, root)`, and it must go through `FileSystemPort`
  so it stays testable and platform-independent.

---

## Troubleshooting

**`flutter doctor` reports missing Android licences.**
Run `flutter doctor --android-licenses` and accept them.

**Gradle sync fails with `flutter.sdk not set in local.properties`.**
`android/local.properties` is missing or incomplete. Run `flutter pub get` then
`flutter build apk --debug` once from the command line to regenerate it, or
create it by hand as shown in [First run](#first-run).

**The first Android build takes a very long time.**
Expected. It downloads the Gradle distribution (~200 MB), Android SDK platforms,
and Build-Tools. Subsequent builds are incremental and take seconds.

**`Unresolved reference: io.flutter` in `MainActivity.kt`.**
The Gradle sync has not completed. *File → Sync Project with Gradle Files*.

**Android Studio shows no Dart tooling / no run button.**
You opened `android/` instead of the repository root. Close the project and
reopen the folder containing `pubspec.yaml`.

**The app shows "No games found yet" even though saves exist.**
Check *Settings*: the save folder must be granted, and it must be the folder
that directly contains the per-game folders or files (for PPSSPP, `PSP/SAVEDATA`
itself — not `PSP`, and not `PSP/SAVEDATA/ULUS10041DATA00`).

**A folder that worked before now shows "no longer has access".**
Android revoked the persisted grant, which can happen after an app update, a
storage change, or the user clearing permissions. Re-pick the folder in
Settings.

**Backup fails with "cannot write to the backup folder".**
Same cause on the destination side. Re-pick the backup folder.

**A restore is refused because a folder is not selected.**
The backup contains save states (or save data) for a source you have not granted
a folder for. Grant it in Settings, then retry. Checkpoint refuses rather than
restoring only part of the archive.

**Build fails after changing dependencies.**

```bash
flutter clean
flutter pub get
flutter build apk --debug
```

---

## Toolchain versions

Versions this project is developed and verified against:

| Component | Version |
| --- | --- |
| Flutter | 3.47.0 (stable) |
| Dart | 3.13.0 |
| Android Gradle Plugin | 9.1.0 |
| Gradle | 9.3.1 |
| Kotlin | 2.4.0 |
| Java source/target compatibility | 17 |
| compileSdk / targetSdk | 36 |
| minSdk | 24 (Android 7.0) |
| NDK | 28.2.13676358 |
| Application id / namespace | `dev.checkpoint.checkpoint` |
| iOS bundle identifier | `dev.checkpoint.checkpoint` |

Direct Dart dependencies (resolved versions in `pubspec.lock`, which **is**
committed — this is an application, so builds should be reproducible):

| Package | Version | Used for |
| --- | --- | --- |
| `flutter_riverpod` | 3.4.2 | State management and dependency injection |
| `archive` | 4.0.9 | ZIP container read/write (extraction is hand-written) |
| `crypto` | 3.0.7 | SHA-256 for per-file integrity |
| `path` | 1.9.1 | Path manipulation |
| `path_provider` | 2.1.6 | Locating app-private storage for the config file |
| `collection` | 1.19.1 | Small collection helpers |
| `flutter_lints` | 6.0.0 | Lint baseline (dev dependency) |

---

## Current limitations

- **Not yet run on a physical device or emulator.** The APK builds and 145 tests
  pass, but the SAF code paths have not executed against a real
  `DocumentsProvider`. This is the single biggest caveat.
- **Three emulators**, all reachable without root. Nothing under `Android/data`
  works.
- **Archives are held in memory** while being packed or unpacked, bounded by
  `ArchiveLimits` (256 MB per file, 1 GB total uncompressed, 512 MB archive).
  Save folders are small, so this is fine in practice, but a very large one will
  fail rather than stream. A ZIP entry that *lies* about its uncompressed size
  can still force one oversized decompression before the post-check catches it;
  streaming extraction is the real fix.
- **No instrumented tests** for the Kotlin layer.
- **Backups are flat** in the backup folder, identified by filename. No per-game
  subfolders, no automatic rotation, no pruning of old backups.
- **No delete** for backups from inside the app.
- **Restore is all-or-nothing per archive.** You cannot restore only the save
  data and skip the save states.
- **Backup is all-or-nothing per game.** You cannot back up only one save slot.
- **Detection is a hint, not a gate.** You always pick every folder yourself.
- **iOS is scaffold only.** No storage adapter exists, and an iOS build has
  never been attempted — the target is unverified, not merely incomplete.
- **No backup encryption.** Archives are plain ZIPs; anyone with the file can
  read your saves.
- No dark/light theme toggle (it follows the system), no localisation, no
  accessibility audit has been performed.

---

## Roadmap

Ordered roughly by priority. Nothing here is committed to a date.

**Next**
- Instrumented tests for `SafStorage` against a real device
- Delete and prune backups from within the app, with a configurable retention
  count
- Per-game subfolders in the backup destination
- More SAF-reachable emulators: DraStic, Lemuroid, Pizza Boy, Flycast, Vita3K
- Streaming archive read/write, lifting the in-memory bound

**Later**
- iOS storage adapter behind the existing ports (security-scoped bookmarks)
- Emulators that expose a custom save path (Eden / Yuzu / Citron family)
- Root access, strictly isolated behind a port, for `Android/data` emulators
- Selective restore — choose which sources or individual files
- Verify a backup's integrity without restoring it
- Import a backup from outside the backup folder
- Optional backup encryption
- Localisation

**Explicitly out of scope for now**
Cloud synchronisation, accounts, authentication, analytics, telemetry, and any
backend service.

---

## Contributing

1. Read `CLAUDE.md` — it documents the invariants that are load-bearing and
   should not be "simplified" away.
2. `flutter analyze` must report zero issues and `flutter test` must be green.
3. Add tests for behaviour, especially anything touching path handling, archive
   extraction, or the manifest. Do not add tests that only restate the
   implementation.
4. Do not add a dependency without a clear reason; do not add a permission
   without a very clear one.
5. Keep the domain free of Flutter and platform imports.

---

## Licence and acknowledgements

See [LICENSE](LICENSE).

Checkpoint's emulator knowledge — which emulator stores saves where, and in what
shape — was informed by studying **SaveState-App**, an existing open-source
Android save manager, as a reference. **No code was copied.** Several of its
design decisions were examined and deliberately *not* carried over:

- a single ~1,200-line Activity holding all state, with no ViewModel,
  repository, or dependency injection;
- `MANAGE_EXTERNAL_STORAGE` and `QUERY_ALL_PACKAGES`, where scoped SAF grants
  and a `<queries>` declaration suffice;
- a substring `contains("..")` check in place of real path normalisation;
- a backup manifest that is written but never read back or verified on restore;
- three mutually incompatible archive layouts that restore has to guess between
  using folder-name heuristics;
- root access via interpolated `su` command lines;
- a reflective anti-piracy licence gate;
- and no tests at all.

Those contrasts shaped much of what is written above.
