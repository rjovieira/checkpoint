import 'package:checkpoint/application/progress.dart';
import 'package:checkpoint/core/failure.dart';
import 'package:checkpoint/core/result.dart';
import 'package:checkpoint/domain/backup/backup_archive_port.dart';
import 'package:checkpoint/domain/backup/backup_manifest.dart';
import 'package:checkpoint/domain/config/app_configuration.dart';
import 'package:checkpoint/domain/emulator/save_kind.dart';
import 'package:checkpoint/domain/storage/file_system_port.dart';
import 'package:checkpoint/domain/storage/safe_path.dart';
import 'package:checkpoint/domain/storage/storage_root.dart';

/// Where one source's files will be written.
final class RestoreTarget {
  const RestoreTarget({
    required this.source,
    required this.root,
    required this.fileCount,
  });

  final BackupSource source;
  final StorageRoot root;
  final int fileCount;
}

/// A source in the backup that has nowhere to go.
final class UnresolvedRestoreTarget {
  const UnresolvedRestoreTarget({
    required this.source,
    required this.fileCount,
  });

  final BackupSource source;
  final int fileCount;
}

/// Exactly what a restore would do, computed before anything is written.
///
/// The UI shows this to the user and only then asks them to confirm. Restoring
/// overwrites real progress, so "press the button and find out" is not an
/// acceptable interaction.
final class RestorePlan {
  const RestorePlan({
    required this.archivePath,
    required this.manifest,
    required this.targets,
    required this.unresolved,
  });

  final SafePath archivePath;
  final BackupManifest manifest;
  final List<RestoreTarget> targets;
  final List<UnresolvedRestoreTarget> unresolved;

  /// A restore is refused outright if any part of the backup has no home. A
  /// half-restored save is worse than none: the emulator may load a mix of old
  /// and new state.
  bool get canApply => unresolved.isEmpty && targets.isNotEmpty;

  int get fileCount => manifest.fileCount;

  bool get touchesSaveData =>
      targets.any((t) => t.source.kind == SaveKind.saveData);

  bool get touchesSaveStates =>
      targets.any((t) => t.source.kind == SaveKind.saveState);
}

final class RestoreSummary {
  const RestoreSummary({required this.filesRestored, required this.gameTitle});

  final int filesRestored;
  final String gameTitle;
}

/// Reads a backup and writes its files back into the folders they came from.
///
/// Behaviour is intentionally additive: files in the backup replace the
/// matching files in the save folder, and anything else in that folder is left
/// alone. Wiping the destination first would be tidier but risks destroying
/// saves for other games that share a flat folder, which is exactly how
/// RetroArch and mGBA store things.
final class RestoreBackup {
  const RestoreBackup({required this.fileSystem, required this.archive});

  final FileSystemPort fileSystem;
  final BackupArchivePort archive;

  /// Reads the backup's manifest and works out where its contents would go.
  Future<Result<RestorePlan>> inspect({
    required StorageRoot backupRoot,
    required SafePath archivePath,
    required AppConfiguration configuration,
  }) async {
    try {
      final bytes = await fileSystem.readFile(backupRoot, archivePath);
      final manifestResult = archive.readManifest(bytes);
      if (manifestResult case Err<BackupManifest>(:final failure)) {
        return Err(failure);
      }
      final manifest = (manifestResult as Ok<BackupManifest>).value;

      final fileCounts = <String, int>{};
      for (final file in manifest.files) {
        fileCounts[file.sourceId] = (fileCounts[file.sourceId] ?? 0) + 1;
      }

      final targets = <RestoreTarget>[];
      final unresolved = <UnresolvedRestoreTarget>[];

      for (final source in manifest.sources) {
        final count = fileCounts[source.id] ?? 0;
        if (count == 0) continue;
        final root = configuration.saveRootFor(manifest.emulatorId, source.id);
        if (root == null) {
          unresolved.add(
            UnresolvedRestoreTarget(source: source, fileCount: count),
          );
        } else {
          targets.add(
            RestoreTarget(source: source, root: root, fileCount: count),
          );
        }
      }

      return Ok(
        RestorePlan(
          archivePath: archivePath,
          manifest: manifest,
          targets: targets,
          unresolved: unresolved,
        ),
      );
    } on StorageAccessDeniedException catch (e) {
      return Err(
        PermissionFailure(
          message: 'Checkpoint cannot read this backup any more.',
          detail: e.detail ?? e.message,
        ),
      );
    } on StorageException catch (e) {
      return Err(StorageFailure(message: e.message, detail: e.detail));
    }
  }

  /// Performs a restore the user has confirmed.
  Future<Result<RestoreSummary>> apply({
    required StorageRoot backupRoot,
    required RestorePlan plan,
    ProgressCallback? onProgress,
  }) async {
    if (!plan.canApply) {
      return const Err(
        ValidationFailure(
          message:
              'This backup cannot be restored until every folder it needs has '
              'been selected in Settings.',
        ),
      );
    }

    final rootsBySourceId = {
      for (final target in plan.targets) target.source.id: target.root,
    };

    try {
      onProgress?.call(
        OperationProgress(
          completed: 0,
          total: plan.fileCount,
          label: 'Reading backup',
        ),
      );
      final bytes = await fileSystem.readFile(backupRoot, plan.archivePath);

      // Everything is validated and verified here, before a single byte is
      // written. A backup that fails any check leaves the save folder
      // untouched.
      final unpacked = archive.unpack(bytes);
      if (unpacked case Err<List<ExtractedBackupFile>>(:final failure)) {
        return Err(failure);
      }
      final files = (unpacked as Ok<List<ExtractedBackupFile>>).value;

      for (final root in rootsBySourceId.values.toSet()) {
        if (!await fileSystem.isAccessible(root)) {
          return Err(
            PermissionFailure(
              message:
                  'Checkpoint lost access to ${root.displayName}. Select the '
                  'folder again in Settings, then try the restore again.',
            ),
          );
        }
      }

      // Resolve every destination before writing anything. The plan was built
      // from an earlier read of the archive, so if the file changed in between
      // this is where it is caught — and catching it here rather than inside
      // the write loop is what keeps a mismatch from leaving a half-restored
      // save behind.
      for (final file in files) {
        if (!rootsBySourceId.containsKey(file.sourceId)) {
          return Err(
            ValidationFailure(
              message: 'This backup does not match the folders selected.',
              detail: file.sourceId,
            ),
          );
        }
      }

      var written = 0;
      for (final file in files) {
        final root = rootsBySourceId[file.sourceId]!;

        onProgress?.call(
          OperationProgress(
            completed: written,
            total: files.length,
            label: 'Restoring ${file.path.name}',
          ),
        );

        await fileSystem.writeFile(root, file.path, file.bytes);
        written++;
      }

      onProgress?.call(
        OperationProgress(
          completed: written,
          total: files.length,
          label: 'Finished',
        ),
      );

      return Ok(
        RestoreSummary(
          filesRestored: written,
          gameTitle: plan.manifest.gameTitle,
        ),
      );
    } on StorageAccessDeniedException catch (e) {
      return Err(
        PermissionFailure(
          message:
              'Checkpoint lost access to a folder part-way through the '
              'restore. Some files may not have been written.',
          detail: e.detail ?? e.message,
        ),
      );
    } on StorageException catch (e) {
      return Err(StorageFailure(message: e.message, detail: e.detail));
    }
  }
}
