import 'package:checkpoint/application/providers.dart';
import 'package:checkpoint/application/transfer_controller.dart';
import 'package:checkpoint/core/formatting.dart';
import 'package:checkpoint/presentation/screens/restore_flow.dart';
import 'package:checkpoint/presentation/screens/settings_screen.dart';
import 'package:checkpoint/presentation/widgets/state_views.dart';
import 'package:checkpoint/presentation/widgets/transfer_banner.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Every backup in the user's backup folder.
class BackupsScreen extends ConsumerWidget {
  const BackupsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final configuration = ref.watch(configurationProvider);
    final backups = ref.watch(backupsProvider(null));
    final transfer = ref.watch(transferControllerProvider);
    final backupRoot = configuration.value?.backupRoot;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Backups'),
        actions: [
          IconButton(
            onPressed: () => ref.invalidate(backupsProvider),
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
          ),
        ],
      ),
      body: Column(
        children: [
          const TransferBanner(),
          Expanded(
            child: backupRoot == null
                ? EmptyView(
                    icon: Icons.folder_off_outlined,
                    title: 'No backup folder chosen',
                    message:
                        'Pick a folder for Checkpoint to keep backups in. '
                        'Anywhere you can reach works — including an SD card.',
                    action: FilledButton.icon(
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const SettingsScreen(),
                        ),
                      ),
                      icon: const Icon(Icons.folder_open),
                      label: const Text('Choose backup folder'),
                    ),
                  )
                : backups.when(
                    loading: () => const LoadingView(),
                    error: (error, _) => ErrorView(
                      failure: asFailure(error),
                      onRetry: () => ref.invalidate(backupsProvider),
                    ),
                    data: (summaries) => summaries.isEmpty
                        ? const EmptyView(
                            icon: Icons.inventory_2_outlined,
                            title: 'No backups yet',
                            message:
                                'Open a game from the Games tab and back it '
                                'up. Backups appear here.',
                          )
                        : ListView.builder(
                            itemCount: summaries.length,
                            itemBuilder: (context, index) {
                              final summary = summaries[index];
                              return ListTile(
                                leading: const Icon(Icons.inventory_2_outlined),
                                title: Text(summary.gameSlug),
                                subtitle: Text(
                                  '${summary.emulatorId} · '
                                  '${formatTimestamp(summary.createdAt)} · '
                                  '${formatBytes(summary.sizeBytes)}',
                                ),
                                trailing: TextButton(
                                  onPressed: transfer is TransferRunning
                                      ? null
                                      : () =>
                                            startRestore(context, ref, summary),
                                  child: const Text('Restore'),
                                ),
                              );
                            },
                          ),
                  ),
          ),
        ],
      ),
    );
  }
}
