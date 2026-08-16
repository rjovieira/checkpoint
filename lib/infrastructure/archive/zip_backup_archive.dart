import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:checkpoint/core/failure.dart';
import 'package:checkpoint/core/result.dart';
import 'package:checkpoint/domain/backup/archive_limits.dart';
import 'package:checkpoint/domain/backup/backup_archive_port.dart';
import 'package:checkpoint/domain/backup/backup_manifest.dart';
import 'package:checkpoint/domain/storage/safe_path.dart';
import 'package:crypto/crypto.dart';

/// ZIP-backed implementation of [BackupArchivePort].
///
/// Extraction is written by hand rather than using the `archive` package's
/// `extractArchiveToDisk`, which trusts entry names. The rules here are:
///
/// 1. **The manifest is the allowlist.** Only files the manifest declares are
///    ever read out of the archive. An entry that is not in the manifest is
///    never decompressed and never written, so an attacker cannot smuggle an
///    extra file in by adding an entry.
/// 2. **Every path goes through [SafePath].** Absolute paths, `..`, backslashes
///    and control characters are rejected by construction, so no extracted path
///    can leave its destination root.
/// 3. **Symbolic links are refused outright.** A symlink entry is the standard
///    way to turn a contained extraction into an arbitrary write, and no
///    legitimate save backup needs one.
/// 4. **Sizes are bounded before decompression** using each entry's declared
///    size, then re-checked against reality afterwards.
/// 5. **Contents are verified** against the SHA-256 in the manifest, so a
///    tampered payload fails before it reaches the user's save folder.
final class ZipBackupArchive implements BackupArchivePort {
  const ZipBackupArchive({this.limits = ArchiveLimits.standard});

  final ArchiveLimits limits;

  static const int _compressionLevel = 6;

  @override
  Uint8List pack({
    required BackupManifest manifest,
    required Map<String, Uint8List> contents,
  }) {
    final archive = Archive()
      ..add(ArchiveFile.bytes(BackupManifest.fileName, manifest.encode()));

    for (final file in manifest.files) {
      final bytes = contents[file.archiveEntryPath];
      if (bytes == null) {
        // A manifest that promises a file we do not have is a bug in the
        // caller, not bad input — fail loudly rather than write a broken
        // archive that only fails at restore time.
        throw StateError(
          'Manifest declares ${file.archiveEntryPath} but no content was '
          'supplied for it',
        );
      }
      archive.add(ArchiveFile.bytes(file.archiveEntryPath, bytes));
    }

    return ZipEncoder().encodeBytes(archive, level: _compressionLevel);
  }

  @override
  Result<BackupManifest> readManifest(Uint8List archiveBytes) {
    final archive = _decode(archiveBytes);
    return switch (archive) {
      Err<Archive>(:final failure) => Err(failure),
      Ok<Archive>(:final value) => _extractManifest(value),
    };
  }

  @override
  Result<List<ExtractedBackupFile>> unpack(Uint8List archiveBytes) {
    final decoded = _decode(archiveBytes);
    if (decoded case Err<Archive>(:final failure)) {
      return Err(failure);
    }
    final archive = (decoded as Ok<Archive>).value;

    final manifestResult = _extractManifest(archive);
    if (manifestResult case Err<BackupManifest>(:final failure)) {
      return Err(failure);
    }
    final manifest = (manifestResult as Ok<BackupManifest>).value;

    // Index the archive by entry name so the manifest drives extraction.
    // Symlinks are rejected here rather than skipped: their presence means the
    // archive is not something Checkpoint produced, and continuing would be
    // extracting a partially hostile file.
    final entriesByName = <String, ArchiveFile>{};
    for (final entry in archive.files) {
      if (entry.isSymbolicLink) {
        return Err(
          ArchiveFailure(
            message: 'This backup contains a symbolic link and was refused.',
            detail: entry.name,
          ),
        );
      }
      if (!entry.isFile) continue;
      entriesByName[entry.name] = entry;
    }

    final payloadPrefix = SafePath.parse(BackupManifest.payloadPrefix);
    final prefix = (payloadPrefix as Ok<SafePath>).value;

    var runningTotal = 0;
    final extracted = <ExtractedBackupFile>[];

    for (final declared in manifest.files) {
      final entryName = declared.archiveEntryPath;

      // Belt and braces: the manifest's own paths were validated on decode,
      // but the joined archive path is what an implementation bug would
      // corrupt, so validate the final string too.
      final entryPath = SafePath.parse(entryName);
      if (entryPath case Err<SafePath>(:final failure)) {
        return Err(
          ArchiveFailure(
            message: 'This backup contains an unsafe entry path.',
            detail: failure.detail,
          ),
        );
      }
      if (!(entryPath as Ok<SafePath>).value.isUnder(prefix)) {
        return Err(
          ArchiveFailure(
            message: 'This backup stores a file outside its payload folder.',
            detail: entryName,
          ),
        );
      }

      final entry = entriesByName[entryName];
      if (entry == null) {
        return Err(
          ArchiveFailure(
            message: 'This backup is incomplete — a file it lists is missing.',
            detail: entryName,
          ),
        );
      }

      if (entry.size > limits.maxFileBytes) {
        return Err(
          ArchiveFailure(
            message: 'This backup contains a file that is too large to restore.',
            detail: '$entryName declares ${entry.size} bytes',
          ),
        );
      }
      if (entry.size != declared.sizeBytes) {
        return Err(
          ArchiveFailure(
            message: 'This backup has been modified since it was created.',
            detail:
                '$entryName is ${entry.size} bytes, manifest says '
                '${declared.sizeBytes}',
          ),
        );
      }
      runningTotal += entry.size;
      if (runningTotal > limits.maxTotalBytes) {
        return Err(
          ArchiveFailure(
            message: 'This backup is too large to restore.',
            detail: 'exceeds ${limits.maxTotalBytes} bytes uncompressed',
          ),
        );
      }

      final bytes = entry.readBytes();
      if (bytes == null) {
        return Err(
          ArchiveFailure(
            message: 'A file in this backup could not be read.',
            detail: entryName,
          ),
        );
      }
      if (bytes.length != declared.sizeBytes) {
        return Err(
          ArchiveFailure(
            message: 'This backup has been modified since it was created.',
            detail: '$entryName expanded to ${bytes.length} bytes',
          ),
        );
      }

      final digest = sha256.convert(bytes).toString();
      if (digest != declared.sha256) {
        return Err(
          ArchiveFailure(
            message:
                'A file in this backup failed its integrity check and was '
                'not restored.',
            detail: entryName,
          ),
        );
      }

      extracted.add(
        ExtractedBackupFile(
          sourceId: declared.sourceId,
          path: declared.path,
          bytes: bytes,
        ),
      );
    }

    return Ok(extracted);
  }

  Result<Archive> _decode(Uint8List archiveBytes) {
    if (archiveBytes.length > limits.maxArchiveBytes) {
      return Err(
        ArchiveFailure(
          message: 'This backup file is too large to open.',
          detail: '${archiveBytes.length} bytes',
        ),
      );
    }
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(archiveBytes);
    } on Object catch (e) {
      return Err(
        ArchiveFailure(
          message: 'This file is not a readable backup archive.',
          detail: e.toString(),
        ),
      );
    }
    if (archive.files.length > limits.maxEntries) {
      return Err(
        ArchiveFailure(
          message: 'This backup contains too many files to restore.',
          detail: '${archive.files.length} entries',
        ),
      );
    }
    return Ok(archive);
  }

  Result<BackupManifest> _extractManifest(Archive archive) {
    ArchiveFile? manifestEntry;
    for (final entry in archive.files) {
      if (entry.name == BackupManifest.fileName && entry.isFile) {
        manifestEntry = entry;
        break;
      }
    }
    if (manifestEntry == null) {
      return const Err(
        ArchiveFailure(
          message:
              'This file is not a Checkpoint backup — it has no manifest.',
        ),
      );
    }
    if (manifestEntry.size > _maxManifestBytes) {
      return const Err(
        ArchiveFailure(message: 'This backup\'s metadata is implausibly large.'),
      );
    }
    final bytes = manifestEntry.readBytes();
    if (bytes == null) {
      return const Err(
        ArchiveFailure(message: 'This backup\'s metadata could not be read.'),
      );
    }
    return BackupManifest.decode(bytes);
  }

  static const int _maxManifestBytes = 8 * 1024 * 1024;
}
