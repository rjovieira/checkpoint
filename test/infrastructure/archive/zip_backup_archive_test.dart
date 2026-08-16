import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:checkpoint/core/result.dart';
import 'package:checkpoint/domain/backup/archive_limits.dart';
import 'package:checkpoint/domain/backup/backup_archive_port.dart';
import 'package:checkpoint/domain/backup/backup_manifest.dart';
import 'package:checkpoint/domain/emulator/save_kind.dart';
import 'package:checkpoint/domain/storage/safe_path.dart';
import 'package:checkpoint/infrastructure/archive/zip_backup_archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

/// These tests build hostile archives by hand and assert Checkpoint refuses
/// them. They are the guarantee that a malicious backup file cannot write
/// outside the folder the user chose.
void main() {
  const archive = ZipBackupArchive();

  group('round trip', () {
    test('packs and unpacks a backup unchanged', () {
      final payload = Uint8List.fromList(utf8.encode('save game bytes'));
      final manifest = _manifest([_entry('savedata', 'GAME/DATA.BIN', payload)]);

      final bytes = archive.pack(
        manifest: manifest,
        contents: {'files/savedata/GAME/DATA.BIN': payload},
      );

      final result = archive.unpack(bytes);
      expect(result, isA<Ok<List<ExtractedBackupFile>>>());

      final files = result.valueOrNull!;
      expect(files, hasLength(1));
      expect(files.single.sourceId, 'savedata');
      expect(files.single.path.value, 'GAME/DATA.BIN');
      expect(files.single.bytes, payload);
    });

    test('readManifest does not need the payload', () {
      final payload = Uint8List.fromList([1, 2, 3]);
      final manifest = _manifest([_entry('savedata', 'a.bin', payload)]);
      final bytes = archive.pack(
        manifest: manifest,
        contents: {'files/savedata/a.bin': payload},
      );

      final read = archive.readManifest(bytes).valueOrNull!;
      expect(read.gameTitle, 'Test Game');
      expect(read.emulatorId, 'ppsspp');
      expect(read.formatVersion, BackupManifest.currentFormatVersion);
      expect(read.containsSaveData, isTrue);
    });

    test('pack refuses a manifest it cannot satisfy', () {
      final manifest = _manifest([
        _entry('savedata', 'a.bin', Uint8List.fromList([1])),
      ]);
      expect(
        () => archive.pack(manifest: manifest, contents: const {}),
        throwsStateError,
      );
    });
  });

  group('rejects malicious archives', () {
    test('path traversal in a manifest entry', () {
      final bytes = _handBuilt(
        manifestJson: _rawManifest(
          files: [
            {
              'sourceId': 'savedata',
              'path': '../../../../data/data/com.bank/databases/accounts.db',
              'sizeBytes': 4,
              'sha256': _sha([1, 2, 3, 4]),
            },
          ],
        ),
        entries: {'files/savedata/x': const [1, 2, 3, 4]},
      );

      final result = archive.unpack(bytes);
      expect(result, isA<Err<List<ExtractedBackupFile>>>());
      expect(result.failureOrNull!.message, contains('unsafe file path'));
    });

    test('absolute path in a manifest entry', () {
      final bytes = _handBuilt(
        manifestJson: _rawManifest(
          files: [
            {
              'sourceId': 'savedata',
              'path': '/data/local/tmp/payload.so',
              'sizeBytes': 1,
              'sha256': _sha([0]),
            },
          ],
        ),
        entries: const {},
      );
      expect(archive.unpack(bytes), isA<Err<List<ExtractedBackupFile>>>());
    });

    test('traversal in the source id', () {
      final bytes = _handBuilt(
        manifestJson: _rawManifest(
          sources: [
            {
              'id': '../..',
              'label': 'evil',
              'kind': 'saveData',
              'layoutId': 'x',
            },
          ],
          files: [
            {
              'sourceId': '../..',
              'path': 'a.bin',
              'sizeBytes': 1,
              'sha256': _sha([0]),
            },
          ],
        ),
        entries: const {},
      );
      final result = archive.unpack(bytes);
      expect(result, isA<Err<List<ExtractedBackupFile>>>());
      expect(result.failureOrNull!.message, contains('unsafe source'));
    });

    test('a symbolic link entry', () {
      final payload = Uint8List.fromList([1, 2, 3, 4]);
      final manifest = _manifest([_entry('savedata', 'a.bin', payload)]);

      // A symlink whose target is an absolute path outside the restore
      // destination: extracting it and then following it is the classic way to
      // turn a contained extraction into an arbitrary write.
      final link = ArchiveFile.bytes(
        'files/savedata/link',
        utf8.encode('/data/data/com.example.bank'),
      )..mode = _unixSymlinkMode;

      final raw = Archive()
        ..add(ArchiveFile.bytes(BackupManifest.fileName, manifest.encode()))
        ..add(ArchiveFile.bytes('files/savedata/a.bin', payload))
        ..add(link);

      final result = archive.unpack(_asUnixZip(ZipEncoder().encodeBytes(raw)));
      expect(result, isA<Err<List<ExtractedBackupFile>>>());
      expect(result.failureOrNull!.message, contains('symbolic link'));
    });

    test('undeclared entries are never extracted', () {
      final payload = Uint8List.fromList([1, 2, 3, 4]);
      final manifest = _manifest([_entry('savedata', 'a.bin', payload)]);
      final raw = Archive()
        ..add(ArchiveFile.bytes(BackupManifest.fileName, manifest.encode()))
        ..add(ArchiveFile.bytes('files/savedata/a.bin', payload))
        // Smuggled: present in the ZIP but absent from the manifest.
        ..add(ArchiveFile.bytes('files/savedata/backdoor.sh', [0x23, 0x21]))
        ..add(ArchiveFile.bytes('unrelated/elsewhere.bin', [0xFF]));

      final files = archive.unpack(ZipEncoder().encodeBytes(raw)).valueOrNull!;
      expect(files, hasLength(1));
      expect(files.single.path.value, 'a.bin');
    });

    test('tampered content fails its checksum', () {
      final payload = Uint8List.fromList(utf8.encode('original'));
      final manifest = _manifest([_entry('savedata', 'a.bin', payload)]);
      final tampered = Uint8List.fromList(utf8.encode('tampered'));

      final raw = Archive()
        ..add(ArchiveFile.bytes(BackupManifest.fileName, manifest.encode()))
        ..add(ArchiveFile.bytes('files/savedata/a.bin', tampered));

      final result = archive.unpack(ZipEncoder().encodeBytes(raw));
      expect(result, isA<Err<List<ExtractedBackupFile>>>());
      expect(result.failureOrNull!.message, contains('integrity check'));
    });

    test('declared size that disagrees with reality', () {
      final payload = Uint8List.fromList([1, 2, 3, 4]);
      final bytes = _handBuilt(
        manifestJson: _rawManifest(
          files: [
            {
              'sourceId': 'savedata',
              'path': 'a.bin',
              'sizeBytes': 999,
              'sha256': _sha(payload),
            },
          ],
        ),
        entries: {'files/savedata/a.bin': payload},
      );
      final result = archive.unpack(bytes);
      expect(result, isA<Err<List<ExtractedBackupFile>>>());
      expect(result.failureOrNull!.message, contains('modified'));
    });

    test('a file the manifest promises but the archive omits', () {
      final bytes = _handBuilt(
        manifestJson: _rawManifest(
          files: [
            {
              'sourceId': 'savedata',
              'path': 'missing.bin',
              'sizeBytes': 1,
              'sha256': _sha([0]),
            },
          ],
        ),
        entries: const {},
      );
      final result = archive.unpack(bytes);
      expect(result.failureOrNull!.message, contains('incomplete'));
    });

    test('an archive with no manifest at all', () {
      final raw = Archive()..add(ArchiveFile.bytes('random.txt', [1, 2, 3]));
      final result = archive.unpack(ZipEncoder().encodeBytes(raw));
      expect(result.failureOrNull!.message, contains('not a Checkpoint backup'));
    });

    test('a file that is not a ZIP', () {
      final result = archive.unpack(
        Uint8List.fromList(utf8.encode('this is not a zip file at all')),
      );
      expect(result, isA<Err<List<ExtractedBackupFile>>>());
    });
  });

  group('resource limits', () {
    test('rejects an oversized archive before decoding it', () {
      const tiny = ZipBackupArchive(
        limits: ArchiveLimits(maxArchiveBytes: 10),
      );
      final result = tiny.unpack(Uint8List(64));
      expect(result.failureOrNull!.message, contains('too large to open'));
    });

    test('rejects an entry larger than the per-file limit', () {
      final payload = Uint8List(2048);
      final manifest = _manifest([_entry('savedata', 'big.bin', payload)]);
      final bytes = archive.pack(
        manifest: manifest,
        contents: {'files/savedata/big.bin': payload},
      );

      const bounded = ZipBackupArchive(
        limits: ArchiveLimits(maxFileBytes: 1024),
      );
      expect(
        bounded.unpack(bytes).failureOrNull!.message,
        contains('too large to restore'),
      );
    });

    test('rejects a payload larger than the total limit', () {
      final a = Uint8List(600);
      final b = Uint8List(600);
      final manifest = _manifest([
        _entry('savedata', 'a.bin', a),
        _entry('savedata', 'b.bin', b),
      ]);
      final bytes = archive.pack(
        manifest: manifest,
        contents: {'files/savedata/a.bin': a, 'files/savedata/b.bin': b},
      );

      const bounded = ZipBackupArchive(
        limits: ArchiveLimits(maxTotalBytes: 1000),
      );
      expect(
        bounded.unpack(bytes).failureOrNull!.message,
        contains('too large to restore'),
      );
    });

    test('rejects an archive with too many entries', () {
      final raw = Archive()
        ..add(ArchiveFile.bytes(BackupManifest.fileName, utf8.encode('{}')));
      for (var i = 0; i < 20; i++) {
        raw.add(ArchiveFile.bytes('files/savedata/$i.bin', [i]));
      }
      const bounded = ZipBackupArchive(
        limits: ArchiveLimits(maxEntries: 5),
      );
      expect(
        bounded.unpack(ZipEncoder().encodeBytes(raw)).failureOrNull!.message,
        contains('too many files'),
      );
    });
  });
}

// ── helpers ────────────────────────────────────────────────────────────────

/// `S_IFLNK | 0777` — the UNIX mode bits that mark a ZIP entry as a symlink.
const int _unixSymlinkMode = 0xA1FF;

/// Rewrites a ZIP's central directory to claim it was produced on UNIX.
///
/// `ZipEncoder` always stamps `versionMadeBy` as MS-DOS, and the decoder only
/// honours symlink mode bits for UNIX-made archives — so an archive built
/// purely with the package's own encoder can never *be* a symlink archive.
/// Real malicious archives are made on UNIX, so the test fixture patches the
/// high byte of `versionMadeBy` (offset 5 of each central directory header) to
/// 3 to reproduce one faithfully.
Uint8List _asUnixZip(Uint8List zip) {
  const centralDirectorySignature = 0x02014b50;
  const unixOs = 3;
  final patched = Uint8List.fromList(zip);
  final view = ByteData.sublistView(patched);

  for (var i = 0; i + 4 <= patched.length; i++) {
    if (view.getUint32(i, Endian.little) == centralDirectorySignature) {
      patched[i + 5] = unixOs;
    }
  }
  return patched;
}

String _sha(List<int> bytes) => sha256.convert(bytes).toString();

BackupFileEntry _entry(String sourceId, String path, Uint8List bytes) =>
    BackupFileEntry(
      sourceId: sourceId,
      path: SafePath.parse(path).valueOrNull!,
      sizeBytes: bytes.length,
      sha256: _sha(bytes),
    );

BackupManifest _manifest(List<BackupFileEntry> files) => BackupManifest(
  formatVersion: BackupManifest.currentFormatVersion,
  appVersion: '0.1.0',
  backupId: 'test-backup',
  createdAt: DateTime.utc(2026, 1, 2, 3, 4, 5),
  emulatorId: 'ppsspp',
  emulatorName: 'PPSSPP',
  gameId: 'ULUS10041',
  gameTitle: 'Test Game',
  sources: const [
    BackupSource(
      id: 'savedata',
      label: 'PSP save data folder',
      kind: SaveKind.saveData,
      layoutId: 'ppsspp.savedata.v1',
      originDisplayPath: 'Internal storage/PSP/SAVEDATA',
    ),
  ],
  files: files,
);

/// A manifest document built as raw JSON, so tests can express shapes the
/// typed API would refuse to produce.
List<int> _rawManifest({
  List<Map<String, Object?>>? sources,
  required List<Map<String, Object?>> files,
}) => utf8.encode(
  jsonEncode({
    'formatVersion': BackupManifest.currentFormatVersion,
    'appVersion': '0.1.0',
    'backupId': 'test',
    'createdAt': '2026-01-02T03:04:05.000Z',
    'emulator': {'id': 'ppsspp', 'name': 'PPSSPP'},
    'game': {'id': 'ULUS10041', 'title': 'Test Game'},
    'sources':
        sources ??
        [
          {
            'id': 'savedata',
            'label': 'PSP save data folder',
            'kind': 'saveData',
            'layoutId': 'ppsspp.savedata.v1',
          },
        ],
    'files': files,
  }),
);

Uint8List _handBuilt({
  required List<int> manifestJson,
  required Map<String, List<int>> entries,
}) {
  final raw = Archive()
    ..add(ArchiveFile.bytes(BackupManifest.fileName, manifestJson));
  entries.forEach((name, bytes) {
    raw.add(ArchiveFile.bytes(name, bytes));
  });
  return ZipEncoder().encodeBytes(raw);
}
