/// Progress of a long-running operation, reported so the UI can show something
/// truthful instead of an indefinite spinner.
final class OperationProgress {
  const OperationProgress({
    required this.completed,
    required this.total,
    required this.label,
  });

  final int completed;
  final int total;

  /// What is happening right now, e.g. `Reading SAVE.BIN`.
  final String label;

  /// `null` when the total is not yet known, which the UI shows as an
  /// indeterminate bar rather than a misleading 0%.
  double? get fraction => total <= 0 ? null : (completed / total).clamp(0, 1);

  @override
  String toString() => '$label ($completed/$total)';
}

typedef ProgressCallback = void Function(OperationProgress progress);
