import 'package:checkpoint/application/progress.dart';
import 'package:checkpoint/application/providers.dart';
import 'package:checkpoint/application/usecases/restore_backup.dart';
import 'package:checkpoint/core/failure.dart';
import 'package:checkpoint/core/result.dart';
import 'package:checkpoint/domain/game/discovered_game.dart';
import 'package:checkpoint/domain/storage/safe_path.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// State of the one backup or restore that may be running.
///
/// Modelled as a closed set rather than a bag of booleans, so the UI has to
/// handle every case and cannot render "loading and error at the same time".
sealed class TransferState {
  const TransferState();
}

final class TransferIdle extends TransferState {
  const TransferIdle();
}

final class TransferRunning extends TransferState {
  const TransferRunning({required this.title, required this.progress});

  final String title;
  final OperationProgress progress;
}

final class TransferSucceeded extends TransferState {
  const TransferSucceeded(this.message);

  final String message;
}

final class TransferFailed extends TransferState {
  const TransferFailed(this.failure);

  final Failure failure;
}

final transferControllerProvider =
    NotifierProvider<TransferController, TransferState>(
      TransferController.new,
    );

/// Drives backup and restore, and reports progress.
///
/// Only one transfer runs at a time. Two concurrent restores into the same save
/// folder could interleave writes, and the UI has nowhere sensible to show two
/// progress bars, so a second request is refused rather than queued.
final class TransferController extends Notifier<TransferState> {
  @override
  TransferState build() => const TransferIdle();

  bool get isRunning => state is TransferRunning;

  void reset() => state = const TransferIdle();

  Future<void> backUp(DiscoveredGame game) async {
    if (isRunning) return;

    final configuration = await ref.read(configurationProvider.future);
    final backupRoot = configuration.backupRoot;
    if (backupRoot == null) {
      state = const TransferFailed(
        ValidationFailure(
          message: 'Choose a backup folder in Settings before backing up.',
        ),
      );
      return;
    }

    state = TransferRunning(
      title: 'Backing up ${game.title}',
      progress: OperationProgress(
        completed: 0,
        total: game.fileCount,
        label: 'Starting',
      ),
    );

    final result = await ref
        .read(createBackupProvider)
        .call(
          game: game,
          backupRoot: backupRoot,
          onProgress: (progress) {
            state = TransferRunning(
              title: 'Backing up ${game.title}',
              progress: progress,
            );
          },
        );

    state = result.fold(
      (backup) => TransferSucceeded(
        'Backed up ${backup.manifest.fileCount} file'
        '${backup.manifest.fileCount == 1 ? '' : 's'} from ${game.title}.',
      ),
      TransferFailed.new,
    );

    if (result.isOk) {
      ref.invalidate(backupsProvider);
    }
  }

  /// Works out what a restore would do, without changing anything.
  Future<Result<RestorePlan>> planRestore(SafePath archivePath) async {
    final configuration = await ref.read(configurationProvider.future);
    final backupRoot = configuration.backupRoot;
    if (backupRoot == null) {
      return const Err(
        ValidationFailure(message: 'No backup folder is configured.'),
      );
    }
    return ref
        .read(restoreBackupProvider)
        .inspect(
          backupRoot: backupRoot,
          archivePath: archivePath,
          configuration: configuration,
        );
  }

  /// Performs a restore the user has already seen a plan for and confirmed.
  Future<void> restore(RestorePlan plan) async {
    if (isRunning) return;

    final configuration = await ref.read(configurationProvider.future);
    final backupRoot = configuration.backupRoot;
    if (backupRoot == null) {
      state = const TransferFailed(
        ValidationFailure(message: 'No backup folder is configured.'),
      );
      return;
    }

    final title = 'Restoring ${plan.manifest.gameTitle}';
    state = TransferRunning(
      title: title,
      progress: OperationProgress(
        completed: 0,
        total: plan.fileCount,
        label: 'Starting',
      ),
    );

    final result = await ref
        .read(restoreBackupProvider)
        .apply(
          backupRoot: backupRoot,
          plan: plan,
          onProgress: (progress) {
            state = TransferRunning(title: title, progress: progress);
          },
        );

    state = result.fold(
      (summary) => TransferSucceeded(
        'Restored ${summary.filesRestored} file'
        '${summary.filesRestored == 1 ? '' : 's'} to ${summary.gameTitle}.',
      ),
      TransferFailed.new,
    );

    if (result.isOk) {
      // The save folder changed on disk, so sizes and timestamps are stale.
      ref.invalidate(gamesProvider);
    }
  }
}
