import 'package:checkpoint/domain/storage/directory_picker_port.dart';
import 'package:checkpoint/domain/storage/file_system_port.dart';
import 'package:checkpoint/domain/storage/storage_root.dart';
import 'package:checkpoint/infrastructure/android/checkpoint_channel.dart';

/// [DirectoryPickerPort] backed by `ACTION_OPEN_DOCUMENT_TREE`.
final class SafDirectoryPicker implements DirectoryPickerPort {
  const SafDirectoryPicker([this._channel = const CheckpointChannel()]);

  final CheckpointChannel _channel;

  @override
  Future<StorageRoot?> pickDirectory({
    String? initialLocationHint,
    String? promptTitle,
  }) async {
    final result = await _channel.invoke<Map<Object?, Object?>>(
      'pickDirectory',
      {
        if (initialLocationHint != null)
          'initialLocationHint': androidInitialUri(initialLocationHint),
      },
    );
    if (result == null) return null;

    final rootId = result['rootId'];
    if (rootId is! String) {
      throw const StorageException(
        'The folder picker returned nothing usable.',
      );
    }
    return StorageRoot(
      id: rootId,
      displayName: result['displayName'] as String? ?? 'Selected folder',
      displayPath: result['displayPath'] as String?,
    );
  }

  @override
  Future<void> releaseRoot(StorageRoot root) async {
    await _channel.invoke<void>('releaseRoot', {'rootId': root.id});
  }

  /// Builds the document URI that opens the picker at [relativePath] on primary
  /// shared storage, e.g. `PSP/SAVEDATA`.
  ///
  /// Only a hint: if the path does not exist, or the OEM's picker ignores it,
  /// the user simply starts from the default location.
  static String androidInitialUri(String relativePath) {
    final encoded = Uri.encodeComponent('primary:$relativePath');
    return 'content://com.android.externalstorage.documents/document/$encoded';
  }
}
