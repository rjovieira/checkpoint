/// The complete set of failures Checkpoint reports to the user.
///
/// Every failure carries a [message] written for a person, not a log file.
/// Technical detail belongs in [detail], which the UI may reveal on demand but
/// never shows by default.
sealed class Failure {
  const Failure({required this.message, this.detail});

  /// User-facing, actionable description of what went wrong.
  final String message;

  /// Optional technical detail (exception text, offending path, ...).
  final String? detail;

  @override
  String toString() => detail == null ? message : '$message ($detail)';
}

/// The user has not granted, or has revoked, access to a storage location.
final class PermissionFailure extends Failure {
  const PermissionFailure({required super.message, super.detail});
}

/// A filesystem or Storage Access Framework operation failed.
final class StorageFailure extends Failure {
  const StorageFailure({required super.message, super.detail});
}

/// A backup archive is malformed, unsafe, or of an unsupported version.
final class ArchiveFailure extends Failure {
  const ArchiveFailure({required super.message, super.detail});
}

/// Input did not satisfy a documented invariant.
final class ValidationFailure extends Failure {
  const ValidationFailure({required super.message, super.detail});
}

/// A requested entity does not exist.
final class NotFoundFailure extends Failure {
  const NotFoundFailure({required super.message, super.detail});
}

/// Something went wrong that Checkpoint has no specific handling for.
final class UnexpectedFailure extends Failure {
  const UnexpectedFailure({required super.message, super.detail});
}
