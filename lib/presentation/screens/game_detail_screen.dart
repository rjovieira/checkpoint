import 'package:checkpoint/application/providers.dart';
import 'package:checkpoint/application/transfer_controller.dart';
import 'package:checkpoint/core/formatting.dart';
import 'package:checkpoint/domain/emulator/save_kind.dart';
import 'package:checkpoint/domain/game/discovered_game.dart';
import 'package:checkpoint/presentation/screens/restore_flow.dart';
import 'package:checkpoint/presentation/widgets/state_views.dart';
import 'package:checkpoint/presentation/widgets/transfer_banner.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// One game: where its saves come from, where a backup would go, and the
/// backups that already exist.
///
/// The point of this screen is that the user can answer "what exactly is about
/// to happen?" before pressing anything.
class GameDetailScreen extends ConsumerWidget {
  const GameDetailScreen({required this.game, super.key});

  final DiscoveredGame game;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final configuration = ref.watch(configurationProvider);
    final transfer = ref.watch(transferControllerProvider);
    final backupRoot = configuration.value?.backupRoot;

    final backups = ref.watch(
      backupsProvider((emulatorId: game.emulatorId, gameId: game.gameId)),
    );

    return Scaffold(
      appBar: AppBar(title: Text(game.title)),
      body: Column(
        children: [
          const TransferBanner(),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.only(bottom: 24),
              children: [
                _SectionHeader(
                  title: 'Save data',
                  subtitle: 'Where this backup would be read from',
                ),
                for (final saveSet in game.saveSets)
                  ListTile(
                    leading: Icon(switch (saveSet.kind) {
                      SaveKind.saveData => Icons.save_outlined,
                      SaveKind.saveState => Icons.camera_outlined,
                    }),
                    title: Text(saveSet.kind.label),
                    // Naming the kind matters: the user is about to overwrite
                    // one of these, and they are not interchangeable.
                    subtitle: Text(
                      '${saveSet.fileCount} file'
                      '${saveSet.fileCount == 1 ? '' : 's'} · '
                      '${formatBytes(saveSet.totalBytes)}\n'
                      '${saveSet.root.displayPath ?? saveSet.root.displayName}',
                    ),
                    isThreeLine: true,
                  ),

                const Divider(height: 32),

                _SectionHeader(
                  title: 'Backup destination',
                  subtitle: 'Where the archive will be written',
                ),
                ListTile(
                  leading: Icon(
                    backupRoot == null
                        ? Icons.folder_off_outlined
                        : Icons.folder_outlined,
                  ),
                  title: Text(
                    backupRoot?.displayPath ??
                        backupRoot?.displayName ??
                        'No backup folder chosen',
                  ),
                  subtitle: backupRoot == null
                      ? const Text('Choose one in Settings before backing up')
                      : null,
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  child: FilledButton.icon(
                    onPressed: backupRoot == null || transfer is TransferRunning
                        ? null
                        : () => ref
                              .read(transferControllerProvider.notifier)
                              .backUp(game),
                    icon: const Icon(Icons.backup_outlined),
                    label: Text(
                      'Back up ${game.fileCount} file'
                      '${game.fileCount == 1 ? '' : 's'} '
                      '(${formatBytes(game.totalBytes)})',
                    ),
                  ),
                ),

                const Divider(height: 32),

                _SectionHeader(
                  title: 'Backups of this game',
                  subtitle: 'Newest first',
                ),
                backups.when(
                  loading: () => const Padding(
                    padding: EdgeInsets.all(24),
                    child: LoadingView(),
                  ),
                  error: (error, _) => Padding(
                    padding: const EdgeInsets.all(16),
                    child: ErrorView(
                      failure: asFailure(error),
                      onRetry: () => ref.invalidate(backupsProvider),
                    ),
                  ),
                  data: (summaries) => summaries.isEmpty
                      ? Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(
                            backupRoot == null
                                ? 'Choose a backup folder in Settings to '
                                      'start keeping backups.'
                                : 'No backups of this game yet.',
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        )
                      : Column(
                          children: [
                            for (final summary in summaries)
                              ListTile(
                                leading: const Icon(Icons.inventory_2_outlined),
                                title: Text(formatTimestamp(summary.createdAt)),
                                subtitle: Text(
                                  '${formatBytes(summary.sizeBytes)} · '
                                  '${formatRelative(summary.createdAt)}',
                                ),
                                trailing: TextButton(
                                  onPressed: transfer is TransferRunning
                                      ? null
                                      : () =>
                                            startRestore(context, ref, summary),
                                  child: const Text('Restore'),
                                ),
                              ),
                          ],
                        ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, required this.subtitle});

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: theme.textTheme.titleMedium),
          Text(
            subtitle,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
