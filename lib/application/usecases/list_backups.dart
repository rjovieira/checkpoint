import 'package:checkpoint/core/failure.dart';
import 'package:checkpoint/core/result.dart';
import 'package:checkpoint/domain/backup/backup_file_name.dart';
import 'package:checkpoint/domain/storage/file_system_port.dart';
import 'package:checkpoint/domain/storage/safe_path.dart';
import 'package:checkpoint/domain/storage/storage_root.dart';

/// A backup as it appears in a list, built from the directory listing alone.
///
/// Deliberately does not carry a manifest: reading one means decompressing the
/// archive, and doing that for every backup just to draw a list would be slow
/// and wasteful. The manifest is read when the user opens or restores a
/// specific backup.
final class BackupSummary {
  const BackupSummary({
    required this.fileName,
    required this.path,
    required this.sizeBytes,
    required this.createdAt,
    required this.emulatorId,
    required this.gameSlug,
  });

  final String fileName;

  /// Location within the backup root.
  final SafePath path;

  final int sizeBytes;
  final DateTime createdAt;
  final String emulatorId;
  final String gameSlug;

  bool matchesGame({required String emulatorId, required String gameId}) =>
      this.emulatorId == BackupFileName.slug(emulatorId) &&
      gameSlug == BackupFileName.slug(gameId);
}

/// Lists Checkpoint backups in the user's backup folder, newest first.
///
/// Files that are not Checkpoint backups are ignored rather than reported: the
/// backup folder is the user's own, and they are free to keep other things in
/// it.
final class ListBackups {
  const ListBackups({required this.fileSystem});

  final FileSystemPort fileSystem;

  Future<Result<List<BackupSummary>>> call({
    required StorageRoot backupRoot,
    String? emulatorId,
    String? gameId,
  }) async {
    try {
      final entries = await fileSystem.listDirectory(backupRoot, null);
      final summaries = <BackupSummary>[];

      for (final entry in entries) {
        if (entry.isDirectory) continue;
        final parsed = BackupFileName.tryParse(entry.name);
        if (parsed == null) continue;

        final summary = BackupSummary(
          fileName: entry.name,
          path: entry.path,
          sizeBytes: entry.sizeBytes,
          createdAt: parsed.createdAt,
          emulatorId: parsed.emulatorId,
          gameSlug: parsed.gameSlug,
        );

        if (emulatorId != null &&
            gameId != null &&
            !summary.matchesGame(emulatorId: emulatorId, gameId: gameId)) {
          continue;
        }
        summaries.add(summary);
      }

      summaries.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      return Ok(summaries);
    } on StorageAccessDeniedException catch (e) {
      return Err(
        PermissionFailure(
          message:
              'Checkpoint cannot read the backup folder. Choose it again in '
              'Settings.',
          detail: e.detail ?? e.message,
        ),
      );
    } on StorageException catch (e) {
      return Err(StorageFailure(message: e.message, detail: e.detail));
    }
  }
}
