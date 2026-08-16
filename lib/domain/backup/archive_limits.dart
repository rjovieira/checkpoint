/// Bounds applied when reading a backup archive.
///
/// A backup file is untrusted input — it may have been downloaded, shared, or
/// deliberately crafted. Without bounds, a small archive can declare enormous
/// contents and exhaust memory or storage on extraction (a "zip bomb"). These
/// limits are checked against each entry's *declared* size before anything is
/// decompressed, and again against the real size afterwards.
final class ArchiveLimits {
  const ArchiveLimits({
    this.maxEntries = 20000,
    this.maxFileBytes = 256 * 1024 * 1024,
    this.maxTotalBytes = 1024 * 1024 * 1024,
    this.maxArchiveBytes = 512 * 1024 * 1024,
  });

  /// Generous enough for any real save folder; small enough that a
  /// million-entry archive is refused immediately.
  final int maxEntries;

  /// Largest single file that may be extracted.
  final int maxFileBytes;

  /// Largest total uncompressed payload.
  final int maxTotalBytes;

  /// Largest archive Checkpoint will read into memory at all.
  final int maxArchiveBytes;

  static const ArchiveLimits standard = ArchiveLimits();
}
