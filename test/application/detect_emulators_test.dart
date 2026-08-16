import 'package:checkpoint/application/usecases/detect_emulators.dart';
import 'package:checkpoint/domain/config/app_configuration.dart';
import 'package:checkpoint/domain/emulator/emulator_registry.dart';
import 'package:checkpoint/domain/platform/installed_app_port.dart';
import 'package:checkpoint/domain/storage/storage_root.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final registry = EmulatorRegistry.defaults();

  DetectEmulators detectorFor(List<InstalledApp> installed) => DetectEmulators(
    registry: registry,
    installedApps: _FakeInstalledApps(installed),
  );

  EmulatorStatus statusFor(List<EmulatorStatus> statuses, String id) =>
      statuses.firstWhere((s) => s.definition.id == id);

  test('every registered emulator is reported, installed or not', () async {
    final statuses = await detectorFor(const [])(AppConfiguration.empty);

    expect(statuses.map((s) => s.definition.id), [
      'ppsspp',
      'retroarch',
      'mgba',
    ]);
    expect(statuses.every((s) => !s.isInstalled), isTrue);
    expect(statuses.every((s) => !s.isConfigured), isTrue);
  });

  test('detects an emulator by any of its package ids', () async {
    // The paid build, not the free one listed first.
    final statuses = await detectorFor(const [
      InstalledApp(packageId: 'org.ppsspp.ppssppgold', label: 'PPSSPP Gold'),
    ])(AppConfiguration.empty);

    final ppsspp = statusFor(statuses, 'ppsspp');
    expect(ppsspp.isInstalled, isTrue);
    expect(ppsspp.installedLabel, 'PPSSPP Gold');
    expect(statusFor(statuses, 'mgba').isInstalled, isFalse);
  });

  test('reports which folders are still missing', () async {
    const configured = AppConfiguration(
      saveRoots: [
        GrantedSaveRoot(
          emulatorId: 'ppsspp',
          sourceId: 'states',
          root: StorageRoot(id: 'root://states', displayName: 'PPSSPP_STATE'),
        ),
      ],
    );

    final ppsspp = statusFor(await detectorFor(const [])(configured), 'ppsspp');

    expect(ppsspp.isConfigured, isTrue);
    expect(ppsspp.grantedRoots.keys, ['states']);
    // Save states are optional; save data is not, so only that is reported.
    expect(ppsspp.missingRequiredSources.map((s) => s.id), ['savedata']);
  });

  test('nothing is missing once every required folder is granted', () async {
    const configured = AppConfiguration(
      saveRoots: [
        GrantedSaveRoot(
          emulatorId: 'mgba',
          sourceId: 'saves',
          root: StorageRoot(id: 'root://mgba', displayName: 'saves'),
        ),
      ],
    );

    final mgba = statusFor(await detectorFor(const [])(configured), 'mgba');
    expect(mgba.missingRequiredSources, isEmpty);
  });

  test('a platform that cannot answer degrades to "not detected"', () async {
    // iOS has no equivalent API, and the emulator may simply be uninstalled
    // while its saves remain. Either way the app must stay usable.
    final statuses = await DetectEmulators(
      registry: registry,
      installedApps: _ThrowingInstalledApps(),
    )(AppConfiguration.empty);

    expect(statuses, hasLength(3));
    expect(statuses.every((s) => !s.isInstalled), isTrue);
  });

  test('the registry exposes every package id for one scoped query', () {
    expect(registry.allPackageIds, contains('org.ppsspp.ppsspp'));
    expect(registry.allPackageIds, contains('com.retroarch.aarch64'));
    expect(registry.allPackageIds, contains('io.mgba'));
    expect(
      registry.allPackageIds.toSet().length,
      registry.allPackageIds.length,
      reason: 'a duplicated package id would double-report an emulator',
    );
  });

  test('every save source id is unique within its emulator', () {
    for (final emulator in registry.emulators) {
      final ids = emulator.saveSources.map((s) => s.id).toList();
      expect(
        ids.toSet().length,
        ids.length,
        reason:
            'source ids become archive path segments for ${emulator.id}, so a '
            'duplicate would make two sources collide inside a backup',
      );
    }
  });
}

final class _FakeInstalledApps implements InstalledAppPort {
  const _FakeInstalledApps(this.installed);

  final List<InstalledApp> installed;

  @override
  Future<List<InstalledApp>> findInstalled(List<String> packageIds) async =>
      installed.where((app) => packageIds.contains(app.packageId)).toList();
}

final class _ThrowingInstalledApps implements InstalledAppPort {
  @override
  Future<List<InstalledApp>> findInstalled(List<String> packageIds) async =>
      throw Exception('package visibility unavailable');
}
