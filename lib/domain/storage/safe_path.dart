import 'package:checkpoint/core/failure.dart';
import 'package:checkpoint/core/result.dart';

/// A validated, relative, forward-slash-separated path.
///
/// This is the single chokepoint for path safety in Checkpoint. Both the
/// archive layer and the filesystem ports accept **only** a [SafePath], and a
/// [SafePath] can only be obtained through [parse], which rejects every form of
/// path that could escape its intended root.
///
/// The containment guarantee follows directly from the invariants below: a path
/// that is relative, contains no `..` segment and no empty segment cannot
/// resolve outside the directory it is joined to, no matter how it is joined.
/// That is why extraction code does not need a second "is it still inside?"
/// check — the type already proves it.
///
/// Rejected, with reasons:
///
/// * absolute paths (`/etc/passwd`), Windows drive paths (`C:\x`) and UNC paths
///   — they would ignore the destination root entirely;
/// * any `..` or `.` segment — classic traversal;
/// * empty segments (`a//b`, trailing `/`) — normalisation ambiguity;
/// * backslashes anywhere. A backslash is a legal filename character on POSIX
///   but a separator on Windows, so any interpretation is wrong somewhere. We
///   refuse rather than guess, which closes the "Windows separator smuggling"
///   family of bugs;
/// * control characters including NUL — truncation attacks against native APIs;
/// * segments ending in `.` or ` `, and segments made only of dots — Windows
///   silently strips these, so `evil. ` and `evil` can collide;
/// * Windows reserved device names (`CON`, `NUL`, `COM1`, ...) — opening them
///   has side effects rather than creating a file;
/// * oversized segments, paths and depths — defensive bounds.
///
/// Not attempted: Unicode confusables and case-folding collisions. Those are a
/// display concern rather than an escape vector, and the filesystem is the
/// authority on collisions.
final class SafePath {
  const SafePath._(this.segments, this.value);

  /// The individual path components, guaranteed non-empty and clean.
  final List<String> segments;

  /// The canonical `a/b/c` form.
  final String value;

  static const int maxSegmentLength = 255;
  static const int maxPathLength = 4096;
  static const int maxDepth = 64;

  static final RegExp _windowsDrive = RegExp(r'^[A-Za-z]:');
  static final RegExp _onlyDots = RegExp(r'^\.+$');
  static final RegExp _reservedDeviceName = RegExp(
    r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$',
    caseSensitive: false,
  );

  /// Validates [input] and returns a [SafePath], or a [ValidationFailure]
  /// naming the specific rule that was broken.
  static Result<SafePath> parse(String input) {
    Err<SafePath> reject(String why) => Err<SafePath>(
      ValidationFailure(message: 'Unsafe path rejected: $why', detail: input),
    );

    if (input.isEmpty) {
      return reject('the path is empty');
    }
    if (input.length > maxPathLength) {
      return reject('the path exceeds $maxPathLength characters');
    }
    if (input.contains(r'\')) {
      return reject('the path contains a backslash');
    }
    if (input.startsWith('/')) {
      return reject('the path is absolute');
    }
    if (_windowsDrive.hasMatch(input)) {
      return reject('the path names a drive letter');
    }

    final segments = input.split('/');
    if (segments.length > maxDepth) {
      return reject('the path is nested more than $maxDepth levels deep');
    }

    for (final segment in segments) {
      if (segment.isEmpty) {
        return reject('the path contains an empty component');
      }
      if (segment.length > maxSegmentLength) {
        return reject('a component exceeds $maxSegmentLength characters');
      }
      if (_onlyDots.hasMatch(segment)) {
        // Covers "." and ".." as well as "..." and longer runs.
        return reject('the path contains a "$segment" component');
      }
      if (segment.endsWith('.') || segment.endsWith(' ')) {
        return reject('a component ends with a dot or space');
      }
      if (segment.startsWith(' ')) {
        return reject('a component starts with a space');
      }
      for (final unit in segment.codeUnits) {
        if (unit <= 0x1F || unit == 0x7F) {
          return reject('a component contains a control character');
        }
      }
      final stem = segment.split('.').first;
      if (_reservedDeviceName.hasMatch(stem)) {
        return reject('a component is the reserved name "$stem"');
      }
    }

    return Ok(SafePath._(List.unmodifiable(segments), segments.join('/')));
  }

  /// Whether this path lies inside the directory named by [prefix].
  ///
  /// Segment-wise, so `files2/x` is correctly *not* inside `files`.
  bool isUnder(SafePath prefix) {
    if (prefix.segments.length >= segments.length) return false;
    for (var i = 0; i < prefix.segments.length; i++) {
      if (segments[i] != prefix.segments[i]) return false;
    }
    return true;
  }

  /// This path with the leading [prefix] removed.
  ///
  /// Throws [ArgumentError] when `!isUnder(prefix)`; callers are expected to
  /// have checked, so reaching this is a bug rather than bad input.
  SafePath relativeTo(SafePath prefix) {
    if (!isUnder(prefix)) {
      throw ArgumentError.value(value, 'this', 'is not under "${prefix.value}"');
    }
    final rest = segments.sublist(prefix.segments.length);
    return SafePath._(List.unmodifiable(rest), rest.join('/'));
  }

  /// This path with [child] appended.
  SafePath join(SafePath child) {
    final combined = [...segments, ...child.segments];
    return SafePath._(List.unmodifiable(combined), combined.join('/'));
  }

  /// The final component — the file or directory name.
  String get name => segments.last;

  /// The containing directory, or `null` for a single-segment path.
  SafePath? get parent {
    if (segments.length == 1) return null;
    final head = segments.sublist(0, segments.length - 1);
    return SafePath._(List.unmodifiable(head), head.join('/'));
  }

  @override
  bool operator ==(Object other) => other is SafePath && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}
