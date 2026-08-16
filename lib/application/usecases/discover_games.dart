import 'package:checkpoint/core/failure.dart';
import 'package:checkpoint/domain/config/app_configuration.dart';
import 'package:checkpoint/domain/emulator/emulator_definition.dart';
import 'package:checkpoint/domain/emulator/emulator_registry.dart';
import 'package:checkpoint/domain/game/discovered_game.dart';
import 'package:checkpoint/domain/storage/file_system_port.dart';
import 'package:checkpoint/domain/storage/storage_root.dart';

/// A save folder that could not be scanned.
///
/// Surfaced rather than swallowed: one revoked folder should not silently make
/// a user's games disappear with no explanation.
final class DiscoveryIssue {
  const DiscoveryIssue({
    required this.emulatorName,
    required this.sourceLabel,
    required this.failure,
  });

  final String emulatorName;
  final String sourceLabel;
  final Failure failure;
}

final class GameDiscoveryResult {
  const GameDiscoveryResult({required this.games, required this.issues});

  final List<DiscoveredGame> games;
  final List<DiscoveryIssue> issues;

  bool get isEmpty => games.isEmpty;
}

/// Scans every granted save folder and merges the results into games.
///
/// A game's save data and save states live in different folders, so the same
/// title is found once per source and merged here on (emulator, game id). That
/// merge is why a single backup can capture both while still recording which
/// files came from where.
final class DiscoverGames {
  const DiscoverGames({required this.registry, required this.fileSystem});

  final EmulatorRegistry registry;
  final FileSystemPort fileSystem;

  Future<GameDiscoveryResult> call(AppConfiguration configuration) async {
    final games = <String, _GameBuilder>{};
    final issues = <DiscoveryIssue>[];

    for (final emulator in registry.emulators) {
      for (final source in emulator.saveSources) {
        final root = configuration.saveRootFor(emulator.id, source.id);
        if (root == null) continue;

        try {
          await _scan(emulator, source, root, games);
        } on StorageAccessDeniedException catch (e) {
          issues.add(
            DiscoveryIssue(
              emulatorName: emulator.name,
              sourceLabel: source.label,
              failure: PermissionFailure(
                message:
                    'Checkpoint no longer has access to the '
                    '${source.label.toLowerCase()}. Select it again in '
                    'Settings.',
                detail: e.detail,
              ),
            ),
          );
        } on StorageException catch (e) {
          issues.add(
            DiscoveryIssue(
              emulatorName: emulator.name,
              sourceLabel: source.label,
              failure: StorageFailure(message: e.message, detail: e.detail),
            ),
          );
        }
      }
    }

    final result = games.values.map((b) => b.build()).toList()
      ..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));

    return GameDiscoveryResult(games: result, issues: issues);
  }

  Future<void> _scan(
    EmulatorDefinition emulator,
    SaveSource source,
    StorageRoot root,
    Map<String, _GameBuilder> games,
  ) async {
    final groups = await source.layout.discover(fileSystem, root);

    for (final group in groups) {
      final key = '${emulator.id}:${group.gameId}';
      final builder = games.putIfAbsent(
        key,
        () => _GameBuilder(
          emulatorId: emulator.id,
          emulatorName: emulator.name,
          gameId: group.gameId,
        ),
      );

      builder.addSaveSet(
        GameSaveSet(
          sourceId: source.id,
          sourceLabel: source.label,
          kind: source.kind,
          layoutId: source.layout.id,
          root: root,
          files: group.files,
          totalBytes: group.totalBytes,
          modifiedAt: group.modifiedAt,
        ),
        title: group.title,
        titleIsMeaningful: group.title != group.gameId,
      );
    }
  }
}

final class _GameBuilder {
  _GameBuilder({
    required this.emulatorId,
    required this.emulatorName,
    required this.gameId,
  }) : title = gameId;

  final String emulatorId;
  final String emulatorName;
  final String gameId;
  final List<GameSaveSet> saveSets = [];

  String title;
  bool _hasMeaningfulTitle = false;

  void addSaveSet(
    GameSaveSet saveSet, {
    required String title,
    required bool titleIsMeaningful,
  }) {
    saveSets.add(saveSet);
    // A real title from game metadata always beats a folder or file name, no
    // matter which source happened to be scanned first.
    if (titleIsMeaningful && !_hasMeaningfulTitle) {
      this.title = title;
      _hasMeaningfulTitle = true;
    }
  }

  DiscoveredGame build() => DiscoveredGame(
    emulatorId: emulatorId,
    emulatorName: emulatorName,
    gameId: gameId,
    title: title,
    saveSets: saveSets,
  );
}
