import 'dart:convert';
import 'dart:typed_data';

/// Extracts a human-readable game title from a metadata file that sits
/// alongside a game's saves.
///
/// Pure byte parsing with no I/O, so implementations are trivially testable and
/// work identically on every platform.
abstract interface class TitleReader {
  /// Name of the metadata file to look for inside a game's save directory.
  String get fileName;

  /// The title found in [bytes], or `null` if the file is absent, malformed, or
  /// simply carries no title. Implementations must not throw on malformed
  /// input — save files are untrusted data.
  String? parseTitle(Uint8List bytes);
}

/// Reads the game title out of a PSP `PARAM.SFO`.
///
/// SFO is a small key/value container:
///
/// ```text
/// 0x00 magic  "\0PSF"
/// 0x04 version
/// 0x08 uint32 offset of the key table
/// 0x0C uint32 offset of the data table
/// 0x10 uint32 number of entries
/// 0x14 entries[]: uint16 keyOffset, uint16 format, uint32 usedLen,
///                 uint32 totalLen, uint32 dataOffset
/// ```
///
/// Every offset in the file is attacker-controlled, so each one is
/// bounds-checked before use and any failure degrades to `null` rather than
/// throwing.
final class ParamSfoTitleReader implements TitleReader {
  const ParamSfoTitleReader();

  static const int _headerSize = 0x14;
  static const int _entrySize = 0x10;
  static const int _magic = 0x46535000; // "\0PSF" little-endian
  static const int _maxEntries = 1024;
  static const String _titleKey = 'TITLE';

  @override
  String get fileName => 'PARAM.SFO';

  @override
  String? parseTitle(Uint8List bytes) {
    if (bytes.length < _headerSize) return null;

    final data = ByteData.sublistView(bytes);
    if (data.getUint32(0x00, Endian.little) != _magic) return null;

    final keyTableOffset = data.getUint32(0x08, Endian.little);
    final dataTableOffset = data.getUint32(0x0C, Endian.little);
    final entryCount = data.getUint32(0x10, Endian.little);

    if (entryCount == 0 || entryCount > _maxEntries) return null;
    if (keyTableOffset > bytes.length || dataTableOffset > bytes.length) {
      return null;
    }
    if (_headerSize + entryCount * _entrySize > bytes.length) return null;

    for (var i = 0; i < entryCount; i++) {
      final entry = _headerSize + i * _entrySize;
      final keyOffset = keyTableOffset + data.getUint16(entry, Endian.little);
      final usedLength = data.getUint32(entry + 0x04, Endian.little);
      final dataOffset =
          dataTableOffset + data.getUint32(entry + 0x0C, Endian.little);

      if (_readNulTerminated(bytes, keyOffset) != _titleKey) continue;

      if (usedLength == 0 || dataOffset >= bytes.length) return null;
      final end = dataOffset + usedLength;
      if (end > bytes.length) return null;

      // `usedLength` covers the NUL terminator and any padding after it.
      final raw = bytes.sublist(dataOffset, end);
      final nul = raw.indexOf(0);
      final value = _decodeUtf8(nul == -1 ? raw : raw.sublist(0, nul));
      final title = value.trim();
      return title.isEmpty ? null : title;
    }
    return null;
  }

  static String? _readNulTerminated(Uint8List bytes, int start) {
    if (start >= bytes.length) return null;
    var end = start;
    while (end < bytes.length && bytes[end] != 0) {
      end++;
    }
    return _decodeUtf8(bytes.sublist(start, end));
  }

  static String _decodeUtf8(Uint8List bytes) =>
      const Utf8Decoder(allowMalformed: true).convert(bytes);
}
