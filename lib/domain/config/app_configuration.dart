import 'package:checkpoint/domain/storage/storage_root.dart';

/// A save folder the user has granted for one emulator source.
final class GrantedSaveRoot {
  const GrantedSaveRoot({
    required this.emulatorId,
    required this.sourceId,
    required this.root,
  });

  final String emulatorId;
  final String sourceId;
  final StorageRoot root;

  String get key => '$emulatorId:$sourceId';

  Map<String, Object?> toJson() => {
    'emulatorId': emulatorId,
    'sourceId': sourceId,
    'rootId': root.id,
    'displayName': root.displayName,
    if (root.displayPath != null) 'displayPath': root.displayPath,
  };

  static GrantedSaveRoot? fromJson(Map<String, Object?> json) {
    final emulatorId = json['emulatorId'];
    final sourceId = json['sourceId'];
    final rootId = json['rootId'];
    if (emulatorId is! String || sourceId is! String || rootId is! String) {
      return null;
    }
    return GrantedSaveRoot(
      emulatorId: emulatorId,
      sourceId: sourceId,
      root: StorageRoot(
        id: rootId,
        displayName: json['displayName'] as String? ?? sourceId,
        displayPath: json['displayPath'] as String?,
      ),
    );
  }
}

/// Everything Checkpoint remembers between launches.
///
/// Deliberately small: it holds the user's *choices* (which folders they
/// granted, where backups go) and nothing that can be recomputed. Discovered
/// games are not persisted — rescanning is fast and always correct, whereas a
/// stale cache silently shows games whose saves have moved.
final class AppConfiguration {
  const AppConfiguration({this.backupRoot, this.saveRoots = const []});

  /// Where backups are written. Null until the user picks a folder.
  final StorageRoot? backupRoot;

  final List<GrantedSaveRoot> saveRoots;

  static const AppConfiguration empty = AppConfiguration();

  StorageRoot? saveRootFor(String emulatorId, String sourceId) {
    for (final granted in saveRoots) {
      if (granted.emulatorId == emulatorId && granted.sourceId == sourceId) {
        return granted.root;
      }
    }
    return null;
  }

  bool hasAnySaveRootFor(String emulatorId) =>
      saveRoots.any((r) => r.emulatorId == emulatorId);

  AppConfiguration withBackupRoot(StorageRoot? root) =>
      AppConfiguration(backupRoot: root, saveRoots: saveRoots);

  AppConfiguration withSaveRoot(GrantedSaveRoot granted) => AppConfiguration(
    backupRoot: backupRoot,
    saveRoots: [
      ...saveRoots.where((r) => r.key != granted.key),
      granted,
    ],
  );

  AppConfiguration withoutSaveRoot(String emulatorId, String sourceId) =>
      AppConfiguration(
        backupRoot: backupRoot,
        saveRoots: saveRoots
            .where((r) => r.key != '$emulatorId:$sourceId')
            .toList(),
      );

  Map<String, Object?> toJson() => {
    'version': 1,
    if (backupRoot != null)
      'backupRoot': {
        'rootId': backupRoot!.id,
        'displayName': backupRoot!.displayName,
        if (backupRoot!.displayPath != null)
          'displayPath': backupRoot!.displayPath,
      },
    'saveRoots': saveRoots.map((r) => r.toJson()).toList(),
  };

  /// Tolerant by design: a corrupt or partially unreadable configuration must
  /// degrade to "nothing configured yet" rather than prevent the app starting.
  static AppConfiguration fromJson(Map<String, Object?> json) {
    StorageRoot? backupRoot;
    final rawBackupRoot = json['backupRoot'];
    if (rawBackupRoot is Map<String, Object?>) {
      final id = rawBackupRoot['rootId'];
      if (id is String) {
        backupRoot = StorageRoot(
          id: id,
          displayName: rawBackupRoot['displayName'] as String? ?? 'Backups',
          displayPath: rawBackupRoot['displayPath'] as String?,
        );
      }
    }

    final saveRoots = <GrantedSaveRoot>[];
    final rawSaveRoots = json['saveRoots'];
    if (rawSaveRoots is List) {
      for (final entry in rawSaveRoots) {
        if (entry is! Map<String, Object?>) continue;
        final granted = GrantedSaveRoot.fromJson(entry);
        if (granted != null) saveRoots.add(granted);
      }
    }

    return AppConfiguration(backupRoot: backupRoot, saveRoots: saveRoots);
  }
}

/// Loads and stores [AppConfiguration].
///
/// An interface so the rest of the app never learns whether this is a JSON
/// file, a database, or something else. Today it is a JSON document; the
/// trigger to move to a real database is the first feature that needs to
/// *query* this data rather than load all of it.
abstract interface class ConfigurationRepository {
  Future<AppConfiguration> load();

  Future<void> save(AppConfiguration configuration);
}
