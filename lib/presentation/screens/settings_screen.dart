import 'package:checkpoint/application/providers.dart';
import 'package:checkpoint/application/usecases/detect_emulators.dart';
import 'package:checkpoint/core/app_info.dart';
import 'package:checkpoint/domain/config/app_configuration.dart';
import 'package:checkpoint/domain/emulator/emulator_definition.dart';
import 'package:checkpoint/domain/storage/file_system_port.dart';
import 'package:checkpoint/domain/storage/storage_root.dart';
import 'package:checkpoint/presentation/widgets/state_views.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Where the user grants Checkpoint the folders it needs.
///
/// Nothing here is automatic: Checkpoint has no storage permissions, so every
/// folder in this screen exists because the user picked it.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final configuration = ref.watch(configurationProvider);
    final statuses = ref.watch(emulatorStatusesProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: statuses.when(
        loading: () => const LoadingView(),
        error: (error, _) => ErrorView(
          failure: asFailure(error),
          onRetry: () => ref.invalidate(emulatorStatusesProvider),
        ),
        data: (emulators) => ListView(
          children: [
            _Header(
              title: 'Backup folder',
              subtitle: 'Where Checkpoint writes backup archives',
            ),
            _BackupRootTile(
              configuration: configuration.value ?? AppConfiguration.empty,
            ),
            const Divider(height: 24),
            _Header(
              title: 'Save folders',
              subtitle:
                  'Checkpoint reads saves only from folders you choose here',
            ),
            for (final status in emulators) _EmulatorSection(status: status),
            const Divider(height: 24),
            AboutListTile(
              icon: const Icon(Icons.info_outline),
              applicationName: 'Checkpoint',
              applicationVersion: checkpointVersion,
              aboutBoxChildren: const [
                SizedBox(height: 12),
                Text(
                  'Checkpoint requests no storage permissions. Every folder it '
                  'can read or write was granted by you, and access can be '
                  'revoked at any time from Android settings.',
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _BackupRootTile extends ConsumerWidget {
  const _BackupRootTile({required this.configuration});

  final AppConfiguration configuration;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final root = configuration.backupRoot;

    return ListTile(
      leading: Icon(
        root == null ? Icons.folder_off_outlined : Icons.folder_special_outlined,
      ),
      title: Text(root?.displayPath ?? root?.displayName ?? 'Not chosen'),
      subtitle: Text(
        root == null
            ? 'Backups cannot be created until this is set'
            : 'Tap to change',
      ),
      trailing: root == null
          ? null
          : IconButton(
              tooltip: 'Forget this folder',
              icon: const Icon(Icons.link_off),
              onPressed: () async {
                await ref.read(directoryPickerProvider).releaseRoot(root);
                await ref
                    .read(configurationProvider.notifier)
                    .setBackupRoot(null);
              },
            ),
      onTap: () async {
        final picked = await _pick(context, ref);
        if (picked == null) return;
        await ref.read(configurationProvider.notifier).setBackupRoot(picked);
      },
    );
  }
}

class _EmulatorSection extends ConsumerWidget {
  const _EmulatorSection({required this.status});

  final EmulatorStatus status;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);

    return ExpansionTile(
      leading: Icon(
        status.isInstalled
            ? Icons.check_circle_outline
            : Icons.radio_button_unchecked,
        color: status.isInstalled ? theme.colorScheme.primary : null,
      ),
      title: Text(status.definition.name),
      subtitle: Text(
        [
          status.definition.platform.label,
          if (status.isInstalled) 'installed' else 'not detected',
          if (status.isConfigured)
            '${status.grantedRoots.length} folder'
            '${status.grantedRoots.length == 1 ? '' : 's'} set',
        ].join(' · '),
      ),
      initiallyExpanded: status.isInstalled && !status.isConfigured,
      children: [
        for (final source in status.definition.saveSources)
          _SourceTile(
            emulator: status.definition,
            source: source,
            granted: status.grantedRoots[source.id],
          ),
      ],
    );
  }
}

class _SourceTile extends ConsumerWidget {
  const _SourceTile({
    required this.emulator,
    required this.source,
    required this.granted,
  });

  final EmulatorDefinition emulator;
  final SaveSource source;
  final StorageRoot? granted;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final root = granted;
    final hint = source.androidPathHints.isEmpty
        ? null
        : source.androidPathHints.first;

    return ListTile(
      contentPadding: const EdgeInsets.only(left: 32, right: 16),
      leading: Icon(
        root == null ? Icons.folder_outlined : Icons.folder,
        size: 20,
      ),
      title: Text(source.label),
      subtitle: Text(
        root == null
            ? (hint == null ? 'Not set' : 'Not set · usually $hint')
            : root.displayPath ?? root.displayName,
      ),
      trailing: root == null
          ? const Icon(Icons.chevron_right)
          : IconButton(
              tooltip: 'Forget this folder',
              icon: const Icon(Icons.link_off),
              onPressed: () => ref
                  .read(configurationProvider.notifier)
                  .removeSaveRoot(emulator.id, source.id),
            ),
      onTap: () async {
        final picked = await _pick(context, ref, initialHint: hint);
        if (picked == null) return;
        await ref
            .read(configurationProvider.notifier)
            .setSaveRoot(
              GrantedSaveRoot(
                emulatorId: emulator.id,
                sourceId: source.id,
                root: picked,
              ),
            );
      },
    );
  }
}

/// Opens the system folder picker and reports failures without crashing the
/// screen — a user who denies or cancels should simply be back where they were.
Future<StorageRoot?> _pick(
  BuildContext context,
  WidgetRef ref, {
  String? initialHint,
}) async {
  try {
    return await ref
        .read(directoryPickerProvider)
        .pickDirectory(initialLocationHint: initialHint);
  } on StorageException catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.message)));
    }
    return null;
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.title, required this.subtitle});

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: theme.textTheme.titleSmall?.copyWith(
              color: theme.colorScheme.primary,
            ),
          ),
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
