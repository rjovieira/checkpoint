import 'package:checkpoint/domain/emulator/title_reader.dart';
import 'package:checkpoint/domain/storage/file_system_port.dart';
import 'package:checkpoint/domain/storage/safe_path.dart';
import 'package:checkpoint/domain/storage/storage_root.dart';
import 'package:collection/collection.dart';

/// One game's files inside a single save root.
final class SaveGroup {
  const SaveGroup({
    required this.gameId,
    required this.title,
    required this.files,
    required this.totalBytes,
    this.modifiedAt,
  });

  /// Stable identifier within the emulator, e.g. `ULUS10041` or a ROM base
  /// name. Used to merge a game's save data and save states into one entry.
  final String gameId;

  /// Display name. Falls back to [gameId] when no better source exists.
  final String title;

  /// Files belonging to this game, relative to the root they were found in.
  final List<SafePath> files;

  final int totalBytes;
  final DateTime? modifiedAt;

  int get fileCount => files.length;
}

/// Describes how one emulator arranges saves inside a folder, and knows how to
/// enumerate the games in it.
///
/// Layouts are the extension point for emulator support: adding an emulator
/// whose saves follow a shape Checkpoint already understands requires no new
/// code at all, only a registry entry. A genuinely new shape means one new
/// implementation of this interface.
///
/// Implementations must be pure with respect to the platform — they see storage
/// only through [FileSystemPort], which is what makes them unit-testable
/// against an in-memory fake and identical on every OS.
abstract interface class SaveLayout {
  /// Stable identifier recorded in backup manifests, so a future version can
  /// tell how an archive was laid out.
  String get id;

  Future<List<SaveGroup>> discover(FileSystemPort fs, StorageRoot root);
}

/// Each game owns a directory; every file beneath it belongs to that game.
///
/// Several directories can map to one game — PPSSPP splits a title's data
/// across `ULUS10041DATA00`, `ULUS10041PROFILE00` and similar — so directories
/// are grouped by the identifier derived from their names.
final class DirectoryPerGameLayout implements SaveLayout {
  const DirectoryPerGameLayout({
    required this.id,
    this.groupingSuffixes = const [],
    this.idPattern,
    this.acceptUnmatchedDirectories = true,
    this.titleReader,
  });

  @override
  final String id;

  /// Suffixes stripped from a directory name before deriving the identifier.
  final List<String> groupingSuffixes;

  /// When set, a directory is only treated as a game if its name matches. The
  /// first capture group (or the whole match) becomes the identifier, which is
  /// what collapses `ULUS10041_MISC` and `ULUS10041DATA00` onto `ULUS10041`.
  final RegExp? idPattern;

  /// Whether directories that match no rule are still treated as games. `false`
  /// keeps unrelated folders out of the list for emulators with a strict naming
  /// scheme.
  final bool acceptUnmatchedDirectories;

  /// Optional metadata reader used to upgrade an identifier into a real title.
  final TitleReader? titleReader;

  @override
  Future<List<SaveGroup>> discover(FileSystemPort fs, StorageRoot root) async {
    final children = await fs.listDirectory(root, null);
    final byGameId = <String, List<SafePath>>{};

    for (final child in children) {
      if (!child.isDirectory) continue;
      if (child.name.startsWith('.')) continue;
      final gameId = _deriveGameId(child.name);
      if (gameId == null) continue;
      byGameId.putIfAbsent(gameId, () => <SafePath>[]).add(child.path);
    }

    final groups = <SaveGroup>[];
    for (final entry in byGameId.entries) {
      final files = <SafePath>[];
      var totalBytes = 0;
      DateTime? newest;

      for (final directory in entry.value) {
        for (final file in await fs.listFilesRecursively(root, directory)) {
          files.add(file.path);
          totalBytes += file.sizeBytes;
          newest = _newer(newest, file.modifiedAt);
        }
      }
      if (files.isEmpty) continue;

      groups.add(
        SaveGroup(
          gameId: entry.key,
          title:
              await _readTitle(fs, root, entry.value, files) ?? entry.key,
          files: files,
          totalBytes: totalBytes,
          modifiedAt: newest,
        ),
      );
    }

    groups.sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    return groups;
  }

  String? _deriveGameId(String directoryName) {
    var name = directoryName;
    for (final suffix in groupingSuffixes) {
      if (name.length > suffix.length && name.endsWith(suffix)) {
        name = name.substring(0, name.length - suffix.length);
        break;
      }
    }

    final pattern = idPattern;
    if (pattern == null) return name;

    final match = pattern.firstMatch(name);
    if (match == null) {
      return acceptUnmatchedDirectories ? name : null;
    }
    return match.groupCount >= 1 ? (match.group(1) ?? match.group(0)) : match.group(0);
  }

  Future<String?> _readTitle(
    FileSystemPort fs,
    StorageRoot root,
    List<SafePath> directories,
    List<SafePath> files,
  ) async {
    final reader = titleReader;
    if (reader == null) return null;

    for (final directory in directories) {
      final candidate = files
          .where((f) => f.name == reader.fileName && f.isUnder(directory))
          .firstOrNull;
      if (candidate == null) continue;
      try {
        final title = reader.parseTitle(await fs.readFile(root, candidate));
        if (title != null && title.isNotEmpty) return title;
      } on StorageException {
        // A missing or unreadable metadata file is not a discovery failure;
        // fall through to the next directory and ultimately to the game id.
        continue;
      }
    }
    return null;
  }
}

/// Every game is one or more flat files in a shared directory, distinguished by
/// base name — RetroArch's `saves/` and `states/`, mGBA's `saves/`.
///
/// `Zelda.srm`, `Zelda.state1` and `Zelda.state.auto` all belong to `Zelda`:
/// trailing extensions are stripped while they keep matching
/// [extensionPattern], which is also what decides whether a file is a save at
/// all. A file whose last extension does not match is ignored, so cover art and
/// stray notes do not become games.
final class FlatFilePerGameLayout implements SaveLayout {
  const FlatFilePerGameLayout({
    required this.id,
    required this.extensionPattern,
    this.idPattern,
    this.acceptUnmatchedNames = true,
  });

  @override
  final String id;

  /// Matched against each trailing extension, without the dot.
  final RegExp extensionPattern;

  /// Optional pattern applied to the stripped base name to recover the game
  /// identifier, with the first capture group winning.
  ///
  /// Needed wherever the filename carries more than the game: PPSSPP names
  /// save states `ULUS10041_1.00_0.ppst`, so without this the states would form
  /// their own "game" instead of merging with `ULUS10041`'s save data.
  final RegExp? idPattern;

  /// Whether a base name that matches no [idPattern] is still treated as a
  /// game.
  final bool acceptUnmatchedNames;

  static const int _maxStrippedExtensions = 4;

  @override
  Future<List<SaveGroup>> discover(FileSystemPort fs, StorageRoot root) async {
    final children = await fs.listDirectory(root, null);
    final byGameId = <String, List<StorageEntry>>{};

    for (final child in children) {
      if (child.isDirectory) continue;
      if (child.name.startsWith('.')) continue;
      final baseName = _deriveBaseName(child.name);
      if (baseName == null) continue;
      byGameId.putIfAbsent(baseName, () => <StorageEntry>[]).add(child);
    }

    final groups = byGameId.entries.map((entry) {
      var totalBytes = 0;
      DateTime? newest;
      for (final file in entry.value) {
        totalBytes += file.sizeBytes;
        newest = _newer(newest, file.modifiedAt);
      }
      return SaveGroup(
        gameId: entry.key,
        title: entry.key,
        files: entry.value.map((e) => e.path).toList(growable: false),
        totalBytes: totalBytes,
        modifiedAt: newest,
      );
    }).toList();

    groups.sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    return groups;
  }

  /// The game name, or `null` if [fileName] is not a save file.
  String? _deriveBaseName(String fileName) {
    var name = fileName;
    var stripped = 0;

    while (stripped < _maxStrippedExtensions) {
      final dot = name.lastIndexOf('.');
      if (dot <= 0 || dot == name.length - 1) break;
      final extension = name.substring(dot + 1);
      if (!extensionPattern.hasMatch(extension)) break;
      name = name.substring(0, dot);
      stripped++;
    }

    if (stripped == 0 || name.isEmpty) return null;

    final pattern = idPattern;
    if (pattern == null) return name;

    final match = pattern.firstMatch(name);
    if (match == null) return acceptUnmatchedNames ? name : null;
    return match.groupCount >= 1
        ? (match.group(1) ?? match.group(0))
        : match.group(0);
  }
}

DateTime? _newer(DateTime? current, DateTime? candidate) {
  if (candidate == null) return current;
  if (current == null) return candidate;
  return candidate.isAfter(current) ? candidate : current;
}
