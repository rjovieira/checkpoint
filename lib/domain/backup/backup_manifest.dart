import 'dart:convert';

import 'package:checkpoint/core/failure.dart';
import 'package:checkpoint/core/result.dart';
import 'package:checkpoint/domain/emulator/save_kind.dart';
import 'package:checkpoint/domain/storage/safe_path.dart';

/// Where an archived file originally came from.
final class BackupSource {
  const BackupSource({
    required this.id,
    required this.label,
    required this.kind,
    required this.layoutId,
    this.originDisplayPath,
  });

  /// The [SaveSource.id] this content belongs to. Restore uses it to find the
  /// folder the files must go back into.
  final String id;

  final String label;
  final SaveKind kind;

  /// Which [SaveLayout] produced this content, so a future version can tell how
  /// the files were grouped even if the layout has since changed.
  final String layoutId;

  /// Human-readable origin, shown to the user before a restore. Display only —
  /// it is never resolved as a path.
  final String? originDisplayPath;

  Map<String, Object?> toJson() => {
    'id': id,
    'label': label,
    'kind': kind.name,
    'layoutId': layoutId,
    if (originDisplayPath != null) 'originDisplayPath': originDisplayPath,
  };
}

/// One file inside a backup archive.
final class BackupFileEntry {
  const BackupFileEntry({
    required this.sourceId,
    required this.path,
    required this.sizeBytes,
    required this.sha256,
  });

  final String sourceId;

  /// Location relative to the source root — i.e. exactly where it is written
  /// back on restore.
  final SafePath path;

  final int sizeBytes;

  /// Lowercase hex SHA-256 of the file's contents, verified on restore.
  final String sha256;

  /// Where this file is stored inside the archive.
  String get archiveEntryPath =>
      '${BackupManifest.payloadPrefix}/$sourceId/${path.value}';

  Map<String, Object?> toJson() => {
    'sourceId': sourceId,
    'path': path.value,
    'sizeBytes': sizeBytes,
    'sha256': sha256,
  };
}

/// The metadata document stored at the root of every Checkpoint archive.
///
/// Versioning is the point. [formatVersion] is checked before anything in an
/// archive is trusted: a newer archive is refused with a clear message rather
/// than half-restored, and older versions can be migrated in [_migrate] as the
/// format evolves.
///
/// The archive is a ZIP laid out as:
///
/// ```text
/// checkpoint.json                     this document
/// files/<sourceId>/<relative path>    payload, nothing lives outside files/
/// ```
final class BackupManifest {
  const BackupManifest({
    required this.formatVersion,
    required this.appVersion,
    required this.backupId,
    required this.createdAt,
    required this.emulatorId,
    required this.emulatorName,
    required this.gameId,
    required this.gameTitle,
    required this.sources,
    required this.files,
  });

  /// The version this build writes.
  static const int currentFormatVersion = 1;

  /// The oldest version this build can still read.
  static const int minimumSupportedFormatVersion = 1;

  /// Manifest entry name at the archive root.
  static const String fileName = 'checkpoint.json';

  /// Directory every payload file lives under.
  static const String payloadPrefix = 'files';

  final int formatVersion;

  /// Checkpoint version that wrote the archive, for diagnostics.
  final String appVersion;

  /// Unique id for this backup, also used in the archive filename.
  final String backupId;

  /// Always stored in UTC.
  final DateTime createdAt;

  final String emulatorId;
  final String emulatorName;
  final String gameId;
  final String gameTitle;

  final List<BackupSource> sources;
  final List<BackupFileEntry> files;

  int get totalBytes => files.fold(0, (sum, f) => sum + f.sizeBytes);

  int get fileCount => files.length;

  BackupSource? sourceById(String id) {
    for (final source in sources) {
      if (source.id == id) return source;
    }
    return null;
  }

  bool get containsSaveData =>
      sources.any((s) => s.kind == SaveKind.saveData);

  bool get containsSaveStates =>
      sources.any((s) => s.kind == SaveKind.saveState);

  Map<String, Object?> toJson() => {
    'formatVersion': formatVersion,
    'appVersion': appVersion,
    'backupId': backupId,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'emulator': {'id': emulatorId, 'name': emulatorName},
    'game': {'id': gameId, 'title': gameTitle},
    'sources': sources.map((s) => s.toJson()).toList(),
    'files': files.map((f) => f.toJson()).toList(),
  };

  List<int> encode() => utf8.encode(const JsonEncoder.withIndent('  ').convert(toJson()));

  /// Parses a manifest from archive bytes.
  ///
  /// Every field is treated as hostile input: a backup file is just a file the
  /// user obtained somewhere, and it may have been crafted. Anything unexpected
  /// produces an [ArchiveFailure] instead of a partially built manifest.
  static Result<BackupManifest> decode(List<int> bytes) {
    final Object? raw;
    try {
      raw = jsonDecode(utf8.decode(bytes, allowMalformed: true));
    } on FormatException catch (e) {
      return Err(
        ArchiveFailure(
          message: 'This backup\'s metadata is not valid JSON.',
          detail: e.message,
        ),
      );
    }

    if (raw is! Map<String, Object?>) {
      return const Err(
        ArchiveFailure(message: 'This backup\'s metadata is malformed.'),
      );
    }
    return fromJson(raw);
  }

  static Result<BackupManifest> fromJson(Map<String, Object?> json) {
    Err<BackupManifest> reject(String why, [String? detail]) =>
        Err<BackupManifest>(ArchiveFailure(message: why, detail: detail));

    final formatVersion = json['formatVersion'];
    if (formatVersion is! int) {
      return reject('This backup is missing its format version.');
    }
    if (formatVersion > currentFormatVersion) {
      return reject(
        'This backup was made by a newer version of Checkpoint. '
        'Update Checkpoint to restore it.',
        'formatVersion $formatVersion > $currentFormatVersion',
      );
    }
    if (formatVersion < minimumSupportedFormatVersion) {
      return reject(
        'This backup uses a format Checkpoint no longer supports.',
        'formatVersion $formatVersion',
      );
    }

    final migrated = _migrate(json, formatVersion);

    final emulator = migrated['emulator'];
    final game = migrated['game'];
    if (emulator is! Map<String, Object?> || game is! Map<String, Object?>) {
      return reject('This backup does not say which game it belongs to.');
    }

    final createdAtRaw = migrated['createdAt'];
    final createdAt = createdAtRaw is String
        ? DateTime.tryParse(createdAtRaw)
        : null;
    if (createdAt == null) {
      return reject('This backup has no valid creation time.');
    }

    final sourcesRaw = migrated['sources'];
    final filesRaw = migrated['files'];
    if (sourcesRaw is! List || filesRaw is! List) {
      return reject('This backup does not list its contents.');
    }

    final sources = <BackupSource>[];
    for (final entry in sourcesRaw) {
      if (entry is! Map<String, Object?>) {
        return reject('This backup has a malformed source entry.');
      }
      final id = entry['id'];
      final layoutId = entry['layoutId'];
      if (id is! String || id.isEmpty || layoutId is! String) {
        return reject('This backup has a malformed source entry.');
      }
      // Source ids become a path segment inside the archive, so they must be
      // safe on their own — a source id of "../.." would otherwise smuggle a
      // traversal in through the back door.
      final segment = SafePath.parse(id);
      if (segment is Err<SafePath> || segment.valueOrNull!.segments.length != 1) {
        return reject('This backup has an unsafe source identifier.', id);
      }
      sources.add(
        BackupSource(
          id: id,
          label: entry['label'] as String? ?? id,
          kind: _kindFromName(entry['kind']),
          layoutId: layoutId,
          originDisplayPath: entry['originDisplayPath'] as String?,
        ),
      );
    }

    final sourceIds = sources.map((s) => s.id).toSet();
    final files = <BackupFileEntry>[];
    for (final entry in filesRaw) {
      if (entry is! Map<String, Object?>) {
        return reject('This backup has a malformed file entry.');
      }
      final sourceId = entry['sourceId'];
      final rawPath = entry['path'];
      final sizeBytes = entry['sizeBytes'];
      final sha256 = entry['sha256'];
      if (sourceId is! String ||
          rawPath is! String ||
          sizeBytes is! int ||
          sha256 is! String) {
        return reject('This backup has a malformed file entry.');
      }
      if (!sourceIds.contains(sourceId)) {
        return reject(
          'This backup refers to a source it does not describe.',
          sourceId,
        );
      }
      if (sizeBytes < 0) {
        return reject('This backup declares a negative file size.', rawPath);
      }
      final path = SafePath.parse(rawPath);
      switch (path) {
        case Err<SafePath>(:final failure):
          return reject('This backup contains an unsafe file path.', failure.detail);
        case Ok<SafePath>(:final value):
          files.add(
            BackupFileEntry(
              sourceId: sourceId,
              path: value,
              sizeBytes: sizeBytes,
              sha256: sha256.toLowerCase(),
            ),
          );
      }
    }

    return Ok(
      BackupManifest(
        formatVersion: formatVersion,
        appVersion: migrated['appVersion'] as String? ?? 'unknown',
        backupId: migrated['backupId'] as String? ?? '',
        createdAt: createdAt.toUtc(),
        emulatorId: emulator['id'] as String? ?? 'unknown',
        emulatorName: emulator['name'] as String? ?? 'Unknown emulator',
        gameId: game['id'] as String? ?? 'unknown',
        gameTitle: game['title'] as String? ?? 'Unknown game',
        sources: sources,
        files: files,
      ),
    );
  }

  /// Upgrades an older manifest document to the current shape.
  ///
  /// Version 1 is the first format, so there is nothing to migrate yet. The
  /// hook exists now so that adding version 2 is a local change here rather
  /// than a rewrite of [fromJson].
  static Map<String, Object?> _migrate(
    Map<String, Object?> json,
    int fromVersion,
  ) => json;

  static SaveKind _kindFromName(Object? name) {
    for (final kind in SaveKind.values) {
      if (kind.name == name) return kind;
    }
    // An unrecognised kind is not worth failing a restore over; treat it as
    // save data, which is the conservative choice for what to warn about.
    return SaveKind.saveData;
  }
}
