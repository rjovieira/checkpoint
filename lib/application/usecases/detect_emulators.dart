import 'package:checkpoint/domain/config/app_configuration.dart';
import 'package:checkpoint/domain/emulator/emulator_definition.dart';
import 'package:checkpoint/domain/emulator/emulator_registry.dart';
import 'package:checkpoint/domain/platform/installed_app_port.dart';
import 'package:checkpoint/domain/storage/storage_root.dart';

/// What Checkpoint knows about one emulator right now.
final class EmulatorStatus {
  const EmulatorStatus({
    required this.definition,
    required this.isInstalled,
    required this.installedLabel,
    required this.grantedRoots,
  });

  final EmulatorDefinition definition;

  /// Whether the emulator's app was found on the device. On platforms that
  /// cannot answer this, always `false` — which is why the UI must never gate
  /// folder selection on it.
  final bool isInstalled;

  /// The label the OS reports for the installed app, when known.
  final String? installedLabel;

  /// Granted save folders, keyed by source id.
  final Map<String, StorageRoot> grantedRoots;

  bool get isConfigured => grantedRoots.isNotEmpty;

  /// Sources the emulator declares as required that have no folder yet.
  List<SaveSource> get missingRequiredSources => definition.saveSources
      .where((s) => s.required && !grantedRoots.containsKey(s.id))
      .toList();
}

/// Reports which supported emulators are present and configured.
///
/// Installation is a *hint*, not a gate: an emulator may be uninstalled while
/// its saves remain on disk, and iOS cannot answer the question at all. The UI
/// therefore lets the user configure any emulator in the registry and simply
/// highlights the ones that were detected.
final class DetectEmulators {
  const DetectEmulators({required this.registry, required this.installedApps});

  final EmulatorRegistry registry;
  final InstalledAppPort installedApps;

  Future<List<EmulatorStatus>> call(AppConfiguration configuration) async {
    List<InstalledApp> installed;
    try {
      installed = await installedApps.findInstalled(registry.allPackageIds);
    } on Object {
      // Package visibility is a convenience. If the platform refuses, the app
      // stays fully usable through manual folder selection.
      installed = const [];
    }

    final labelsByPackage = {
      for (final app in installed) app.packageId: app.label,
    };

    return [
      for (final definition in registry.emulators)
        _statusFor(definition, labelsByPackage, configuration),
    ];
  }

  EmulatorStatus _statusFor(
    EmulatorDefinition definition,
    Map<String, String> labelsByPackage,
    AppConfiguration configuration,
  ) {
    String? label;
    for (final packageId in definition.androidPackageIds) {
      final found = labelsByPackage[packageId];
      if (found != null) {
        label = found;
        break;
      }
    }

    final grantedRoots = <String, StorageRoot>{};
    for (final source in definition.saveSources) {
      final root = configuration.saveRootFor(definition.id, source.id);
      if (root != null) grantedRoots[source.id] = root;
    }

    return EmulatorStatus(
      definition: definition,
      isInstalled: label != null,
      installedLabel: label,
      grantedRoots: grantedRoots,
    );
  }
}
