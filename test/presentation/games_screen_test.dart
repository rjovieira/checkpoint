import 'dart:async';

import 'package:checkpoint/application/providers.dart';
import 'package:checkpoint/application/usecases/discover_games.dart';
import 'package:checkpoint/core/failure.dart';
import 'package:checkpoint/domain/config/app_configuration.dart';
import 'package:checkpoint/domain/storage/storage_root.dart';
import 'package:checkpoint/infrastructure/android/android_installed_apps.dart';
import 'package:checkpoint/presentation/screens/games_screen.dart';
import 'package:checkpoint/presentation/widgets/state_views.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_configuration_repository.dart';
import '../support/in_memory_file_system.dart';

/// Covers the four states the games list has to render, plus the discovery
/// warning. These are the screens a user actually gets stuck on, so they are
/// worth testing; the pixel layout is not.
void main() {
  const saveRoot = StorageRoot(
    id: 'root://psp',
    displayName: 'SAVEDATA',
    displayPath: 'Internal storage/PSP/SAVEDATA',
  );

  const configured = AppConfiguration(
    saveRoots: [
      GrantedSaveRoot(
        emulatorId: 'ppsspp',
        sourceId: 'savedata',
        root: saveRoot,
      ),
    ],
  );

  // Riverpod 3 does not export the `Override` type, so the shared overrides are
  // held in an inferred list and spread into each test's literal rather than
  // passed through a typed helper parameter.
  final baseOverrides = [
    // Never let a widget test reach a real platform channel.
    installedAppsProvider.overrideWithValue(const UnsupportedInstalledApps()),
  ];

  Widget screen() => const MaterialApp(home: GamesScreen());

  testWidgets('shows a spinner while save folders are being scanned', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...baseOverrides,
          gamesProvider.overrideWith(
            // A future that never completes, so the screen stays in its
            // loading state for the duration of the test.
            (ref) => Completer<GameDiscoveryResult>().future,
          ),
        ],
        child: screen(),
      ),
    );
    await tester.pump();

    expect(find.byType(LoadingView), findsOneWidget);
    expect(find.text('Scanning save folders…'), findsOneWidget);
  });

  testWidgets('guides the user to Settings when nothing is configured', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...baseOverrides,
          configurationRepositoryProvider.overrideWithValue(
            FakeConfigurationRepository(),
          ),
          fileSystemProvider.overrideWithValue(InMemoryFileSystem()),
        ],
        child: screen(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(EmptyView), findsOneWidget);
    expect(find.text('No games found yet'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Choose folders'), findsOneWidget);
  });

  testWidgets('lists discovered games with their emulator and size', (
    tester,
  ) async {
    final fs = InMemoryFileSystem()
      ..seedFile(saveRoot, 'ULUS10041DATA00/SAVE.BIN', List.filled(2048, 7))
      ..seedFile(saveRoot, 'ULES00181DATA00/SAVE.BIN', List.filled(512, 3));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...baseOverrides,
          configurationRepositoryProvider.overrideWithValue(
            FakeConfigurationRepository(configured),
          ),
          fileSystemProvider.overrideWithValue(fs),
        ],
        child: screen(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(EmptyView), findsNothing);
    expect(find.text('ULUS10041'), findsOneWidget);
    expect(find.text('ULES00181'), findsOneWidget);
    expect(find.textContaining('PPSSPP'), findsNWidgets(2));
    expect(find.textContaining('2.0 KB'), findsOneWidget);
  });

  testWidgets('shows a readable error with the details tucked away', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...baseOverrides,
          gamesProvider.overrideWith(
            (ref) async => throw const StorageFailure(
              message: 'Could not read the save folder.',
              detail: 'EACCES on /storage/emulated/0/PSP',
            ),
          ),
        ],
        child: screen(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(ErrorView), findsOneWidget);
    expect(find.text('Could not read the save folder.'), findsOneWidget);
    // The technical detail is present but collapsed behind "Details".
    expect(find.text('Details'), findsOneWidget);
    expect(find.text('EACCES on /storage/emulated/0/PSP'), findsNothing);
    // A failed scan is recoverable, so the screen must offer a way out.
    expect(find.widgetWithText(FilledButton, 'Try again'), findsOneWidget);
  });

  testWidgets('surfaces a revoked folder instead of silently losing games', (
    tester,
  ) async {
    final fs = InMemoryFileSystem()
      ..seedFile(saveRoot, 'ULUS10041DATA00/SAVE.BIN', [1])
      ..makeInaccessible(saveRoot);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...baseOverrides,
          configurationRepositoryProvider.overrideWithValue(
            FakeConfigurationRepository(configured),
          ),
          fileSystemProvider.overrideWithValue(fs),
        ],
        child: screen(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('PPSSPP'), findsOneWidget);
    expect(find.textContaining('no longer has access'), findsOneWidget);
  });

  testWidgets('a discovery issue is reported even when it is not fatal', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...baseOverrides,
          gamesProvider.overrideWith(
            (ref) async => const GameDiscoveryResult(
              games: [],
              issues: [
                DiscoveryIssue(
                  emulatorName: 'RetroArch',
                  sourceLabel: 'RetroArch states folder',
                  failure: PermissionFailure(
                    message: 'Select the folder again in Settings.',
                  ),
                ),
              ],
            ),
          ),
        ],
        child: screen(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('RetroArch · RetroArch states folder'), findsOneWidget);
    expect(
      find.text('No games could be read from the folders above.'),
      findsOneWidget,
    );
  });
}
