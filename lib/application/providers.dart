import 'package:checkpoint/application/usecases/create_backup.dart';
import 'package:checkpoint/application/usecases/detect_emulators.dart';
import 'package:checkpoint/application/usecases/discover_games.dart';
import 'package:checkpoint/application/usecases/list_backups.dart';
import 'package:checkpoint/application/usecases/restore_backup.dart';
import 'package:checkpoint/core/app_info.dart';
import 'package:checkpoint/domain/backup/backup_archive_port.dart';
import 'package:checkpoint/domain/config/app_configuration.dart';
import 'package:checkpoint/domain/emulator/emulator_registry.dart';
import 'package:checkpoint/domain/platform/installed_app_port.dart';
import 'package:checkpoint/domain/storage/directory_picker_port.dart';
import 'package:checkpoint/domain/storage/file_system_port.dart';
import 'package:checkpoint/domain/storage/storage_root.dart';
import 'package:checkpoint/infrastructure/android/android_installed_apps.dart';
import 'package:checkpoint/infrastructure/android/saf_directory_picker.dart';
import 'package:checkpoint/infrastructure/android/saf_file_system.dart';
import 'package:checkpoint/infrastructure/archive/zip_backup_archive.dart';
import 'package:checkpoint/infrastructure/persistence/json_configuration_repository.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Composition root.
///
/// Every provider here is overridable, which is the whole reason the app is
/// wired this way: a test replaces [fileSystemProvider] with an in-memory fake
/// and the entire stack above it runs unchanged, with no Android in sight.

// ── platform adapters ───────────────────────────────────────────────────

final fileSystemProvider = Provider<FileSystemPort>(
  (ref) => const SafFileSystem(),
);

final directoryPickerProvider = Provider<DirectoryPickerPort>(
  (ref) => const SafDirectoryPicker(),
);

final installedAppsProvider = Provider<InstalledAppPort>(
  (ref) => const AndroidInstalledApps(),
);

final backupArchiveProvider = Provider<BackupArchivePort>(
  (ref) => const ZipBackupArchive(),
);

final configurationRepositoryProvider = Provider<ConfigurationRepository>(
  (ref) => JsonConfigurationRepository(),
);

final emulatorRegistryProvider = Provider<EmulatorRegistry>(
  (ref) => EmulatorRegistry.defaults(),
);

// ── use cases ───────────────────────────────────────────────────────────

final detectEmulatorsProvider = Provider<DetectEmulators>(
  (ref) => DetectEmulators(
    registry: ref.watch(emulatorRegistryProvider),
    installedApps: ref.watch(installedAppsProvider),
  ),
);

final discoverGamesProvider = Provider<DiscoverGames>(
  (ref) => DiscoverGames(
    registry: ref.watch(emulatorRegistryProvider),
    fileSystem: ref.watch(fileSystemProvider),
  ),
);

final createBackupProvider = Provider<CreateBackup>(
  (ref) => CreateBackup(
    fileSystem: ref.watch(fileSystemProvider),
    archive: ref.watch(backupArchiveProvider),
    appVersion: checkpointVersion,
  ),
);

final listBackupsProvider = Provider<ListBackups>(
  (ref) => ListBackups(fileSystem: ref.watch(fileSystemProvider)),
);

final restoreBackupProvider = Provider<RestoreBackup>(
  (ref) => RestoreBackup(
    fileSystem: ref.watch(fileSystemProvider),
    archive: ref.watch(backupArchiveProvider),
  ),
);

// ── state ───────────────────────────────────────────────────────────────

/// The user's folder choices. Everything downstream depends on this, so
/// granting a folder automatically refreshes discovery and backup lists.
final configurationProvider =
    AsyncNotifierProvider<ConfigurationNotifier, AppConfiguration>(
      ConfigurationNotifier.new,
    );

final class ConfigurationNotifier extends AsyncNotifier<AppConfiguration> {
  @override
  Future<AppConfiguration> build() =>
      ref.read(configurationRepositoryProvider).load();

  Future<void> setBackupRoot(StorageRoot? root) =>
      _update((current) => current.withBackupRoot(root));

  Future<void> setSaveRoot(GrantedSaveRoot granted) =>
      _update((current) => current.withSaveRoot(granted));

  Future<void> removeSaveRoot(String emulatorId, String sourceId) =>
      _update((current) => current.withoutSaveRoot(emulatorId, sourceId));

  Future<void> _update(
    AppConfiguration Function(AppConfiguration current) change,
  ) async {
    final current = state.value ?? AppConfiguration.empty;
    final updated = change(current);
    await ref.read(configurationRepositoryProvider).save(updated);
    state = AsyncData(updated);
  }
}

/// Supported emulators, whether they were detected, and which folders are set.
final emulatorStatusesProvider = FutureProvider<List<EmulatorStatus>>((
  ref,
) async {
  final configuration = await ref.watch(configurationProvider.future);
  return ref.read(detectEmulatorsProvider)(configuration);
});

/// Games found by scanning every granted save folder.
final gamesProvider = FutureProvider<GameDiscoveryResult>((ref) async {
  final configuration = await ref.watch(configurationProvider.future);
  return ref.read(discoverGamesProvider)(configuration);
});

/// Identifies one game for the backup list. A record rather than a class so
/// family equality is structural and free.
typedef GameKey = ({String emulatorId, String gameId});

/// Backups in the user's backup folder, optionally narrowed to one game.
final backupsProvider = FutureProvider.family<List<BackupSummary>, GameKey?>((
  ref,
  key,
) async {
  final configuration = await ref.watch(configurationProvider.future);
  final backupRoot = configuration.backupRoot;
  if (backupRoot == null) return const [];

  final result = await ref
      .read(listBackupsProvider)
      .call(
        backupRoot: backupRoot,
        emulatorId: key?.emulatorId,
        gameId: key?.gameId,
      );
  return result.fold((backups) => backups, (failure) => throw failure);
});
