import 'package:checkpoint/domain/storage/safe_path.dart';

/// A directory the user has explicitly granted Checkpoint access to.
///
/// [id] is an **opaque platform token** and the domain never parses it. On
/// Android it is a persisted Storage Access Framework tree URI; on iOS it will
/// be a security-scoped bookmark; on desktop, an absolute path. Keeping it
/// opaque is what lets the same discovery, backup and restore logic run on
/// every platform.
final class StorageRoot {
  const StorageRoot({
    required this.id,
    required this.displayName,
    this.displayPath,
  });

  final String id;

  /// Short label for the UI, e.g. `PSP`.
  final String displayName;

  /// A human-readable rendering of the location, e.g.
  /// `Internal storage/PSP/SAVEDATA`. Best-effort and for display only —
  /// never treat it as a real filesystem path.
  final String? displayPath;

  @override
  bool operator ==(Object other) => other is StorageRoot && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'StorageRoot($displayName, $id)';
}

/// A file or directory inside a [StorageRoot].
final class StorageEntry {
  const StorageEntry({
    required this.path,
    required this.isDirectory,
    required this.sizeBytes,
    this.modifiedAt,
  });

  /// Location relative to the owning root.
  final SafePath path;

  final bool isDirectory;

  /// Size in bytes; always `0` for directories.
  final int sizeBytes;

  final DateTime? modifiedAt;

  String get name => path.name;

  bool get isFile => !isDirectory;

  @override
  String toString() =>
      '${isDirectory ? 'dir' : 'file'}:${path.value} ($sizeBytes B)';
}
