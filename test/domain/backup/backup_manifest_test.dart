import 'dart:convert';

import 'package:checkpoint/core/result.dart';
import 'package:checkpoint/domain/backup/backup_manifest.dart';
import 'package:checkpoint/domain/emulator/save_kind.dart';
import 'package:checkpoint/domain/storage/safe_path.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  BackupManifest sample() => BackupManifest(
    formatVersion: BackupManifest.currentFormatVersion,
    appVersion: '0.1.0',
    backupId: 'checkpoint__ppsspp__ULUS10041__20260816-120000.zip',
    createdAt: DateTime.utc(2026, 8, 16, 12),
    emulatorId: 'ppsspp',
    emulatorName: 'PPSSPP',
    gameId: 'ULUS10041',
    gameTitle: 'God of War: Chains of Olympus',
    sources: const [
      BackupSource(
        id: 'savedata',
        label: 'PSP save data folder',
        kind: SaveKind.saveData,
        layoutId: 'ppsspp.savedata.v1',
        originDisplayPath: 'Internal storage/PSP/SAVEDATA',
      ),
      BackupSource(
        id: 'states',
        label: 'PSP save state folder',
        kind: SaveKind.saveState,
        layoutId: 'ppsspp.states.v1',
      ),
    ],
    files: [
      BackupFileEntry(
        sourceId: 'savedata',
        path: SafePath.parse('ULUS10041DATA00/SAVE.BIN').valueOrNull!,
        sizeBytes: 128,
        sha256: 'abc123',
      ),
      BackupFileEntry(
        sourceId: 'states',
        path: SafePath.parse('ULUS10041_1.00_0.ppst').valueOrNull!,
        sizeBytes: 64,
        sha256: 'def456',
      ),
    ],
  );

  group('round trip', () {
    test('survives encode and decode unchanged', () {
      final decoded = BackupManifest.decode(sample().encode()).valueOrNull!;

      expect(decoded.formatVersion, BackupManifest.currentFormatVersion);
      expect(decoded.appVersion, '0.1.0');
      expect(decoded.gameId, 'ULUS10041');
      expect(decoded.gameTitle, 'God of War: Chains of Olympus');
      expect(decoded.emulatorId, 'ppsspp');
      expect(decoded.createdAt, DateTime.utc(2026, 8, 16, 12));
      expect(decoded.createdAt.isUtc, isTrue);
      expect(decoded.sources.map((s) => s.id), ['savedata', 'states']);
      expect(decoded.files, hasLength(2));
      expect(decoded.totalBytes, 192);
      expect(decoded.containsSaveData, isTrue);
      expect(decoded.containsSaveStates, isTrue);
    });

    test('preserves the kind of each source', () {
      final decoded = BackupManifest.decode(sample().encode()).valueOrNull!;
      expect(decoded.sourceById('savedata')!.kind, SaveKind.saveData);
      expect(decoded.sourceById('states')!.kind, SaveKind.saveState);
    });

    test('archive entry paths are derived, not stored', () {
      final entry = sample().files.first;
      expect(entry.archiveEntryPath, 'files/savedata/ULUS10041DATA00/SAVE.BIN');
    });
  });

  group('version gating', () {
    Result<BackupManifest> decodeWith(Map<String, Object?> overrides) {
      final json = sample().toJson()..addAll(overrides);
      return BackupManifest.fromJson(json);
    }

    test('refuses a manifest from a newer Checkpoint', () {
      final result = decodeWith({
        'formatVersion': BackupManifest.currentFormatVersion + 1,
      });
      expect(result, isA<Err<BackupManifest>>());
      expect(result.failureOrNull!.message, contains('newer version'));
    });

    test('refuses a manifest older than the supported floor', () {
      final result = decodeWith({
        'formatVersion': BackupManifest.minimumSupportedFormatVersion - 1,
      });
      expect(result, isA<Err<BackupManifest>>());
      expect(result.failureOrNull!.message, contains('no longer supports'));
    });

    test('refuses a manifest with no version at all', () {
      final json = sample().toJson()..remove('formatVersion');
      final result = BackupManifest.fromJson(json);
      expect(result.failureOrNull!.message, contains('format version'));
    });
  });

  group('rejects malformed input', () {
    test('bytes that are not JSON', () {
      final result = BackupManifest.decode(utf8.encode('not json at all'));
      expect(result, isA<Err<BackupManifest>>());
    });

    test('JSON that is not an object', () {
      final result = BackupManifest.decode(utf8.encode('[1, 2, 3]'));
      expect(result, isA<Err<BackupManifest>>());
    });

    test('a missing game section', () {
      final json = sample().toJson()..remove('game');
      expect(
        BackupManifest.fromJson(json).failureOrNull!.message,
        contains('which game'),
      );
    });

    test('an unparseable timestamp', () {
      final json = sample().toJson()..['createdAt'] = 'not a date';
      expect(
        BackupManifest.fromJson(json).failureOrNull!.message,
        contains('creation time'),
      );
    });

    test('a file entry with a negative size', () {
      final json = sample().toJson();
      ((json['files']! as List).first as Map<String, Object?>)['sizeBytes'] =
          -1;
      expect(
        BackupManifest.fromJson(json).failureOrNull!.message,
        contains('negative'),
      );
    });

    test('a file referring to an undeclared source', () {
      final json = sample().toJson();
      ((json['files']! as List).first as Map<String, Object?>)['sourceId'] =
          'nonexistent';
      expect(
        BackupManifest.fromJson(json).failureOrNull!.message,
        contains('does not describe'),
      );
    });

    test('a source id that is a path rather than a name', () {
      final json = sample().toJson();
      ((json['sources']! as List).first as Map<String, Object?>)['id'] = 'a/b';
      expect(
        BackupManifest.fromJson(json).failureOrNull!.message,
        contains('unsafe source'),
      );
    });

    test('a file path containing traversal', () {
      final json = sample().toJson();
      ((json['files']! as List).first as Map<String, Object?>)['path'] =
          '../../etc/passwd';
      expect(
        BackupManifest.fromJson(json).failureOrNull!.message,
        contains('unsafe file path'),
      );
    });
  });

  test('checksums are normalised to lowercase', () {
    final json = sample().toJson();
    ((json['files']! as List).first as Map<String, Object?>)['sha256'] =
        'ABC123';
    final decoded = BackupManifest.fromJson(json).valueOrNull!;
    expect(decoded.files.first.sha256, 'abc123');
  });
}
