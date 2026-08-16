import 'dart:typed_data';

import 'package:checkpoint/domain/storage/file_system_port.dart';
import 'package:checkpoint/domain/storage/safe_path.dart';
import 'package:checkpoint/domain/storage/storage_root.dart';
import 'package:checkpoint/infrastructure/android/checkpoint_channel.dart';

/// [FileSystemPort] backed by the Android Storage Access Framework.
///
/// Paths cross the channel as plain strings, but only ever as the canonical
/// form of an already-validated [SafePath] — the Kotlin side re-resolves them
/// component by component inside the granted tree, so neither side relies on
/// the other for containment.
final class SafFileSystem implements FileSystemPort {
  const SafFileSystem([this._channel = const CheckpointChannel()]);

  final CheckpointChannel _channel;

  @override
  Future<List<StorageEntry>> listDirectory(
    StorageRoot root,
    SafePath? directory,
  ) async {
    final raw = await _channel.invokeList<Object?>('listDirectory', {
      'rootId': root.id,
      'path': directory?.value,
    });
    return _toEntries(raw);
  }

  @override
  Future<List<StorageEntry>> listFilesRecursively(
    StorageRoot root,
    SafePath? directory,
  ) async {
    final raw = await _channel.invokeList<Object?>('listFilesRecursively', {
      'rootId': root.id,
      'path': directory?.value,
    });
    return _toEntries(raw);
  }

  @override
  Future<Uint8List> readFile(StorageRoot root, SafePath file) async {
    final bytes = await _channel.invoke<Uint8List>('readFile', {
      'rootId': root.id,
      'path': file.value,
    });
    if (bytes == null) {
      throw StorageException('Could not read file', file.value);
    }
    return bytes;
  }

  @override
  Future<void> writeFile(
    StorageRoot root,
    SafePath file,
    Uint8List bytes,
  ) async {
    await _channel.invoke<void>('writeFile', {
      'rootId': root.id,
      'path': file.value,
      'bytes': bytes,
    });
  }

  @override
  Future<void> createDirectory(StorageRoot root, SafePath directory) async {
    await _channel.invoke<void>('createDirectory', {
      'rootId': root.id,
      'path': directory.value,
    });
  }

  @override
  Future<bool> exists(StorageRoot root, SafePath path) async =>
      await _channel.invoke<bool>('exists', {
        'rootId': root.id,
        'path': path.value,
      }) ??
      false;

  @override
  Future<void> delete(StorageRoot root, SafePath path) async {
    await _channel.invoke<void>('delete', {
      'rootId': root.id,
      'path': path.value,
    });
  }

  @override
  Future<bool> isAccessible(StorageRoot root) async {
    try {
      return await _channel.invoke<bool>('isAccessible', {'rootId': root.id}) ??
          false;
    } on StorageException {
      return false;
    }
  }

  @override
  Future<StorageEntry?> stat(StorageRoot root, SafePath path) async {
    final raw = await _channel.invoke<Map<Object?, Object?>>('stat', {
      'rootId': root.id,
      'path': path.value,
    });
    return raw == null ? null : _toEntry(raw);
  }

  List<StorageEntry> _toEntries(List<Object?> raw) {
    final entries = <StorageEntry>[];
    for (final item in raw) {
      if (item is! Map<Object?, Object?>) continue;
      final entry = _toEntry(item);
      if (entry != null) entries.add(entry);
    }
    return entries;
  }

  /// Converts one channel map into an entry.
  ///
  /// Returns `null` for entries whose name the platform reports in a form
  /// Checkpoint will not touch — a file literally called `..`, say. Skipping
  /// those is correct: they cannot be addressed safely, so they are not backed
  /// up rather than being handled with a special case.
  StorageEntry? _toEntry(Map<Object?, Object?> raw) {
    final path = raw['path'];
    if (path is! String) return null;

    final parsed = SafePath.parse(path);
    final safePath = parsed.valueOrNull;
    if (safePath == null) return null;

    final modified = raw['modified'];
    return StorageEntry(
      path: safePath,
      isDirectory: raw['isDirectory'] == true,
      sizeBytes: switch (raw['size']) {
        final int size => size,
        _ => 0,
      },
      modifiedAt: modified is int && modified > 0
          ? DateTime.fromMillisecondsSinceEpoch(modified)
          : null,
    );
  }
}
