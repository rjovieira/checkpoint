import 'package:checkpoint/application/transfer_controller.dart';
import 'package:checkpoint/application/usecases/list_backups.dart';
import 'package:checkpoint/application/usecases/restore_backup.dart';
import 'package:checkpoint/core/failure.dart';
import 'package:checkpoint/core/formatting.dart';
import 'package:checkpoint/core/result.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Inspects a backup, shows the user exactly what restoring it would do, and
/// only then performs it.
///
/// The confirmation is not a formality. A restore overwrites save files in
/// place, so the dialog names the game, the folders that will be written to,
/// and whether save data or save states are involved — all read from the
/// archive's own manifest, not guessed from its filename.
Future<void> startRestore(
  BuildContext context,
  WidgetRef ref,
  BackupSummary summary,
) async {
  final controller = ref.read(transferControllerProvider.notifier);
  final planResult = await controller.planRestore(summary.path);

  if (!context.mounted) return;

  switch (planResult) {
    case Err<RestorePlan>(:final failure):
      await _showBlocked(context, failure);
    case Ok<RestorePlan>(:final value):
      final confirmed = await _confirm(context, value, summary);
      if (confirmed == true) {
        await controller.restore(value);
      }
  }
}

Future<bool?> _confirm(
  BuildContext context,
  RestorePlan plan,
  BackupSummary summary,
) {
  final manifest = plan.manifest;

  return showDialog<bool>(
    context: context,
    builder: (context) {
      final theme = Theme.of(context);
      return AlertDialog(
        title: const Text('Restore this backup?'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              _Fact(label: 'Game', value: manifest.gameTitle),
              _Fact(label: 'Emulator', value: manifest.emulatorName),
              _Fact(
                label: 'Created',
                value: formatTimestamp(manifest.createdAt),
              ),
              _Fact(
                label: 'Contents',
                value:
                    '${manifest.fileCount} file'
                    '${manifest.fileCount == 1 ? '' : 's'} · '
                    '${formatBytes(manifest.totalBytes)}',
              ),
              const SizedBox(height: 16),
              Text('Will be written to', style: theme.textTheme.titleSmall),
              const SizedBox(height: 4),
              for (final target in plan.targets)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    '• ${target.source.kind.label} → '
                    '${target.root.displayPath ?? target.root.displayName}'
                    '\n  ${target.fileCount} file'
                    '${target.fileCount == 1 ? '' : 's'}',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              if (plan.unresolved.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  'Cannot be restored: no folder is selected for '
                  '${plan.unresolved.map((u) => u.source.label).join(', ')}.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ],
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  'Files in this backup will replace the matching files in '
                  'those folders. Anything else in them is left untouched. '
                  'This cannot be undone.',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: plan.canApply
                ? () => Navigator.of(context).pop(true)
                : null,
            child: const Text('Restore'),
          ),
        ],
      );
    },
  );
}

Future<void> _showBlocked(BuildContext context, Failure failure) {
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('This backup cannot be restored'),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(failure.message),
          if (failure.detail != null) ...[
            const SizedBox(height: 12),
            Text(failure.detail!, style: Theme.of(context).textTheme.bodySmall),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    ),
  );
}

class _Fact extends StatelessWidget {
  const _Fact({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 84,
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(child: Text(value, style: theme.textTheme.bodyMedium)),
        ],
      ),
    );
  }
}
