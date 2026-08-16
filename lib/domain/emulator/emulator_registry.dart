import 'package:checkpoint/domain/emulator/emulator_definition.dart';
import 'package:checkpoint/domain/emulator/game_platform.dart';
import 'package:checkpoint/domain/emulator/save_kind.dart';
import 'package:checkpoint/domain/emulator/save_layout.dart';
import 'package:checkpoint/domain/emulator/title_reader.dart';

/// The emulators Checkpoint supports.
///
/// The three here were chosen because all of them keep saves in ordinary shared
/// storage, so the Storage Access Framework alone can reach them. Emulators
/// that hide saves under `Android/data` (Dolphin, DuckStation, the Yuzu family)
/// need root or a user-configured custom save path, and are deliberately out of
/// scope until that is designed properly — see the roadmap in the README.
///
/// Between them they exercise both layout strategies, which is the real test of
/// whether the extension mechanism works.
final class EmulatorRegistry {
  const EmulatorRegistry(this.emulators);

  EmulatorRegistry.defaults() : this(_builtIn);

  final List<EmulatorDefinition> emulators;

  EmulatorDefinition? byId(String id) {
    for (final emulator in emulators) {
      if (emulator.id == id) return emulator;
    }
    return null;
  }

  /// Every package identifier across every emulator, for a single scoped
  /// installed-app query.
  List<String> get allPackageIds => [
    for (final emulator in emulators) ...emulator.androidPackageIds,
  ];

  static final List<EmulatorDefinition> _builtIn = [_ppsspp, _retroArch, _mgba];

  // ── PPSSPP ────────────────────────────────────────────────────────────
  //
  // Saves live in `PSP/SAVEDATA/<GAMEID><suffix>/`, one directory per save
  // slot, with several directories per game. `PARAM.SFO` inside carries the
  // real title, which turns "ULUS10041" into "God of War: Chains of Olympus".

  static final EmulatorDefinition _ppsspp = EmulatorDefinition(
    id: 'ppsspp',
    name: 'PPSSPP',
    platform: GamePlatform.playStationPortable,
    androidPackageIds: const ['org.ppsspp.ppsspp', 'org.ppsspp.ppssppgold'],
    saveSources: [
      SaveSource(
        id: 'savedata',
        label: 'PSP save data folder',
        kind: SaveKind.saveData,
        androidPathHints: const ['PSP/SAVEDATA'],
        layout: DirectoryPerGameLayout(
          id: 'ppsspp.savedata.v1',
          groupingSuffixes: const ['DATA00', 'PROFILE00'],
          idPattern: RegExp(r'^([A-Z]{4}\d{5})'),
          acceptUnmatchedDirectories: false,
          titleReader: const ParamSfoTitleReader(),
        ),
      ),
      SaveSource(
        id: 'states',
        label: 'PSP save state folder',
        kind: SaveKind.saveState,
        required: false,
        androidPathHints: const ['PSP/PPSSPP_STATE'],
        layout: FlatFilePerGameLayout(
          id: 'ppsspp.states.v1',
          extensionPattern: RegExp(
            r'^(ppst|ppss|jpg|png)$',
            caseSensitive: false,
          ),
          // States are named `<GAMEID>_<version>_<slot>`, so the id has to be
          // pulled out of the filename for them to merge with the same game's
          // save data.
          idPattern: RegExp(r'^([A-Z]{4}\d{5})'),
          acceptUnmatchedNames: false,
        ),
      ),
    ],
  );

  // ── RetroArch ─────────────────────────────────────────────────────────
  //
  // Flat files named after the ROM, split across `saves/` and `states/`.
  // `Zelda.srm`, `Zelda.state1` and `Zelda.state.auto` are all one game.

  static final EmulatorDefinition _retroArch = EmulatorDefinition(
    id: 'retroarch',
    name: 'RetroArch',
    platform: GamePlatform.multiSystem,
    androidPackageIds: const [
      'com.retroarch',
      'com.retroarch.aarch64',
      'com.retroarch.ra32',
    ],
    saveSources: [
      SaveSource(
        id: 'saves',
        label: 'RetroArch saves folder',
        kind: SaveKind.saveData,
        androidPathHints: const ['RetroArch/saves'],
        layout: FlatFilePerGameLayout(
          id: 'retroarch.saves.v1',
          extensionPattern: RegExp(
            r'^(srm|sav|rtc|mcd|mcr|bsv|dsv|eep|fla|ram|sra)$',
            caseSensitive: false,
          ),
        ),
      ),
      SaveSource(
        id: 'states',
        label: 'RetroArch states folder',
        kind: SaveKind.saveState,
        required: false,
        androidPathHints: const ['RetroArch/states'],
        layout: FlatFilePerGameLayout(
          id: 'retroarch.states.v1',
          extensionPattern: RegExp(
            r'^(state\d*|auto|png)$',
            caseSensitive: false,
          ),
        ),
      ),
    ],
  );

  // ── mGBA ──────────────────────────────────────────────────────────────

  static final EmulatorDefinition _mgba = EmulatorDefinition(
    id: 'mgba',
    name: 'mGBA',
    platform: GamePlatform.gameBoyAdvance,
    androidPackageIds: const ['io.mgba'],
    saveSources: [
      SaveSource(
        id: 'saves',
        label: 'mGBA saves folder',
        kind: SaveKind.saveData,
        androidPathHints: const ['mGBA/saves', 'mGBA'],
        layout: FlatFilePerGameLayout(
          id: 'mgba.saves.v1',
          extensionPattern: RegExp(r'^sav$', caseSensitive: false),
        ),
      ),
      SaveSource(
        id: 'states',
        label: 'mGBA save state folder',
        kind: SaveKind.saveState,
        required: false,
        androidPathHints: const ['mGBA/states', 'mGBA'],
        layout: FlatFilePerGameLayout(
          id: 'mgba.states.v1',
          extensionPattern: RegExp(r'^ss\d+$', caseSensitive: false),
        ),
      ),
    ],
  );
}
