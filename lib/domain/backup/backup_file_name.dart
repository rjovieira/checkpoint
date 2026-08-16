import 'package:checkpoint/core/result.dart';
import 'package:checkpoint/domain/storage/safe_path.dart';

/// The naming scheme for backup archives.
///
/// The filename encodes emulator, game and timestamp so the backup list can be
/// built from a single directory listing, without opening every archive. The
/// manifest inside remains the authority — the name is a fast index, never a
/// source of truth, and restore always reads the manifest.
///
/// Shape: `checkpoint__<emulatorId>__<gameSlug>__<yyyyMMdd-HHmmss>.zip`
///
/// `__` separates fields, and slugging collapses runs of `_`, so no field can
/// contain the separator and parsing stays unambiguous.
final class BackupFileName {
  const BackupFileName({
    required this.emulatorId,
    required this.gameSlug,
    required this.createdAt,
  });

  final String emulatorId;
  final String gameSlug;
  final DateTime createdAt;

  static const String _prefix = 'checkpoint';
  static const String _separator = '__';
  static const String extension = '.zip';
  static const int _maxSlugLength = 64;

  static final RegExp _unsafeCharacters = RegExp(r'[^A-Za-z0-9.-]+');

  /// Reduces an arbitrary game id to something safe in a filename on every
  /// platform. Game ids come from folder and ROM names, so they can contain
  /// anything at all.
  static String slug(String value) {
    var slug = value.replaceAll(_unsafeCharacters, '_');
    slug = slug.replaceAll(RegExp('_+'), '_');
    slug = slug.replaceAll(RegExp(r'^[._-]+|[._ -]+$'), '');
    if (slug.length > _maxSlugLength) slug = slug.substring(0, _maxSlugLength);
    slug = slug.replaceAll(RegExp(r'[._-]+$'), '');
    return slug.isEmpty ? 'game' : slug;
  }

  static BackupFileName forGame({
    required String emulatorId,
    required String gameId,
    required DateTime createdAt,
  }) => BackupFileName(
    emulatorId: slug(emulatorId),
    gameSlug: slug(gameId),
    createdAt: createdAt.toUtc(),
  );

  String get value =>
      '$_prefix$_separator$emulatorId$_separator$gameSlug$_separator'
      '${_timestamp(createdAt)}$extension';

  /// The filename as a validated path component.
  ///
  /// Slugging already guarantees safety, so a failure here means the slug rules
  /// and [SafePath] rules have drifted apart — a bug, not bad input.
  SafePath toSafePath() {
    final parsed = SafePath.parse(value);
    return switch (parsed) {
      Ok<SafePath>(:final value) => value,
      Err<SafePath>(:final failure) => throw StateError(
        'Generated backup name is not a safe path: $failure',
      ),
    };
  }

  /// Parses a filename produced by [value], or `null` if it is not one.
  static BackupFileName? tryParse(String fileName) {
    if (!fileName.endsWith(extension)) return null;
    final stem = fileName.substring(0, fileName.length - extension.length);
    final parts = stem.split(_separator);
    if (parts.length != 4 || parts[0] != _prefix) return null;

    final createdAt = _parseTimestamp(parts[3]);
    if (createdAt == null) return null;

    return BackupFileName(
      emulatorId: parts[1],
      gameSlug: parts[2],
      createdAt: createdAt,
    );
  }

  static String _timestamp(DateTime value) {
    final utc = value.toUtc();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${utc.year.toString().padLeft(4, '0')}${two(utc.month)}'
        '${two(utc.day)}-${two(utc.hour)}${two(utc.minute)}${two(utc.second)}';
  }

  static DateTime? _parseTimestamp(String value) {
    final match = RegExp(r'^(\d{4})(\d{2})(\d{2})-(\d{2})(\d{2})(\d{2})$')
        .firstMatch(value);
    if (match == null) return null;
    return DateTime.utc(
      int.parse(match.group(1)!),
      int.parse(match.group(2)!),
      int.parse(match.group(3)!),
      int.parse(match.group(4)!),
      int.parse(match.group(5)!),
      int.parse(match.group(6)!),
    );
  }
}
