import 'dart:convert';
import 'dart:typed_data';

import 'package:checkpoint/application/usecases/create_backup.dart';
import 'package:checkpoint/application/usecases/discover_games.dart';
import 'package:checkpoint/application/usecases/list_backups.dart';
import 'package:checkpoint/application/usecases/restore_backup.dart';
import 'package:checkpoint/core/failure.dart';
import 'package:checkpoint/core/result.dart';
import 'package:checkpoint/domain/config/app_configuration.dart';
import 'package:checkpoint/domain/emulator/emulator_registry.dart';
import 'package:checkpoint/domain/emulator/save_kind.dart';
import 'package:checkpoint/domain/game/discovered_game.dart';
import 'package:checkpoint/domain/storage/safe_path.dart';
import 'package:checkpoint/domain/storage/storage_root.dart';
import 'package:checkpoint/infrastructure/archive/zip_backup_archive.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/in_memory_file_system.dart';

/// Exercises the whole vertical slice — discover, back up, restore — with only
/// the platform swapped for an in-memory fake. Everything above the ports is
/// the same code that runs on a device.
void main() {
  const saveDataRoot = StorageRoot(
    id: 'root://psp-savedata',
    displayName: 'SAVEDATA',
    displayPath: 'Internal storage/PSP/SAVEDATA',
  );
  const stateRoot = StorageRoot(
    id: 'root://psp-states',
    displayName: 'PPSSPP_STATE',
    displayPath: 'Internal storage/PSP/PPSSPP_STATE',
  );
  const backupRoot = StorageRoot(
    id: 'root://backups',
    displayName: 'Checkpoint',
    displayPath: 'Internal storage/Checkpoint',
  );

  const configuration = AppConfiguration(
    backupRoot: backupRoot,
    saveRoots: [
      GrantedSaveRoot(
        emulatorId: 'ppsspp',
        sourceId: 'savedata',
        root: saveDataRoot,
      ),
      GrantedSaveRoot(
        emulatorId: 'ppsspp',
        sourceId: 'states',
        root: stateRoot,
      ),
    ],
  );

  late InMemoryFileSystem fs;
  late DiscoverGames discoverGames;
  late CreateBackup createBackup;
  late RestoreBackup restoreBackup;
  late ListBackups listBackups;

  Uint8List bytesOf(String value) => Uint8List.fromList(utf8.encode(value));

  setUp(() {
    fs = InMemoryFileSystem();
    const archive = ZipBackupArchive();
    final registry = EmulatorRegistry.defaults();

    discoverGames = DiscoverGames(registry: registry, fileSystem: fs);
    createBackup = CreateBackup(
      fileSystem: fs,
      archive: archive,
      appVersion: '0.1.0-test',
      clock: () => DateTime.utc(2026, 8, 16, 12, 0, 0),
    );
    restoreBackup = RestoreBackup(fileSystem: fs, archive: archive);
    listBackups = ListBackups(fileSystem: fs);

    fs
      ..seedFile(saveDataRoot, 'ULUS10041DATA00/SAVE.BIN', bytesOf('progress'))
      ..seedFile(saveDataRoot, 'ULUS10041DATA00/ICON0.PNG', bytesOf('icon'))
      ..seedFile(
        saveDataRoot,
        'ULUS10041PROFILE00/SETTINGS.BIN',
        bytesOf('settings'),
      )
      ..seedFile(stateRoot, 'ULUS10041_1.00_0.ppst', bytesOf('state'))
      // A different game, to prove backups do not sweep up their neighbours.
      ..seedFile(saveDataRoot, 'ULES00181DATA00/SAVE.BIN', bytesOf('other'));
  });

  test('discovers a game across both of its save folders', () async {
    final result = await discoverGames(configuration);

    expect(result.issues, isEmpty);
    expect(result.games.map((g) => g.gameId), ['ULES00181', 'ULUS10041']);

    final game = result.games.firstWhere((g) => g.gameId == 'ULUS10041');
    expect(game.emulatorId, 'ppsspp');
    expect(game.saveSets, hasLength(2));
    expect(game.hasSaveData, isTrue);
    expect(game.hasSaveStates, isTrue);
    expect(game.fileCount, 4);

    final states = game.saveSets.firstWhere(
      (s) => s.kind == SaveKind.saveState,
    );
    expect(states.files.single.value, 'ULUS10041_1.00_0.ppst');
  });

  test('backs up a game and restores it byte for byte', () async {
    final discovered = await discoverGames(configuration);
    final game = discovered.games.firstWhere((g) => g.gameId == 'ULUS10041');

    final backup = await createBackup(game: game, backupRoot: backupRoot);
    expect(backup, isA<Ok<CreatedBackup>>());

    final created = backup.valueOrNull!;
    expect(created.manifest.fileCount, 4);
    expect(created.manifest.gameId, 'ULUS10041');
    expect(created.manifest.emulatorId, 'ppsspp');
    expect(created.manifest.sources.map((s) => s.id), ['savedata', 'states']);
    expect(created.fileName, contains('ppsspp'));
    expect(created.fileName, contains('20260816-120000'));

    // The user's saves get corrupted after the backup.
    fs
      ..seedFile(saveDataRoot, 'ULUS10041DATA00/SAVE.BIN', bytesOf('CORRUPT'))
      ..seedFile(stateRoot, 'ULUS10041_1.00_0.ppst', bytesOf('CORRUPT'));

    final summaries = await listBackups(backupRoot: backupRoot);
    final summary = summaries.valueOrNull!.single;
    expect(summary.fileName, created.fileName);
    expect(summary.emulatorId, 'ppsspp');

    final plan = await restoreBackup.inspect(
      backupRoot: backupRoot,
      archivePath: summary.path,
      configuration: configuration,
    );
    expect(plan, isA<Ok<RestorePlan>>());
    expect(plan.valueOrNull!.canApply, isTrue);
    expect(plan.valueOrNull!.touchesSaveData, isTrue);
    expect(plan.valueOrNull!.touchesSaveStates, isTrue);

    final restored = await restoreBackup.apply(
      backupRoot: backupRoot,
      plan: plan.valueOrNull!,
    );
    expect(restored, isA<Ok<RestoreSummary>>());
    expect(restored.valueOrNull!.filesRestored, 4);

    expect(
      fs.fileAt(saveDataRoot, 'ULUS10041DATA00/SAVE.BIN'),
      bytesOf('progress'),
    );
    expect(fs.fileAt(stateRoot, 'ULUS10041_1.00_0.ppst'), bytesOf('state'));
  });

  test('restore leaves other games in a shared folder untouched', () async {
    final discovered = await discoverGames(configuration);
    final game = discovered.games.firstWhere((g) => g.gameId == 'ULUS10041');
    await createBackup(game: game, backupRoot: backupRoot);

    final summary = (await listBackups(backupRoot: backupRoot))
        .valueOrNull!
        .single;
    final plan = (await restoreBackup.inspect(
      backupRoot: backupRoot,
      archivePath: summary.path,
      configuration: configuration,
    )).valueOrNull!;

    fs.writeLog.clear();
    await restoreBackup.apply(backupRoot: backupRoot, plan: plan);

    // Only this game's files were written; the neighbour was never touched.
    expect(fs.writeLog, hasLength(4));
    expect(fs.writeLog.any((entry) => entry.contains('ULES00181')), isFalse);
    expect(
      fs.fileAt(saveDataRoot, 'ULES00181DATA00/SAVE.BIN'),
      bytesOf('other'),
    );
  });

  test('a backup only contains the game it names', () async {
    final discovered = await discoverGames(configuration);
    final game = discovered.games.firstWhere((g) => g.gameId == 'ULUS10041');
    final created = (await createBackup(
      game: game,
      backupRoot: backupRoot,
    )).valueOrNull!;

    expect(
      created.manifest.files.every((f) => f.path.value.contains('ULUS10041')),
      isTrue,
    );
  });

  test('reports progress that reaches completion', () async {
    final discovered = await discoverGames(configuration);
    final game = discovered.games.firstWhere((g) => g.gameId == 'ULUS10041');

    final labels = <String>[];
    var lastCompleted = -1;
    await createBackup(
      game: game,
      backupRoot: backupRoot,
      onProgress: (progress) {
        labels.add(progress.label);
        expect(progress.completed, greaterThanOrEqualTo(lastCompleted));
        lastCompleted = progress.completed;
      },
    );

    expect(labels, contains('Compressing backup'));
    expect(labels.last, 'Writing backup');
    expect(lastCompleted, game.fileCount);
  });

  group('failure handling', () {
    test(
      'discovery reports a revoked folder instead of hiding games',
      () async {
        fs.makeInaccessible(stateRoot);

        final result = await discoverGames(configuration);

        expect(result.games, isNotEmpty, reason: 'save data still readable');
        expect(result.issues, hasLength(1));
        expect(result.issues.single.failure, isA<PermissionFailure>());
        expect(result.issues.single.sourceLabel, contains('save state'));
      },
    );

    test('backing up fails clearly when the backup folder is gone', () async {
      final discovered = await discoverGames(configuration);
      final game = discovered.games.first;
      fs.makeInaccessible(backupRoot);

      final result = await createBackup(game: game, backupRoot: backupRoot);
      expect(result, isA<Err<CreatedBackup>>());
      expect(result.failureOrNull, isA<PermissionFailure>());
    });

    test(
      'a restore with no folder for a source is refused, not partial',
      () async {
        final discovered = await discoverGames(configuration);
        final game = discovered.games.firstWhere(
          (g) => g.gameId == 'ULUS10041',
        );
        await createBackup(game: game, backupRoot: backupRoot);

        final summary = (await listBackups(backupRoot: backupRoot))
            .valueOrNull!
            .single;

        // The user removed the save-state folder after taking the backup.
        const partial = AppConfiguration(
          backupRoot: backupRoot,
          saveRoots: [
            GrantedSaveRoot(
              emulatorId: 'ppsspp',
              sourceId: 'savedata',
              root: saveDataRoot,
            ),
          ],
        );

        final plan = (await restoreBackup.inspect(
          backupRoot: backupRoot,
          archivePath: summary.path,
          configuration: partial,
        )).valueOrNull!;

        expect(plan.canApply, isFalse);
        expect(plan.unresolved.single.source.id, 'states');

        fs.writeLog.clear();
        final result = await restoreBackup.apply(
          backupRoot: backupRoot,
          plan: plan,
        );
        expect(result, isA<Err<RestoreSummary>>());
        expect(fs.writeLog, isEmpty, reason: 'nothing may be written');
      },
    );

    test('backing up a game with no files is refused', () async {
      const empty = DiscoveredGame(
        emulatorId: 'ppsspp',
        emulatorName: 'PPSSPP',
        gameId: 'ULUS99999',
        title: 'Nothing here',
        saveSets: [],
      );

      final result = await createBackup(game: empty, backupRoot: backupRoot);
      expect(result, isA<Err<CreatedBackup>>());
      expect(result.failureOrNull, isA<ValidationFailure>());
    });

    test('listing ignores files that are not Checkpoint backups', () async {
      fs
        ..seedFile(backupRoot, 'holiday-photo.jpg', [1, 2, 3])
        ..seedFile(backupRoot, 'notes.txt', [4]);

      final result = await listBackups(backupRoot: backupRoot);
      expect(result.valueOrNull, isEmpty);
    });
  });

  test('backup filenames survive a game id full of awkward characters', () {
    final path = SafePath.parse(
      'checkpoint__retroarch__Legend_of_Zelda_The__20260816-120000.zip',
    );
    expect(path, isA<Ok<SafePath>>());
  });
}
