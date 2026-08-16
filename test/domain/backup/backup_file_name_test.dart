import 'package:checkpoint/core/result.dart';
import 'package:checkpoint/domain/backup/backup_file_name.dart';
import 'package:checkpoint/domain/storage/safe_path.dart';
import 'package:flutter_test/flutter_test.dart';

/// Game ids come from folder and ROM names, so they can contain anything a
/// filesystem allows. The slug rules exist so that a name can never produce a
/// filename that [SafePath] would then refuse.
void main() {
  group('slug', () {
    const cases = <String, String>{
      'ULUS10041': 'ULUS10041',
      'Chrono Trigger': 'Chrono_Trigger',
      'Legend of Zelda, The': 'Legend_of_Zelda_The',
      'a/b/../c': 'a_b_.._c',
      '../../etc/passwd': 'etc_passwd',
      r'C:\Windows': 'C_Windows',
      'trailing.': 'trailing',
      '  spaced  ': 'spaced',
      'CON': 'CON',
      'many___underscores': 'many_underscores',
    };

    cases.forEach((input, expected) {
      test('"$input" becomes "$expected"', () {
        expect(BackupFileName.slug(input), expected);
      });
    });

    test('a name that slugs away entirely gets a fallback', () {
      expect(BackupFileName.slug('///'), 'game');
      expect(BackupFileName.slug(''), 'game');
      expect(BackupFileName.slug('...'), 'game');
    });

    test('long names are truncated', () {
      expect(BackupFileName.slug('x' * 500).length, lessThanOrEqualTo(64));
    });

    test('the separator can never appear inside a field', () {
      // Runs of underscores collapse, so "__" cannot survive slugging and
      // parsing stays unambiguous.
      expect(BackupFileName.slug('a__b'), isNot(contains('__')));
      expect(BackupFileName.slug('a  b'), isNot(contains('__')));
    });
  });

  group('filenames', () {
    test('round trips through parsing', () {
      final name = BackupFileName.forGame(
        emulatorId: 'ppsspp',
        gameId: 'ULUS10041',
        createdAt: DateTime.utc(2026, 8, 16, 12, 30, 45),
      );
      expect(name.value, 'checkpoint__ppsspp__ULUS10041__20260816-123045.zip');

      final parsed = BackupFileName.tryParse(name.value)!;
      expect(parsed.emulatorId, 'ppsspp');
      expect(parsed.gameSlug, 'ULUS10041');
      expect(parsed.createdAt, DateTime.utc(2026, 8, 16, 12, 30, 45));
    });

    test('timestamps are stored in UTC regardless of input', () {
      final local = DateTime(2026, 8, 16, 12).toLocal();
      final name = BackupFileName.forGame(
        emulatorId: 'mgba',
        gameId: 'Zelda',
        createdAt: local,
      );
      expect(BackupFileName.tryParse(name.value)!.createdAt.isUtc, isTrue);
    });

    test('a generated name is always a valid safe path', () {
      const hostile = [
        '../../etc/passwd',
        r'C:\Windows\System32',
        'CON',
        'name with spaces and, commas',
        'ULUS10041',
      ];
      for (final gameId in hostile) {
        final name = BackupFileName.forGame(
          emulatorId: 'retroarch',
          gameId: gameId,
          createdAt: DateTime.utc(2026),
        );
        expect(
          SafePath.parse(name.value),
          isA<Ok<SafePath>>(),
          reason: 'generated name for "$gameId" must be safe',
        );
        expect(() => name.toSafePath(), returnsNormally);
      }
    });

    test('rejects names that are not Checkpoint backups', () {
      const notOurs = [
        'holiday.jpg',
        'Backup_Profile_20260816.zip',
        'checkpoint__ppsspp__ULUS10041.zip',
        'checkpoint__ppsspp__ULUS10041__nonsense.zip',
        'prefix__ppsspp__game__20260816-120000.zip',
        'checkpoint__ppsspp__ULUS10041__20260816-120000.txt',
      ];
      for (final name in notOurs) {
        expect(
          BackupFileName.tryParse(name),
          isNull,
          reason: '"$name" is not a Checkpoint backup',
        );
      }
    });
  });
}
