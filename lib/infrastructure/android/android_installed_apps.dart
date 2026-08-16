import 'package:checkpoint/domain/platform/installed_app_port.dart';
import 'package:checkpoint/infrastructure/android/checkpoint_channel.dart';

/// [InstalledAppPort] backed by a scoped `PackageManager` lookup.
///
/// Only the identifiers passed in are queried, and they must also appear in the
/// manifest's `<queries>` block — Checkpoint never enumerates installed apps.
final class AndroidInstalledApps implements InstalledAppPort {
  const AndroidInstalledApps([this._channel = const CheckpointChannel()]);

  final CheckpointChannel _channel;

  @override
  Future<List<InstalledApp>> findInstalled(List<String> packageIds) async {
    if (packageIds.isEmpty) return const [];

    final raw = await _channel.invokeList<Object?>('findInstalledPackages', {
      'packageIds': packageIds,
    });

    final apps = <InstalledApp>[];
    for (final item in raw) {
      if (item is! Map<Object?, Object?>) continue;
      final packageId = item['packageId'];
      if (packageId is! String) continue;
      apps.add(
        InstalledApp(
          packageId: packageId,
          label: item['label'] as String? ?? packageId,
        ),
      );
    }
    return apps;
  }
}

/// Used on platforms with no notion of querying installed applications.
///
/// iOS has no equivalent API, so discovery there rests entirely on the user
/// picking folders — which is why detection is a hint in the UI and never a
/// precondition.
final class UnsupportedInstalledApps implements InstalledAppPort {
  const UnsupportedInstalledApps();

  @override
  Future<List<InstalledApp>> findInstalled(List<String> packageIds) async =>
      const [];
}
