/// An application installed on the device.
final class InstalledApp {
  const InstalledApp({required this.packageId, required this.label});

  /// Platform application identifier, e.g. `org.ppsspp.ppsspp`.
  final String packageId;

  /// The name the OS shows for the app.
  final String label;

  @override
  String toString() => '$label ($packageId)';
}

/// Answers "is this specific application installed?".
///
/// Scoped by design: callers pass the exact identifiers they care about and get
/// back only those. Checkpoint never enumerates the user's installed apps, so
/// on Android it needs a `<queries>` manifest declaration rather than the
/// broad `QUERY_ALL_PACKAGES` permission.
///
/// Platforms that cannot answer this (iOS has no equivalent API) return an
/// empty list; discovery then falls back to the user picking a folder, which is
/// the path every platform supports.
abstract interface class InstalledAppPort {
  Future<List<InstalledApp>> findInstalled(List<String> packageIds);
}
