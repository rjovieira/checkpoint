import 'package:checkpoint/core/result.dart';
import 'package:checkpoint/domain/storage/safe_path.dart';
import 'package:flutter_test/flutter_test.dart';

/// [SafePath] is the single chokepoint that makes path traversal
/// unrepresentable, so these tests are the most security-critical in the suite.
void main() {
  group('SafePath.parse accepts', () {
    const valid = <String>[
      'a',
      'a/b',
      'a/b/c.txt',
      'ULUS10041DATA00/PARAM.SFO',
      'Legend of Zelda, The.srm',
      'files/savedata/x.bin',
      'name.with.many.dots.bin',
      // A leading dot is a hidden file, not a traversal.
      '.hidden',
      // "..foo" is a legitimate name; only a bare ".." is traversal.
      '..foo',
      'a-b_c+d(1)[2]{3}',
      'юникод/日本語.sav',
    ];

    for (final input in valid) {
      test('"$input"', () {
        final result = SafePath.parse(input);
        expect(result, isA<Ok<SafePath>>(), reason: '$input should be accepted');
        expect(result.valueOrNull!.value, input);
      });
    }
  });

  group('SafePath.parse rejects', () {
    const traversal = <String, String>{
      '..': 'bare parent',
      '../etc/passwd': 'leading parent',
      'a/../../etc/passwd': 'embedded parent',
      'a/..': 'trailing parent',
      '.': 'bare current',
      'a/./b': 'embedded current',
      '...': 'triple dot',
      'a/.../b': 'embedded triple dot',
    };
    const absolute = <String, String>{
      '/etc/passwd': 'posix absolute',
      '/': 'root',
      'C:/Windows/System32': 'drive letter',
      'c:relative': 'drive-relative',
      '//server/share': 'UNC',
    };
    const separators = <String, String>{
      r'a\b': 'backslash separator',
      r'..\..\etc': 'backslash traversal',
      r'C:\Windows': 'windows absolute',
      'a//b': 'empty component',
      'a/': 'trailing slash',
      '/a': 'leading slash',
    };
    const hostileNames = <String, String>{
      'CON': 'reserved device',
      'nul.txt': 'reserved device with extension',
      'COM1': 'reserved serial port',
      'LPT9.sav': 'reserved printer port',
      'trailing.': 'trailing dot',
      'foo..': 'trailing dots Windows would strip',
      'trailing ': 'trailing space',
      ' leading': 'leading space',
    };

    for (final cases in [traversal, absolute, separators, hostileNames]) {
      cases.forEach((input, why) {
        test('$why: "$input"', () {
          expect(
            SafePath.parse(input),
            isA<Err<SafePath>>(),
            reason: '$input ($why) must be rejected',
          );
        });
      });
    }

    test('empty string', () {
      expect(SafePath.parse(''), isA<Err<SafePath>>());
    });

    test('NUL byte', () {
      expect(
        SafePath.parse('evil${String.fromCharCode(0)}.txt'),
        isA<Err<SafePath>>(),
      );
    });

    test('other control characters', () {
      for (final code in [1, 9, 10, 13, 0x1F, 0x7F]) {
        expect(
          SafePath.parse('bad${String.fromCharCode(code)}name'),
          isA<Err<SafePath>>(),
          reason: 'control character 0x${code.toRadixString(16)}',
        );
      }
    });

    test('oversized component', () {
      final long = 'a' * (SafePath.maxSegmentLength + 1);
      expect(SafePath.parse(long), isA<Err<SafePath>>());
    });

    test('oversized path', () {
      final long = List.filled(50, 'a' * 100).join('/');
      expect(SafePath.parse(long), isA<Err<SafePath>>());
    });

    test('excessive depth', () {
      final deep = List.filled(SafePath.maxDepth + 1, 'a').join('/');
      expect(SafePath.parse(deep), isA<Err<SafePath>>());
    });

    test('failure explains which rule was broken', () {
      final failure = SafePath.parse('../x').failureOrNull!;
      expect(failure.message, contains('Unsafe path rejected'));
      expect(failure.detail, '../x');
    });
  });

  group('containment', () {
    SafePath of(String value) => SafePath.parse(value).valueOrNull!;

    test('isUnder is segment-wise, not string-prefix', () {
      expect(of('files/a').isUnder(of('files')), isTrue);
      expect(of('files/a/b').isUnder(of('files')), isTrue);
      // The classic prefix bug: "files2" must not count as inside "files".
      expect(of('files2/a').isUnder(of('files')), isFalse);
      expect(of('filesX').isUnder(of('files')), isFalse);
    });

    test('a path is not under itself', () {
      expect(of('files').isUnder(of('files')), isFalse);
    });

    test('relativeTo strips the prefix', () {
      expect(of('files/src/a.bin').relativeTo(of('files/src')).value, 'a.bin');
      expect(of('files/src/a/b').relativeTo(of('files')).value, 'src/a/b');
    });

    test('relativeTo rejects a non-prefix', () {
      expect(() => of('other/a').relativeTo(of('files')), throwsArgumentError);
    });

    test('join produces a still-safe path', () {
      final joined = of('files').join(of('savedata/a.bin'));
      expect(joined.value, 'files/savedata/a.bin');
      expect(joined.isUnder(of('files')), isTrue);
    });

    test('name and parent', () {
      expect(of('a/b/c.txt').name, 'c.txt');
      expect(of('a/b/c.txt').parent!.value, 'a/b');
      expect(of('a').parent, isNull);
    });
  });

  test('equality is by canonical value', () {
    final a = SafePath.parse('a/b').valueOrNull!;
    final b = SafePath.parse('a/b').valueOrNull!;
    expect(a, b);
    expect(a.hashCode, b.hashCode);
  });
}
