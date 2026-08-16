import 'package:checkpoint/domain/storage/storage_root.dart';

/// Asks the user to grant access to a directory.
///
/// This is deliberately the *only* way Checkpoint obtains storage access. There
/// is no "scan the whole filesystem" entry point, because that would require
/// broad permissions the app does not request.
abstract interface class DirectoryPickerPort {
  /// Presents the system directory picker and returns the granted root, or
  /// `null` if the user cancelled.
  ///
  /// [initialLocationHint] is an optional platform-specific hint (on Android, a
  /// document URI) used to open the picker near the expected folder. It is a
  /// convenience only — the user remains free to pick anywhere, and the app
  /// must work if they do.
  ///
  /// The grant is persisted by the implementation so it survives restarts.
  Future<StorageRoot?> pickDirectory({
    String? initialLocationHint,
    String? promptTitle,
  });

  /// Drops a previously persisted grant. Called when the user removes a folder
  /// so Checkpoint does not hold access it no longer needs.
  Future<void> releaseRoot(StorageRoot root);
}
