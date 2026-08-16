import 'package:checkpoint/domain/storage/file_system_port.dart';
import 'package:flutter/services.dart';

/// Thin wrapper over the Android platform channel.
///
/// Its only jobs are to name the channel in one place and to turn platform
/// error codes into the exception types the domain declares, so no other file
/// has to know that `PlatformException(code: 'access_denied')` is a thing.
final class CheckpointChannel {
  const CheckpointChannel([
    this.channel = const MethodChannel('dev.checkpoint/storage'),
  ]);

  final MethodChannel channel;

  static const String accessDenied = 'access_denied';
  static const String notFound = 'not_found';

  Future<T?> invoke<T>(String method, [Map<String, Object?>? arguments]) async {
    try {
      return await channel.invokeMethod<T>(method, arguments);
    } on PlatformException catch (e) {
      throw _translate(e);
    } on MissingPluginException catch (e) {
      throw StorageException(
        'This feature is not available on this platform yet.',
        e.message,
      );
    }
  }

  Future<List<T>> invokeList<T>(
    String method, [
    Map<String, Object?>? arguments,
  ]) async {
    try {
      final result = await channel.invokeListMethod<T>(method, arguments);
      return result ?? const [];
    } on PlatformException catch (e) {
      throw _translate(e);
    } on MissingPluginException catch (e) {
      throw StorageException(
        'This feature is not available on this platform yet.',
        e.message,
      );
    }
  }

  StorageException _translate(PlatformException e) => switch (e.code) {
    accessDenied => StorageAccessDeniedException(
      e.message ?? 'Access to this folder was denied.',
      e.details?.toString(),
    ),
    notFound => StorageException(
      e.message ?? 'The file or folder no longer exists.',
      e.details?.toString(),
    ),
    _ => StorageException(
      e.message ?? 'A storage operation failed.',
      e.details?.toString(),
    ),
  };
}
