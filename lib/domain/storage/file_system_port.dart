import 'dart:typed_data';

import 'package:checkpoint/domain/storage/safe_path.dart';
import 'package:checkpoint/domain/storage/storage_root.dart';

/// Read/write access to storage the user has granted, addressed as
/// (root, relative path) pairs.
///
/// Every path parameter is a [SafePath], so an implementation can join it to
/// its root without any further validation: the type already guarantees the
/// result stays inside the root.
///
/// Implementations throw [StorageException] for I/O problems and
/// [StorageAccessDeniedException] when the grant is missing or revoked.
abstract interface class FileSystemPort {
  /// Direct children of [directory] within [root]. Does not recurse.
  ///
  /// Passing `null` for [directory] lists the root itself.
  Future<List<StorageEntry>> listDirectory(
    StorageRoot root,
    SafePath? directory,
  );

  /// Recursively collects every *file* at or below [directory].
  Future<List<StorageEntry>> listFilesRecursively(
    StorageRoot root,
    SafePath? directory,
  );

  Future<Uint8List> readFile(StorageRoot root, SafePath file);

  /// Writes [bytes] to [file], creating parent directories as needed and
  /// replacing any existing file.
  Future<void> writeFile(StorageRoot root, SafePath file, Uint8List bytes);

  Future<void> createDirectory(StorageRoot root, SafePath directory);

  Future<bool> exists(StorageRoot root, SafePath path);

  Future<void> delete(StorageRoot root, SafePath path);

  /// Whether the grant behind [root] is still usable. Users can revoke access
  /// at any time from system settings, so this is checked before long
  /// operations rather than assumed.
  Future<bool> isAccessible(StorageRoot root);

  /// Metadata for a single entry, or `null` if it does not exist.
  Future<StorageEntry?> stat(StorageRoot root, SafePath path);
}

/// An I/O operation failed.
class StorageException implements Exception {
  const StorageException(this.message, [this.detail]);

  final String message;
  final String? detail;

  @override
  String toString() =>
      'StorageException: $message${detail == null ? '' : ' ($detail)'}';
}

/// The platform refused the operation because access was never granted or has
/// been revoked. Distinguished from [StorageException] because the remedy is
/// different: the user must re-pick the folder.
class StorageAccessDeniedException extends StorageException {
  const StorageAccessDeniedException(super.message, [super.detail]);

  @override
  String toString() =>
      'StorageAccessDeniedException: $message'
      '${detail == null ? '' : ' ($detail)'}';
}
