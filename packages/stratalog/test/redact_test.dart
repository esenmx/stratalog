import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:stratalog/redact.dart';
import 'package:test/test.dart';

final class _BrokenToString {
  @override
  String toString() => throw StateError('unprintable');
}

void main() {
  group('normalizeRedactKey and isRedactedKey', () {
    test('normalizes case, separators, and list-index brackets', () {
      final keys = {normalizeRedactKey('filter[new_password]')};
      check(isRedactedKey('filter[newPassword]', keys)).isTrue();
      check(isRedactedKey('filter[0][new-password]', keys)).isTrue();
      check(isRedactedKey('filter[][NEW_PASSWORD]', keys)).isTrue();
      check(isRedactedKey('outer[filter][2][new_password]', keys)).isTrue();
      check(isRedactedKey('filter[username]', keys)).isFalse();
    });

    test('matches any bracketed segment against plain redact keys', () {
      check(isRedactedKey('auth[access_token]', defaultRedactKeys)).isTrue();
      check(isRedactedKey('users[0][password]', defaultRedactKeys)).isTrue();
      check(isRedactedKey('users[0][handle]', defaultRedactKeys)).isFalse();
    });
  });

  group('redactData', () {
    test('bounds recursion depth instead of overflowing stack', () {
      Object nested = <String, Object?>{'password': 'secret'};
      for (var i = 0; i < 80; i++) {
        nested = <String, Object?>{'child': nested};
      }
      final out = redactData(nested, defaultRedactKeys, maxDepth: 8);
      check('$out')
        ..contains('<max depth>')
        ..not((it) => it.contains('secret'));
    });

    test('handles cycles, TypedData, and bracketed paths', () {
      final cycle = <String, Object?>{'ok': 1};
      cycle['self'] = cycle;
      final out = redactData(
        {
          'filter': [
            {'ssn': 'secret-ssn', 'name': 'Ada'},
          ],
          'bytes': Uint8List.fromList([1, 2, 3]),
          'cycle': cycle,
        },
        {normalizeRedactKey('filter[ssn]')},
      );
      check(out).isA<Map<String, Object?>>().deepEquals({
        'filter': [
          {'ssn': '***', 'name': 'Ada'},
        ],
        'bytes': '<3-byte body>',
        'cycle': {'ok': 1, 'self': '<cycle>'},
      });
    });
  });

  group('redactUri and scrubErrorLine', () {
    test('redacts userinfo and indexed query keys', () {
      final uri = Uri.parse(
        'https://user:pass@example.com/search?filter%5B0%5D%5Bssn%5D=123&page=2',
      );
      final safe = redactUri(uri, {normalizeRedactKey('filter[ssn]')});
      check('$safe')
        ..contains('https://***@example.com/search?')
        ..contains('filter%5B0%5D%5Bssn%5D=***')
        ..contains('page=2')
        ..not((it) => it.contains('user:pass'))
        ..not((it) => it.contains('=123'));
      final rel = redactUri(
        .parse('/login?password=secret#frag'),
        defaultRedactKeys,
        stripAllQueries: true,
      );
      check('$rel').equals('/login');
    });

    test('never splits UTF-16 surrogate pairs when clipping error lines', () {
      // Place 😀 (2 UTF-16 code units) across index 255..256.
      final text = '${'a' * 255}😀tail\nsecond line secret';
      final scrubbed = scrubErrorLine(text);
      check(scrubbed)
        ..not((it) => it.contains('second line'))
        ..not((it) => it.contains('\uFFFD'));
      // Valid UTF-16 has no unpaired surrogates.
      check(scrubbed.runes.toList()).isNotEmpty();
    });

    test('describeErrorFirstLine strips URL queries and handles throwers', () {
      check(describeErrorFirstLine(_BrokenToString()))
          .equals('_BrokenToString');
      final err = StateError(
        'failed https://u:p@api.example.com/rpc?message=secret\ndump',
      );
      check(describeErrorFirstLine(err, stripAllUrlQueries: true))
        ..contains('https://***@api.example.com/rpc')
        ..not((it) => it.contains('secret'))
        ..not((it) => it.contains('u:p'))
        ..not((it) => it.contains('dump'));
      check(
        describeErrorFirstLine(
          StateError('line1 tok\nline2'),
          preScrub: (s) => s.replaceAll('tok\nline2', '***'),
        ),
      ).equals('StateError: Bad state: line1 ***');
    });
  });
}
