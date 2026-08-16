import 'package:checkpoint/domain/emulator/game_platform.dart';
import 'package:checkpoint/domain/emulator/save_kind.dart';
import 'package:checkpoint/domain/emulator/save_layout.dart';

/// One folder an emulator keeps saves in, and how to read it.
///
/// An emulator usually has more than one: PPSSPP separates `SAVEDATA` from
/// `PPSSPP_STATE`, RetroArch separates `saves/` from `states/`. Each is granted
/// and scanned independently, which is what lets Checkpoint tell the user
/// exactly which kind of data a backup or restore touches.
final class SaveSource {
  const SaveSource({
    required this.id,
    required this.label,
    required this.kind,
    required this.layout,
    this.androidPathHints = const [],
    this.required = true,
  });

  /// Stable identifier, unique within its emulator. Recorded in backup
  /// manifests to map archived files back to the folder they came from, so it
  /// must never be reused for a different meaning.
  final String id;

  /// What to call this folder when asking the user for it, e.g.
  /// `PSP save data folder`.
  final String label;

  final SaveKind kind;

  final SaveLayout layout;

  /// Where this folder usually lives on Android. Used purely to open the
  /// system picker close to the right place, and to show the user what to look
  /// for. Checkpoint never reads these paths directly — access always comes
  /// from the folder the user actually picks.
  final List<String> androidPathHints;

  /// Whether a game is expected to have data here. Optional sources (save
  /// states) simply produce no games when the folder is not granted, instead of
  /// being reported as a problem.
  final bool required;
}

/// Everything Checkpoint knows about one emulator.
///
/// This is the whole extension point. Supporting a new emulator whose saves
/// follow a shape that already has a [SaveLayout] means adding one `const`
/// entry to the registry — no `switch`, no new manager class, no changes to
/// discovery, backup, restore or UI code.
final class EmulatorDefinition {
  const EmulatorDefinition({
    required this.id,
    required this.name,
    required this.platform,
    required this.androidPackageIds,
    required this.saveSources,
  });

  /// Stable identifier written into backup manifests, e.g. `ppsspp`.
  final String id;

  final String name;

  final GamePlatform platform;

  /// Package identifiers this emulator ships under, including forks and paid
  /// variants. Presence of any one means the emulator is installed.
  final List<String> androidPackageIds;

  final List<SaveSource> saveSources;

  SaveSource? sourceById(String sourceId) {
    for (final source in saveSources) {
      if (source.id == sourceId) return source;
    }
    return null;
  }

  @override
  String toString() => 'EmulatorDefinition($id)';
}
