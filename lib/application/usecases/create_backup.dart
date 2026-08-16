import 'dart:typed_data';

import 'package:checkpoint/application/progress.dart';
import 'package:checkpoint/core/failure.dart';
import 'package:checkpoint/core/result.dart';
import 'package:checkpoint/domain/backup/backup_archive_port.dart';
import 'package:checkpoint/domain/backup/backup_file_name.dart';
import 'package:checkpoint/domain/backup/backup_manifest.dart';
import 'package:checkpoint/domain/game/discovered_game.dart';
import 'package:checkpoint/domain/storage/file_system_port.dart';
import 'package:checkpoint/domain/storage/storage_root.dart';
import 'package:crypto/crypto.dart';

/// A backup that was just written.
final class CreatedBackup {
  const CreatedBackup({
    required this.fileName,
    required this.manifest,
    required this.archiveSizeBytes,
  });

  final String fileName;
  final BackupManifest manifest;
  final int archiveSizeBytes;
}

/// Reads a game's saves and writes them to the user's backup folder as one
/// versioned archive.
///
/// Every file is hashed as it is read, and the hashes go into the manifest, so
/// a later restore can prove the archive has not been altered.
final class CreateBackup {
  const CreateBackup({
    required this.fileSystem,
    required this.archive,
    required this.appVersion,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final FileSystemPort fileSystem;
  final BackupArchivePort archive;
  final String appVersion;
  final DateTime Function() _clock;

  Future<Result<CreatedBackup>> call({
    required DiscoveredGame game,
    required StorageRoot backupRoot,
    ProgressCallback? onProgress,
  }) async {
    if (game.saveSets.isEmpty || game.fileCount == 0) {
      return const Err(
        ValidationFailure(message: 'This game has no save files to back up.'),
      );
    }

    final createdAt = _clock().toUtc();
    final totalFiles = game.fileCount;
    var processed = 0;

    final sources = <BackupSource>[];
    final entries = <BackupFileEntry>[];
    final contents = <String, Uint8List>{};

    try {
      if (!await fileSystem.isAccessible(backupRoot)) {
        return const Err(
          PermissionFailure(
            message:
                'Checkpoint cannot write to the backup folder. Choose it '
                'again in Settings.',
          ),
        );
      }

      for (final saveSet in game.saveSets) {
        sources.add(
          BackupSource(
            id: saveSet.sourceId,
            label: saveSet.sourceLabel,
            kind: saveSet.kind,
            layoutId: saveSet.layoutId,
            originDisplayPath:
                saveSet.root.displayPath ?? saveSet.root.displayName,
          ),
        );

        for (final file in saveSet.files) {
          onProgress?.call(
            OperationProgress(
              completed: processed,
              total: totalFiles,
              label: 'Reading ${file.name}',
            ),
          );

          final bytes = await fileSystem.readFile(saveSet.root, file);
          final entry = BackupFileEntry(
            sourceId: saveSet.sourceId,
            path: file,
            sizeBytes: bytes.length,
            sha256: sha256.convert(bytes).toString(),
          );
          entries.add(entry);
          contents[entry.archiveEntryPath] = bytes;
          processed++;
        }
      }

      final fileName = BackupFileName.forGame(
        emulatorId: game.emulatorId,
        gameId: game.gameId,
        createdAt: createdAt,
      );

      final manifest = BackupManifest(
        formatVersion: BackupManifest.currentFormatVersion,
        appVersion: appVersion,
        backupId: fileName.value,
        createdAt: createdAt,
        emulatorId: game.emulatorId,
        emulatorName: game.emulatorName,
        gameId: game.gameId,
        gameTitle: game.title,
        sources: sources,
        files: entries,
      );

      onProgress?.call(
        OperationProgress(
          completed: processed,
          total: totalFiles,
          label: 'Compressing backup',
        ),
      );
      final archiveBytes = archive.pack(manifest: manifest, contents: contents);

      onProgress?.call(
        OperationProgress(
          completed: totalFiles,
          total: totalFiles,
          label: 'Writing backup',
        ),
      );
      await fileSystem.writeFile(
        backupRoot,
        fileName.toSafePath(),
        archiveBytes,
      );

      return Ok(
        CreatedBackup(
          fileName: fileName.value,
          manifest: manifest,
          archiveSizeBytes: archiveBytes.length,
        ),
      );
    } on StorageAccessDeniedException catch (e) {
      return Err(
        PermissionFailure(
          message:
              'Checkpoint lost access to a folder it needs. Select it again '
              'in Settings.',
          detail: e.detail ?? e.message,
        ),
      );
    } on StorageException catch (e) {
      return Err(StorageFailure(message: e.message, detail: e.detail));
    }
  }
}
