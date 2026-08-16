import 'package:checkpoint/application/transfer_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Shows the running backup or restore, and its result.
///
/// Kept as a persistent banner rather than a toast so the outcome of an
/// operation that touches save files stays on screen until the user has read
/// it.
class TransferBanner extends ConsumerWidget {
  const TransferBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(transferControllerProvider);
    final theme = Theme.of(context);

    return switch (state) {
      TransferIdle() => const SizedBox.shrink(),
      TransferRunning(:final title, :final progress) => _Banner(
        colour: theme.colorScheme.surfaceContainerHighest,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            Text(
              progress.total > 0
                  ? '${progress.label} · ${progress.completed} of '
                        '${progress.total}'
                  : progress.label,
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            LinearProgressIndicator(value: progress.fraction),
          ],
        ),
      ),
      TransferSucceeded(:final message) => _Banner(
        colour: theme.colorScheme.secondaryContainer,
        onDismiss: () => ref.read(transferControllerProvider.notifier).reset(),
        child: Row(
          children: [
            const Icon(Icons.check_circle_outline),
            const SizedBox(width: 12),
            Expanded(child: Text(message, style: theme.textTheme.bodyMedium)),
          ],
        ),
      ),
      TransferFailed(:final failure) => _Banner(
        colour: theme.colorScheme.errorContainer,
        onDismiss: () => ref.read(transferControllerProvider.notifier).reset(),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.error_outline, color: theme.colorScheme.onErrorContainer),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(failure.message, style: theme.textTheme.bodyMedium),
                  if (failure.detail != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        failure.detail!,
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    };
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.colour, required this.child, this.onDismiss});

  final Color colour;
  final Widget child;
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: colour,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
        child: Row(
          children: [
            Expanded(child: child),
            if (onDismiss != null)
              IconButton(
                onPressed: onDismiss,
                icon: const Icon(Icons.close),
                tooltip: 'Dismiss',
              ),
          ],
        ),
      ),
    );
  }
}
