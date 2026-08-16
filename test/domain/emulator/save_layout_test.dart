import 'dart:convert';
import 'dart:typed_data';

import 'package:checkpoint/domain/emulator/save_layout.dart';
import 'package:checkpoint/domain/emulator/title_reader.dart';
import 'package:checkpoint/domain/storage/storage_root.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/in_memory_file_system.dart';

const root = StorageRoot(id: 'root://saves', displayName: 'SAVEDATA');

void main() {
  group('DirectoryPerGameLayout', () {
    final ppsspp = DirectoryPerGameLayout(
      id: 'ppsspp.savedata.v1',
      groupingSuffixes: const ['DATA00', 'PROFILE00'],
      idPattern: RegExp(r'^([A-Z]{4}\d{5})'),
      acceptUnmatchedDirectories: false,
    );

    test('groups a game\'s several save folders under one id', () async {
      final fs = InMemoryFileSystem()
        ..seedFile(root, 'ULUS10041DATA00/PARAM.SFO', [1, 2])
        ..seedFile(root, 'ULUS10041DATA00/SAVE.BIN', [1, 2, 3])
        ..seedFile(root, 'ULUS10041PROFILE00/SETTINGS.BIN', [4])
        ..seedFile(root, 'ULES00181DATA00/SAVE.BIN', [5]);

      final groups = await ppsspp.discover(fs, root);

      expect(groups.map((g) => g.gameId), ['ULES00181', 'ULUS10041']);
      final godOfWar = groups.firstWhere((g) => g.gameId == 'ULUS10041');
      expect(godOfWar.fileCount, 3);
      expect(godOfWar.totalBytes, 6);
      expect(
        godOfWar.files.map((f) => f.value),
        containsAll([
          'ULUS10041DATA00/PARAM.SFO',
          'ULUS10041DATA00/SAVE.BIN',
          'ULUS10041PROFILE00/SETTINGS.BIN',
        ]),
      );
    });

    test('ignores folders that do not match the id pattern', () async {
      final fs = InMemoryFileSystem()
        ..seedFile(root, 'ULUS10041DATA00/SAVE.BIN', [1])
        ..seedFile(root, 'RandomFolder/notes.txt', [1])
        ..seedFile(root, '.thumbnails/x.png', [1]);

      final groups = await ppsspp.discover(fs, root);
      expect(groups.map((g) => g.gameId), ['ULUS10041']);
    });

    test('an empty game folder produces no game', () async {
      final fs = InMemoryFileSystem()..seedDirectory(root, 'ULUS10041DATA00');
      expect(await ppsspp.discover(fs, root), isEmpty);
    });

    test('reports the newest modification across all folders', () async {
      final older = DateTime.utc(2026, 1, 1);
      final newer = DateTime.utc(2026, 6, 1);
      final fs = InMemoryFileSystem()
        ..seedFile(root, 'ULUS10041DATA00/A.BIN', [1], modifiedAt: older)
        ..seedFile(root, 'ULUS10041PROFILE00/B.BIN', [1], modifiedAt: newer);

      final groups = await ppsspp.discover(fs, root);
      expect(groups.single.modifiedAt, newer);
    });

    test('uses the title from PARAM.SFO when present', () async {
      final layout = DirectoryPerGameLayout(
        id: 'ppsspp.savedata.v1',
        groupingSuffixes: const ['DATA00'],
        idPattern: RegExp(r'^([A-Z]{4}\d{5})'),
        acceptUnmatchedDirectories: false,
        titleReader: const ParamSfoTitleReader(),
      );
      final fs = InMemoryFileSystem()
        ..seedFile(
          root,
          'ULUS10041DATA00/PARAM.SFO',
          buildParamSfo('God of War'),
        )
        ..seedFile(root, 'ULUS10041DATA00/SAVE.BIN', [1]);

      final groups = await layout.discover(fs, root);
      expect(groups.single.title, 'God of War');
      expect(groups.single.gameId, 'ULUS10041');
    });

    test('falls back to the game id when the title cannot be read', () async {
      final layout = DirectoryPerGameLayout(
        id: 'x',
        idPattern: RegExp(r'^([A-Z]{4}\d{5})'),
        acceptUnmatchedDirectories: false,
        titleReader: const ParamSfoTitleReader(),
      );
      final fs = InMemoryFileSystem()
        ..seedFile(root, 'ULUS10041/PARAM.SFO', [0, 0, 0, 0])
        ..seedFile(root, 'ULUS10041/SAVE.BIN', [1]);

      final groups = await layout.discover(fs, root);
      expect(groups.single.title, 'ULUS10041');
    });

    test('accepts any folder when no pattern is configured', () async {
      const layout = DirectoryPerGameLayout(id: 'generic');
      final fs = InMemoryFileSystem()
        ..seedFile(root, 'Some Game/save.bin', [1]);

      final groups = await layout.discover(fs, root);
      expect(groups.single.gameId, 'Some Game');
    });
  });

  group('FlatFilePerGameLayout', () {
    final retroArchSaves = FlatFilePerGameLayout(
      id: 'retroarch.saves.v1',
      extensionPattern: RegExp(r'^(srm|sav|rtc)$', caseSensitive: false),
    );
    final retroArchStates = FlatFilePerGameLayout(
      id: 'retroarch.states.v1',
      extensionPattern: RegExp(r'^(state\d*|auto|png)$', caseSensitive: false),
    );

    test('groups files by base name', () async {
      final fs = InMemoryFileSystem()
        ..seedFile(root, 'Chrono Trigger.srm', [1, 2])
        ..seedFile(root, 'Chrono Trigger.rtc', [3])
        ..seedFile(root, 'Super Metroid.srm', [4]);

      final groups = await retroArchSaves.discover(fs, root);
      expect(groups.map((g) => g.gameId), ['Chrono Trigger', 'Super Metroid']);
      expect(groups.first.fileCount, 2);
      expect(groups.first.totalBytes, 3);
    });

    test('strips stacked state extensions onto one game', () async {
      final fs = InMemoryFileSystem()
        ..seedFile(root, 'Zelda.state', [1])
        ..seedFile(root, 'Zelda.state1', [1])
        ..seedFile(root, 'Zelda.state2', [1])
        ..seedFile(root, 'Zelda.state.auto', [1])
        ..seedFile(root, 'Zelda.state1.png', [1]);

      final groups = await retroArchStates.discover(fs, root);
      expect(groups, hasLength(1));
      expect(groups.single.gameId, 'Zelda');
      expect(groups.single.fileCount, 5);
    });

    test('ignores files whose extension is not a save extension', () async {
      final fs = InMemoryFileSystem()
        ..seedFile(root, 'Chrono Trigger.srm', [1])
        ..seedFile(root, 'notes.txt', [1])
        ..seedFile(root, 'cover.jpg', [1])
        ..seedFile(root, 'no_extension', [1]);

      final groups = await retroArchSaves.discover(fs, root);
      expect(groups.map((g) => g.gameId), ['Chrono Trigger']);
    });

    test('keeps a dot in a game name that is not an extension', () async {
      final fs = InMemoryFileSystem()
        ..seedFile(root, 'Final Fantasy X-2.srm', [1])
        ..seedFile(root, 'Rev 1.2 Patch.srm', [1]);

      final groups = await retroArchSaves.discover(fs, root);
      expect(
        groups.map((g) => g.gameId),
        containsAll(['Final Fantasy X-2', 'Rev 1.2 Patch']),
      );
    });

    test('ignores directories and hidden files', () async {
      final fs = InMemoryFileSystem()
        ..seedFile(root, 'Zelda.srm', [1])
        ..seedFile(root, 'subfolder/Nested.srm', [1])
        ..seedFile(root, '.hidden.srm', [1]);

      final groups = await retroArchSaves.discover(fs, root);
      expect(groups.map((g) => g.gameId), ['Zelda']);
    });

    test('matches extensions case-insensitively', () async {
      final fs = InMemoryFileSystem()..seedFile(root, 'Zelda.SRM', [1]);
      final groups = await retroArchSaves.discover(fs, root);
      expect(groups.single.gameId, 'Zelda');
    });
  });
}

/// Builds a minimal but structurally valid `PARAM.SFO` carrying one `TITLE`.
List<int> buildParamSfo(String title) {
  const nul = 0;
  final key = [...utf8.encode('TITLE'), nul];
  final value = [...utf8.encode(title), nul];

  const headerSize = 0x14;
  const entrySize = 0x10;
  final keyTableOffset = headerSize + entrySize;
  final dataTableOffset = keyTableOffset + key.length;

  final bytes = BytesBuilder();
  final header = ByteData(headerSize);
  header.setUint32(0x00, 0x46535000, Endian.little); // "\0PSF"
  header.setUint32(0x04, 0x00000101, Endian.little); // version 1.1
  header.setUint32(0x08, keyTableOffset, Endian.little);
  header.setUint32(0x0C, dataTableOffset, Endian.little);
  header.setUint32(0x10, 1, Endian.little); // one entry
  bytes.add(header.buffer.asUint8List());

  final entry = ByteData(entrySize);
  entry.setUint16(0x00, 0, Endian.little); // key offset
  entry.setUint16(0x02, 0x0204, Endian.little); // UTF-8 with terminator
  entry.setUint32(0x04, value.length, Endian.little); // used length
  entry.setUint32(0x08, value.length, Endian.little); // total length
  entry.setUint32(0x0C, 0, Endian.little); // data offset
  bytes.add(entry.buffer.asUint8List());

  bytes.add(key);
  bytes.add(value);
  return bytes.toBytes();
}
