import 'dart:io';

import 'package:checkpoint/domain/config/app_configuration.dart';
import 'package:checkpoint/domain/storage/storage_root.dart';
import 'package:checkpoint/infrastructure/persistence/json_configuration_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// The configuration holds the user's folder grants. Losing it means they have
/// to re-pick every folder, so the failure behaviour matters as much as the
/// happy path.
void main() {
  late Directory directory;
  late JsonConfigurationRepository repository;

  File configFile() =>
      File(p.join(directory.path, JsonConfigurationRepository.fileName));

  setUp(() {
    directory = Directory.systemTemp.createTempSync('checkpoint_config_test');
    repository = JsonConfigurationRepository(directory: () async => directory);
  });

  tearDown(() => directory.deleteSync(recursive: true));

  test('starts empty when nothing has been saved', () async {
    final configuration = await repository.load();
    expect(configuration.backupRoot, isNull);
    expect(configuration.saveRoots, isEmpty);
  });

  test('round trips grants through the file', () async {
    const configuration = AppConfiguration(
      backupRoot: StorageRoot(
        id: 'content://tree/backups',
        displayName: 'Checkpoint',
        displayPath: 'Internal storage/Checkpoint',
      ),
      saveRoots: [
        GrantedSaveRoot(
          emulatorId: 'ppsspp',
          sourceId: 'savedata',
          root: StorageRoot(
            id: 'content://tree/psp',
            displayName: 'SAVEDATA',
            displayPath: 'Internal storage/PSP/SAVEDATA',
          ),
        ),
      ],
    );

    await repository.save(configuration);

    // A fresh instance, so the cache cannot mask a broken write.
    final reloaded = await JsonConfigurationRepository(
      directory: () async => directory,
    ).load();

    expect(reloaded.backupRoot!.id, 'content://tree/backups');
    expect(reloaded.backupRoot!.displayPath, 'Internal storage/Checkpoint');
    expect(reloaded.saveRoots, hasLength(1));
    expect(
      reloaded.saveRootFor('ppsspp', 'savedata')!.id,
      'content://tree/psp',
    );
    expect(reloaded.saveRootFor('ppsspp', 'states'), isNull);
  });

  test('replacing a grant does not duplicate it', () async {
    const first = StorageRoot(id: 'content://tree/a', displayName: 'A');
    const second = StorageRoot(id: 'content://tree/b', displayName: 'B');

    var configuration = AppConfiguration.empty.withSaveRoot(
      const GrantedSaveRoot(emulatorId: 'mgba', sourceId: 'saves', root: first),
    );
    configuration = configuration.withSaveRoot(
      const GrantedSaveRoot(
        emulatorId: 'mgba',
        sourceId: 'saves',
        root: second,
      ),
    );
    await repository.save(configuration);

    final reloaded = await JsonConfigurationRepository(
      directory: () async => directory,
    ).load();

    expect(reloaded.saveRoots, hasLength(1));
    expect(reloaded.saveRootFor('mgba', 'saves')!.id, 'content://tree/b');
  });

  test('a corrupt file degrades to empty rather than crashing', () async {
    configFile().writeAsStringSync('{ this is not json');

    final configuration = await JsonConfigurationRepository(
      directory: () async => directory,
    ).load();

    expect(configuration.backupRoot, isNull);
    expect(configuration.saveRoots, isEmpty);
  });

  test('malformed entries are skipped, valid ones survive', () async {
    configFile().writeAsStringSync('''
{
  "version": 1,
  "backupRoot": {"displayName": "no id here"},
  "saveRoots": [
    {"emulatorId": "ppsspp"},
    "not an object",
    {"emulatorId": "mgba", "sourceId": "saves", "rootId": "content://tree/ok"}
  ]
}
''');

    final configuration = await JsonConfigurationRepository(
      directory: () async => directory,
    ).load();

    expect(configuration.backupRoot, isNull, reason: 'entry had no rootId');
    expect(configuration.saveRoots, hasLength(1));
    expect(configuration.saveRootFor('mgba', 'saves')!.id, 'content://tree/ok');
  });

  test('writes leave no temporary file behind', () async {
    await repository.save(
      AppConfiguration.empty.withBackupRoot(
        const StorageRoot(id: 'content://tree/x', displayName: 'X'),
      ),
    );

    final names = directory.listSync().map((e) => p.basename(e.path)).toList();
    expect(names, [JsonConfigurationRepository.fileName]);
  });

  test('removing a grant persists the removal', () async {
    await repository.save(
      AppConfiguration.empty.withSaveRoot(
        const GrantedSaveRoot(
          emulatorId: 'retroarch',
          sourceId: 'saves',
          root: StorageRoot(id: 'content://tree/ra', displayName: 'saves'),
        ),
      ),
    );
    final current = await repository.load();
    await repository.save(current.withoutSaveRoot('retroarch', 'saves'));

    final reloaded = await JsonConfigurationRepository(
      directory: () async => directory,
    ).load();
    expect(reloaded.saveRoots, isEmpty);
  });
}
