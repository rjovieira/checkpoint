import 'package:checkpoint/application/providers.dart';
import 'package:checkpoint/application/usecases/discover_games.dart';
import 'package:checkpoint/core/formatting.dart';
import 'package:checkpoint/domain/game/discovered_game.dart';
import 'package:checkpoint/presentation/screens/game_detail_screen.dart';
import 'package:checkpoint/presentation/screens/settings_screen.dart';
import 'package:checkpoint/presentation/widgets/state_views.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The games Checkpoint found, and the way in to backing one up.
class GamesScreen extends ConsumerWidget {
  const GamesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final games = ref.watch(gamesProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Games'),
        actions: [
          IconButton(
            onPressed: () => ref.invalidate(gamesProvider),
            icon: const Icon(Icons.refresh),
            tooltip: 'Rescan save folders',
          ),
        ],
      ),
      body: games.when(
        loading: () => const LoadingView(message: 'Scanning save folders…'),
        error: (error, _) => ErrorView(
          failure: asFailure(error),
          onRetry: () => ref.invalidate(gamesProvider),
        ),
        data: (result) => _GamesList(result: result),
      ),
    );
  }
}

class _GamesList extends ConsumerWidget {
  const _GamesList({required this.result});

  final GameDiscoveryResult result;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (result.isEmpty && result.issues.isEmpty) {
      return EmptyView(
        icon: Icons.videogame_asset_outlined,
        title: 'No games found yet',
        message:
            'Checkpoint needs to know where your emulator keeps its saves. '
            'Choose a save folder in Settings and it will scan for games.',
        action: FilledButton.icon(
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const SettingsScreen()),
          ),
          icon: const Icon(Icons.folder_open),
          label: const Text('Choose folders'),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: () async => ref.invalidate(gamesProvider),
      child: ListView(
        children: [
          for (final issue in result.issues) _IssueTile(issue: issue),
          if (result.games.isEmpty && result.issues.isNotEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'No games could be read from the folders above.',
                textAlign: TextAlign.center,
              ),
            ),
          for (final game in result.games) _GameTile(game: game),
        ],
      ),
    );
  }
}

class _IssueTile extends StatelessWidget {
  const _IssueTile({required this.issue});

  final DiscoveryIssue issue;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      color: theme.colorScheme.errorContainer,
      child: ListTile(
        leading: const Icon(Icons.warning_amber_outlined),
        title: Text('${issue.emulatorName} · ${issue.sourceLabel}'),
        subtitle: Text(issue.failure.message),
        onTap: () => Navigator.of(
          context,
        ).push(MaterialPageRoute<void>(builder: (_) => const SettingsScreen())),
      ),
    );
  }
}

class _GameTile extends StatelessWidget {
  const _GameTile({required this.game});

  final DiscoveredGame game;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final modifiedAt = game.modifiedAt;

    return ListTile(
      leading: CircleAvatar(
        backgroundColor: theme.colorScheme.secondaryContainer,
        child: Text(
          game.emulatorName.characters.first,
          style: TextStyle(color: theme.colorScheme.onSecondaryContainer),
        ),
      ),
      title: Text(game.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        '${game.emulatorName} · ${game.fileCount} file'
        '${game.fileCount == 1 ? '' : 's'} · ${formatBytes(game.totalBytes)}'
        '${modifiedAt == null ? '' : ' · ${formatRelative(modifiedAt)}'}',
      ),
      trailing: Wrap(
        spacing: 4,
        children: [
          if (game.hasSaveData)
            const _KindChip(label: 'Saves', icon: Icons.save_outlined),
          if (game.hasSaveStates)
            const _KindChip(label: 'States', icon: Icons.camera_outlined),
        ],
      ),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => GameDetailScreen(game: game)),
      ),
    );
  }
}

class _KindChip extends StatelessWidget {
  const _KindChip({required this.label, required this.icon});

  final String label;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: label,
      child: Icon(
        icon,
        size: 18,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
  }
}
