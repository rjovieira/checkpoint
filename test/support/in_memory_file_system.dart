import 'dart:typed_data';

import 'package:checkpoint/domain/storage/file_system_port.dart';
import 'package:checkpoint/domain/storage/safe_path.dart';
import 'package:checkpoint/domain/storage/storage_root.dart';

/// An in-memory [FileSystemPort] for tests.
///
/// Its existence is the point of the port: discovery, backup and restore can be
/// exercised end to end with no Android, no SAF and no real files, which is
/// what makes the domain logic testable at all.
final class InMemoryFileSystem implements FileSystemPort {
  InMemoryFileSystem();

  /// rootId → (path → bytes)
  final Map<String, Map<String, Uint8List>> _files = {};
  final Map<String, Set<String>> _directories = {};
  final Map<String, DateTime> _modified = {};
  final Set<String> _inaccessibleRoots = {};

  /// Roots whose writes should fail, to exercise error handling.
  final Set<String> readOnlyRoots = {};

  /// Every write this filesystem has seen, in order. Lets a test assert
  /// *exactly* what a restore touched.
  final List<String> writeLog = [];

  void seedFile(
    StorageRoot root,
    String path,
    List<int> bytes, {
    DateTime? modifiedAt,
  }) {
    final safe = SafePath.parse(path).valueOrNull;
    if (safe == null) throw ArgumentError.value(path, 'path', 'is not safe');
    _files.putIfAbsent(root.id, () => {})[safe.value] = Uint8List.fromList(
      bytes,
    );
    if (modifiedAt != null) {
      _modified['${root.id}|${safe.value}'] = modifiedAt;
    }
    var parent = safe.parent;
    while (parent != null) {
      _directories.putIfAbsent(root.id, () => {}).add(parent.value);
      parent = parent.parent;
    }
  }

  void seedDirectory(StorageRoot root, String path) {
    final safe = SafePath.parse(path).valueOrNull;
    if (safe == null) throw ArgumentError.value(path, 'path', 'is not safe');
    _directories.putIfAbsent(root.id, () => {}).add(safe.value);
  }

  void makeInaccessible(StorageRoot root) => _inaccessibleRoots.add(root.id);

  Uint8List? fileAt(StorageRoot root, String path) => _files[root.id]?[path];

  Iterable<String> pathsIn(StorageRoot root) =>
      _files[root.id]?.keys ?? const [];

  void _guard(StorageRoot root) {
    if (_inaccessibleRoots.contains(root.id)) {
      throw StorageAccessDeniedException('No access to ${root.displayName}');
    }
  }

  @override
  Future<List<StorageEntry>> listDirectory(
    StorageRoot root,
    SafePath? directory,
  ) async {
    _guard(root);
    final prefix = directory == null ? '' : '${directory.value}/';
    final depth = directory == null ? 0 : directory.segments.length;
    final entries = <String, StorageEntry>{};

    for (final path in _files[root.id]?.keys ?? const <String>[]) {
      if (!path.startsWith(prefix)) continue;
      final segments = path.split('/');
      if (segments.length <= depth) continue;
      final childPath = segments.take(depth + 1).join('/');
      final isDirectory = segments.length > depth + 1;
      entries[childPath] = StorageEntry(
        path: SafePath.parse(childPath).valueOrNull!,
        isDirectory: isDirectory,
        sizeBytes: isDirectory ? 0 : _files[root.id]![path]!.length,
        modifiedAt: _modified['${root.id}|$path'],
      );
    }

    for (final path in _directories[root.id] ?? const <String>{}) {
      if (!path.startsWith(prefix)) continue;
      final segments = path.split('/');
      if (segments.length != depth + 1) continue;
      entries.putIfAbsent(
        path,
        () => StorageEntry(
          path: SafePath.parse(path).valueOrNull!,
          isDirectory: true,
          sizeBytes: 0,
        ),
      );
    }

    return entries.values.toList();
  }

  @override
  Future<List<StorageEntry>> listFilesRecursively(
    StorageRoot root,
    SafePath? directory,
  ) async {
    _guard(root);
    final prefix = directory == null ? '' : '${directory.value}/';
    final result = <StorageEntry>[];
    for (final entry
        in (_files[root.id] ?? const <String, Uint8List>{}).entries) {
      if (!entry.key.startsWith(prefix)) continue;
      result.add(
        StorageEntry(
          path: SafePath.parse(entry.key).valueOrNull!,
          isDirectory: false,
          sizeBytes: entry.value.length,
          modifiedAt: _modified['${root.id}|${entry.key}'],
        ),
      );
    }
    result.sort((a, b) => a.path.value.compareTo(b.path.value));
    return result;
  }

  @override
  Future<Uint8List> readFile(StorageRoot root, SafePath file) async {
    _guard(root);
    final bytes = _files[root.id]?[file.value];
    if (bytes == null) {
      throw StorageException('No such file', file.value);
    }
    return bytes;
  }

  @override
  Future<void> writeFile(
    StorageRoot root,
    SafePath file,
    Uint8List bytes,
  ) async {
    _guard(root);
    if (readOnlyRoots.contains(root.id)) {
      throw StorageException('Read-only root', file.value);
    }
    writeLog.add('${root.id}|${file.value}');
    seedFile(root, file.value, bytes);
  }

  @override
  Future<void> createDirectory(StorageRoot root, SafePath directory) async {
    _guard(root);
    seedDirectory(root, directory.value);
  }

  @override
  Future<bool> exists(StorageRoot root, SafePath path) async {
    _guard(root);
    return (_files[root.id]?.containsKey(path.value) ?? false) ||
        (_directories[root.id]?.contains(path.value) ?? false);
  }

  @override
  Future<void> delete(StorageRoot root, SafePath path) async {
    _guard(root);
    _files[root.id]?.remove(path.value);
    _directories[root.id]?.remove(path.value);
  }

  @override
  Future<bool> isAccessible(StorageRoot root) async =>
      !_inaccessibleRoots.contains(root.id);

  @override
  Future<StorageEntry?> stat(StorageRoot root, SafePath path) async {
    _guard(root);
    final bytes = _files[root.id]?[path.value];
    if (bytes != null) {
      return StorageEntry(
        path: path,
        isDirectory: false,
        sizeBytes: bytes.length,
        modifiedAt: _modified['${root.id}|${path.value}'],
      );
    }
    if (_directories[root.id]?.contains(path.value) ?? false) {
      return StorageEntry(path: path, isDirectory: true, sizeBytes: 0);
    }
    return null;
  }
}
