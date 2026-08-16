import 'dart:typed_data';

import 'package:checkpoint/core/result.dart';
import 'package:checkpoint/domain/backup/backup_manifest.dart';
import 'package:checkpoint/domain/storage/safe_path.dart';

/// A file recovered from a backup archive, already verified against the
/// manifest and safe to write.
final class ExtractedBackupFile {
  const ExtractedBackupFile({
    required this.sourceId,
    required this.path,
    required this.bytes,
  });

  /// Which save source this belongs to; determines the root it is written to.
  final String sourceId;

  /// Destination relative to that source's root.
  final SafePath path;

  final Uint8List bytes;
}

/// Reads and writes Checkpoint backup archives.
///
/// Kept behind an interface so the container format can change (or gain
/// streaming) without touching use cases, and so tests can drive backup and
/// restore without a real ZIP.
abstract interface class BackupArchivePort {
  /// Builds an archive containing [manifest] and its declared files.
  ///
  /// [contents] is keyed by [BackupFileEntry.archiveEntryPath] and must cover
  /// every file the manifest lists.
  Uint8List pack({
    required BackupManifest manifest,
    required Map<String, Uint8List> contents,
  });

  /// Reads just the manifest, without touching the payload. Used to list
  /// existing backups cheaply.
  Result<BackupManifest> readManifest(Uint8List archiveBytes);

  /// Fully validates [archiveBytes] and returns its files.
  ///
  /// Implementations must extract **only** files the manifest declares, verify
  /// each one's size and checksum, and reject anything unsafe rather than
  /// skipping it silently.
  Result<List<ExtractedBackupFile>> unpack(Uint8List archiveBytes);
}
