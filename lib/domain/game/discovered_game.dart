import 'package:checkpoint/domain/emulator/save_kind.dart';
import 'package:checkpoint/domain/storage/safe_path.dart';
import 'package:checkpoint/domain/storage/storage_root.dart';

/// One game's files from a single save source.
final class GameSaveSet {
  const GameSaveSet({
    required this.sourceId,
    required this.sourceLabel,
    required this.kind,
    required this.layoutId,
    required this.root,
    required this.files,
    required this.totalBytes,
    this.modifiedAt,
  });

  final String sourceId;
  final String sourceLabel;
  final SaveKind kind;
  final String layoutId;

  /// The granted root these files were found in and are restored back into.
  final StorageRoot root;

  /// Paths relative to [root].
  final List<SafePath> files;

  final int totalBytes;
  final DateTime? modifiedAt;

  int get fileCount => files.length;
}

/// A game Checkpoint found on the device, with everything it knows about where
/// that game's saves live.
///
/// A game is identified by (emulator, game id) and aggregates every save set
/// found for it, so backing it up captures its save data *and* its save states
/// in one archive while still recording which is which.
final class DiscoveredGame {
  const DiscoveredGame({
    required this.emulatorId,
    required this.emulatorName,
    required this.gameId,
    required this.title,
    required this.saveSets,
  });

  final String emulatorId;
  final String emulatorName;

  /// Identifier within the emulator, e.g. `ULUS10041`.
  final String gameId;

  final String title;

  final List<GameSaveSet> saveSets;

  /// Stable key across sessions, used for selection and caching.
  String get key => '$emulatorId:$gameId';

  int get totalBytes =>
      saveSets.fold(0, (sum, set) => sum + set.totalBytes);

  int get fileCount => saveSets.fold(0, (sum, set) => sum + set.fileCount);

  bool get hasSaveData => saveSets.any((s) => s.kind == SaveKind.saveData);

  bool get hasSaveStates => saveSets.any((s) => s.kind == SaveKind.saveState);

  DateTime? get modifiedAt {
    DateTime? newest;
    for (final set in saveSets) {
      final candidate = set.modifiedAt;
      if (candidate == null) continue;
      if (newest == null || candidate.isAfter(newest)) newest = candidate;
    }
    return newest;
  }

  @override
  String toString() => 'DiscoveredGame($key, "$title")';
}
