# Checkpoint

A cross-platform game save manager for backing up, restoring, and managing your
emulator saves.

Checkpoint finds the games your emulators have saves for, packs those saves into
a versioned, checksummed archive in a folder you choose, and puts them back when
you need them — without asking for a single broad storage permission.

> **Status: early MVP.** The backup and restore path works end to end on
> Android for three emulators. Everything marked *Planned* below does not exist
> yet.

---

## Supported platforms

| Platform | Status |
| --- | --- |
| Android | **Implemented** (minSdk per Flutter default, tested against API 36 tooling) |
| iOS | *Planned.* The project builds for iOS and the architecture keeps platform code behind ports, but no iOS storage adapter exists yet, so the app has nothing to read. |
| Desktop | Not started. |

## Supported emulators

| Emulator | System | Save data | Save states | Access |
| --- | --- | --- | --- | --- |
| PPSSPP | PlayStation Portable | `PSP/SAVEDATA` | `PSP/PPSSPP_STATE` | SAF |
| RetroArch | Multi-system | `RetroArch/saves` | `RetroArch/states` | SAF |
| mGBA | Game Boy Advance | `mGBA/saves` | `mGBA/states` | SAF |

These three were chosen because all of them keep saves in ordinary shared
storage, which the Storage Access Framework can reach. PPSSPP additionally gets
real game titles: Checkpoint parses `PARAM.SFO`, so `ULUS10041` is shown as
*God of War: Chains of Olympus*.

**Not supported yet:** emulators that hide saves under `Android/data`
(Dolphin, DuckStation, Citra/Azahar, the Yuzu/Citron/Eden family, AetherSX2 and
others). Reaching those needs either root or the emulator's own custom-save-path
setting, and neither is designed yet — see the roadmap.

---

## Architecture

Four layers, each depending only on the one beneath it:

```text
Presentation      Flutter widgets. No business logic.
      ↓
Application       Use cases + Riverpod state. Orchestration only.
      ↓
Domain            Entities, ports, emulator registry, backup format.
                  Pure Dart — no Flutter, no platform imports.
      ↓
Infrastructure    SAF adapter (Kotlin + method channel), ZIP archive,
                  JSON persistence.
```

The domain declares interfaces (`FileSystemPort`, `DirectoryPickerPort`,
`InstalledAppPort`, `BackupArchivePort`, `ConfigurationRepository`) and
infrastructure implements them. Nothing above infrastructure knows what SAF is.
That is what lets the whole discover → back up → restore path run in tests
against an in-memory filesystem, and what makes iOS support an additional
adapter rather than a rewrite.

### Emulator integration

An emulator is a `const` entry in `EmulatorRegistry`:

```dart
EmulatorDefinition(
  id: 'ppsspp',
  name: 'PPSSPP',
  platform: GamePlatform.playStationPortable,
  androidPackageIds: ['org.ppsspp.ppsspp', 'org.ppsspp.ppssppgold'],
  saveSources: [
    SaveSource(
      id: 'savedata',
      label: 'PSP save data folder',
      kind: SaveKind.saveData,
      androidPathHints: ['PSP/SAVEDATA'],
      layout: DirectoryPerGameLayout(...),
    ),
    // ...one more for save states
  ],
)
```

Each `SaveSource` pairs a **kind** (save data or save state — a first-class
distinction, so the UI can tell the user which one a restore is about to
overwrite) with a **layout strategy** that knows how to enumerate games in that
folder. Two layouts cover all three emulators:

- `DirectoryPerGameLayout` — one directory per game, several directories
  grouped onto one game id (PPSSPP's `DATA00`/`PROFILE00` split).
- `FlatFilePerGameLayout` — flat files in a shared folder grouped by base name,
  with optional id extraction (`ULUS10041_1.00_0.ppst` → `ULUS10041`).

Adding an emulator whose saves fit an existing layout is **one registry entry
plus its package ids in `AndroidManifest.xml`** — no `switch`, no new manager
class, no changes to discovery, backup, restore, or UI.

### Backup format

A backup is a ZIP with a versioned manifest at its root:

```text
checkpoint.json                     manifest
files/<sourceId>/<relative path>    payload — nothing lives outside files/
```

The manifest records format version, Checkpoint version, emulator, game,
creation time (UTC), every source folder the files came from, and for each file
its path, size and SHA-256. Filenames follow
`checkpoint__<emulator>__<game>__<yyyyMMdd-HHmmss>.zip` so the backup list can
be built from a directory listing without opening every archive — but the
manifest inside is always the authority, and restore reads it.

`formatVersion` is checked before anything in an archive is trusted. A backup
from a newer Checkpoint is refused with a clear message rather than
half-restored, and `BackupManifest._migrate` is the hook for upgrading older
documents as the format evolves.

### State management: Riverpod

Chosen for testability and explicit dependency boundaries:

- Every dependency is a provider, so a test overrides `fileSystemProvider` with
  an in-memory fake and the entire stack above runs unchanged.
- `AsyncValue` maps directly onto the loading / data / error states the UI has
  to render, so no screen invents its own.
- No `BuildContext` coupling and no code generation, keeping the build simple.

Transfers use a sealed `TransferState` (idle / running / succeeded / failed) so
the UI must handle every case and cannot render "loading and error" at once.

### Persistence

Configuration — the folders you granted and where backups go — is a JSON
document written atomically to app-private storage, behind
`ConfigurationRepository`.

A database is not used because the data is a handful of grants, always read and
written whole; a relational store would add a schema, migrations and a code
generator to buy indexing nothing needs. Discovered games are deliberately
**not** cached: rescanning is fast and always correct, whereas a stale cache
shows games whose saves have moved. The interface is what makes this
reversible — the first feature that needs to *query* this data changes the
implementation and nothing else.

---

## Security

Save backups are treated as untrusted data, because a backup file is just a
file the user obtained somewhere.

**Permissions.** Checkpoint requests **no storage permissions at all** — no
`MANAGE_EXTERNAL_STORAGE`, no legacy `READ/WRITE_EXTERNAL_STORAGE`. Every byte
it reads or writes is inside a folder the user picked through the Storage Access
Framework. Emulator detection uses a scoped `<queries>` manifest declaration
naming the exact packages, not `QUERY_ALL_PACKAGES`.

**Path safety.** `SafePath` is the single chokepoint: it is the only path type
the archive layer and filesystem ports accept, and it can only be built through
a validating parser. It rejects absolute paths, drive letters, UNC paths, `..`
and `.` components, empty components, backslashes, control characters including
NUL, names with trailing dots or spaces, and Windows reserved device names.
Because a `SafePath` is relative and `..`-free by construction, containment is a
property of the type rather than a check that can be forgotten.

**Archive extraction.** Restore never uses a library's "extract to disk" helper.
Instead:

1. The **manifest is the allowlist** — only files it declares are ever
   decompressed, so an extra ZIP entry cannot smuggle a file in.
2. Symbolic link entries cause the whole archive to be **rejected**, not
   skipped.
3. Sizes are bounded before decompression and re-checked afterwards
   (entry count, per-file, total, and archive size).
4. Every file's SHA-256 is verified against the manifest before it is written.
5. Restore is refused outright if any source in the backup has no granted
   destination — a half-restored save is worse than none.

**Restore behaviour.** Files in the backup replace matching files in the save
folder; anything else in that folder is left untouched. Wiping the destination
first would be tidier, but RetroArch and mGBA keep every game's saves in one
flat folder, so it would destroy other games' saves.

**No root.** Not in the MVP. If it is added later it goes behind a port, like
everything else platform-specific.

**No telemetry, no analytics, no network access, no accounts, no secrets.**

---

## Build and run

Requires the Flutter SDK (3.47+) and, for Android, the Android SDK.

```bash
flutter pub get
flutter run                  # on a connected device or emulator
flutter build apk --debug    # or --release, once you add a signing config
```

Checks:

```bash
flutter analyze
flutter test
flutter test test/domain/storage/safe_path_test.dart   # a single file
```

The release build currently signs with the debug key (the Flutter default);
add a real signing config before distributing anything.

---

## Testing

Tests concentrate on what is security- and business-critical rather than on
coverage for its own sake.

| Area | What is covered |
| --- | --- |
| `SafePath` | Traversal, absolute paths, separators, control characters, reserved names, containment being segment-wise rather than string-prefix |
| Archive safety | Hand-built malicious archives: traversal, absolute paths, traversal in a source id, symlink entries, undeclared entries, tampered payloads, size mismatches, resource limits |
| Backup format | Round trip, version gating in both directions, every malformed-input rejection path |
| Backup naming | Slugging hostile game ids, round trip, rejecting foreign filenames |
| Save layouts | Both strategies against an in-memory filesystem, including `PARAM.SFO` title parsing |
| End to end | discover → back up → corrupt → restore → verify bytes, plus revoked folders, missing destinations, and progress reporting |
| UI | Games screen in its loading, empty, populated, error and degraded states |

The symlink test is worth a note: `ZipEncoder` always stamps an MS-DOS
`versionMadeBy`, and the decoder only honours symlink mode bits on UNIX-made
archives, so a fixture built with the package's own encoder could never actually
*be* a symlink archive. The test patches the central directory to reproduce a
real one.

---

## Current limitations

- **Three emulators**, all reachable without root. Nothing under `Android/data`
  works.
- **Archives are held in memory** while being packed or unpacked, bounded by
  `ArchiveLimits`. Save folders are small, but a very large one will fail
  rather than stream. A ZIP entry that lies about its uncompressed size can
  still force one oversized decompression before the post-check catches it;
  streaming extraction is the real fix.
- **Backups are flat** in the backup folder, identified by filename. No
  per-game subfolders, no automatic rotation or pruning of old backups.
- **No delete** for backups from inside the app yet.
- **Restore is all-or-nothing per archive** — you cannot restore only the save
  data and skip the save states.
- **Detection is a hint, not a gate.** Emulator detection tells you what is
  installed; you still pick every folder yourself, and the app works fine for an
  emulator it cannot see.
- **iOS builds but does nothing useful** — no storage adapter.
- No dark/light theme toggle (follows the system), no localisation.

## Roadmap

**Next**
- Delete and prune backups from the app
- Per-game subfolders in the backup destination
- More SAF-reachable emulators (DraStic, Lemuroid, Pizza Boy, Flycast)
- Streaming archive read/write to lift the in-memory bound

**Later**
- iOS storage adapter behind the existing ports
- Emulators with custom-save-path settings (Eden/Yuzu/Citron family)
- Root access, isolated behind a port, for `Android/data` emulators
- Selective restore (choose which sources or files)
- Backup verification without restoring

**Explicitly out of scope for now:** cloud sync, accounts, authentication,
analytics, telemetry, any backend.

---

## Licence

See [LICENSE](LICENSE).

Checkpoint was informed by studying [SaveState-App](https://github.com/) as a
reference for which emulators store saves where. No code was copied, and several
of its design decisions — a single giant activity, broad storage permissions,
substring-based path checks, and an unverified backup manifest — were
deliberately not carried over.
