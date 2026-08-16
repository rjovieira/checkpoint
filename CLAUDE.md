# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with
code in this repository.

## Project

Checkpoint — a Flutter cross-platform game save manager for backing up and
restoring emulator saves. Android is implemented; iOS builds but has no storage
adapter yet. See `README.md` for user-facing docs and the roadmap.

## Build & test

```bash
flutter pub get
flutter analyze                                        # must stay clean
flutter test                                           # whole suite
flutter test test/domain/storage/safe_path_test.dart   # single file
flutter test --plain-name "rejects a symbolic link"    # single test
flutter run                                            # device/emulator
flutter build apk --debug
```

The Android build needs `ANDROID_HOME` (or `local.properties` with `sdk.dir`).
Release builds currently sign with the debug key — the Flutter scaffold default,
not a decision.

`flutter analyze` is configured strictly in `analysis_options.yaml`
(`strict-casts`, `strict-inference`, `strict-raw-types`, and
`unawaited_futures` promoted to an **error** because an unawaited future here is
almost always a backup/restore sequencing bug). Keep it at zero issues.

## Architecture

Four layers, dependencies point downward only:

```text
lib/presentation/    widgets only, no business logic
lib/application/     use cases + Riverpod providers
lib/domain/          entities, ports, emulator registry, backup format
                     (pure Dart — no Flutter, no platform imports)
lib/infrastructure/  SAF adapter, ZIP archive, JSON persistence
```

The domain declares ports (`FileSystemPort`, `DirectoryPickerPort`,
`InstalledAppPort`, `BackupArchivePort`, `ConfigurationRepository`);
`lib/application/providers.dart` is the composition root that binds them to
infrastructure. **Never import `lib/infrastructure/` or `package:flutter/` from
`lib/domain/`** — that boundary is what lets the entire discover → backup →
restore path run against `test/support/in_memory_file_system.dart`.

## Things that are load-bearing

### `SafePath` is the security boundary

`lib/domain/storage/safe_path.dart` is the only way to construct a path, and
both the archive layer and the filesystem ports accept nothing else. Containment
is a property of the type: a `SafePath` is relative and `..`-free by
construction, so extraction code needs no second "is it still inside?" check.

Do not add an escape hatch, do not accept raw strings in a port, and do not
"fix" a rejected path by loosening a rule — `test/domain/storage/safe_path_test.dart`
documents why each rule exists.

### Restore extracts only what the manifest declares

`ZipBackupArchive.unpack` iterates `manifest.files`, not the ZIP's entries. An
entry that is not in the manifest is never decompressed and never written. It
also rejects symlink entries outright, bounds sizes before decompressing, and
verifies SHA-256. Never replace this with `extractArchiveToDisk`.

### Adding an emulator

One `const` entry in `EmulatorRegistry._builtIn` **plus** its package ids in
`android/app/src/main/AndroidManifest.xml`'s `<queries>` block. If the save
layout is a shape that already exists (`DirectoryPerGameLayout`,
`FlatFilePerGameLayout`), nothing else changes — no `switch`, no manager class.

Only add emulators whose saves are reachable via SAF. Anything under
`Android/data` needs root or a custom-save-path setting, neither of which is
designed yet.

`FlatFilePerGameLayout.idPattern` exists because PPSSPP names save states
`<GAMEID>_<version>_<slot>.ppst`; without it, states form their own "game"
instead of merging with the same title's save data.

### Permissions

`AndroidManifest.xml` declares **no permissions**, deliberately. Storage access
is entirely SAF grants; emulator detection is a scoped `<queries>` list. Adding
`MANAGE_EXTERNAL_STORAGE` or `QUERY_ALL_PACKAGES` would be a regression, not a
convenience.

### Version constants

`pubspec.yaml`'s `version:` and `checkpointVersion` in `lib/core/app_info.dart`
must match; the latter is written into every backup manifest.

`BackupManifest.currentFormatVersion` gates what can be read. Bumping it means
adding a case to `BackupManifest._migrate`.

## Conventions

- Use cases return `Result<T>` (`lib/core/result.dart`) for expected failures;
  programming errors still throw. Ports throw `StorageException` /
  `StorageAccessDeniedException`, which use cases translate into `Failure`s.
- `Failure.message` is user-facing prose; technical detail goes in
  `Failure.detail`, which the UI keeps collapsed.
- Use-case dependencies are public final fields with initializing formals.
- Android platform code lives only in
  `android/app/src/main/kotlin/dev/checkpoint/checkpoint/` — `MainActivity.kt`
  (channel dispatch, activity results) and `SafStorage.kt` (DocumentsContract).
  SAF work runs on a background executor; `MethodChannel.Result` is always
  replied to on the main thread.
- `SafStorage` queries `COLUMN_DISPLAY_NAME` directly rather than using
  `DocumentFile.getName()`, which appends a MIME-derived extension to
  extension-less files and would rename saves like `file0` to `file0.bin`.

## Testing

Security-critical behaviour is tested first: `SafePath` rules, adversarial
archives, manifest rejection paths. `test/application/backup_restore_round_trip_test.dart`
is the vertical slice and the best place to start when changing discovery,
backup, or restore.

Widget tests override `installedAppsProvider` with `UnsupportedInstalledApps`
so nothing reaches a real platform channel. Riverpod 3 does not export the
`Override` type, so shared overrides live in an inferred `final` list and are
spread into each test's literal rather than passed through a typed helper.

Avoid writing tests that only restate the implementation.

## Repository notes

The repo was created from the Flutter template on GitHub but had a plain
IntelliJ Kotlin "Hello World" scaffold committed over it locally; that scaffold
was removed and `flutter create` was run in place. `.idea/` and `*.iml` are
generated by the IDE.
