import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:stratalog/stratalog.dart';
import 'package:test/test.dart';

void main() {
  group('snapshotData', () {
    test('caller mutation after snapshot is invisible in the copy', () {
      final nested = <String, Object?>{'attempt': 1};
      final data = <String, Object?>{'stats': nested};

      final out = snapshotData(data);
      nested['attempt'] = 2;
      data['stats'] = 'replaced';

      check(
        out['stats'],
      ).isA<Map<Object?, Object?>>().deepEquals({'attempt': 1});
    });

    test('deep-copies nested lists, not just the top-level map', () {
      final items = <Object?>[1, 2, 3];
      final out = snapshotData({'items': items});
      items.add(4);
      check(out['items']).isA<List<Object?>>().deepEquals([1, 2, 3]);
    });

    test('cycle-safe: a self-referencing map renders <cycle>', () {
      final cyclic = <String, Object?>{'note': 'x'};
      cyclic['self'] = cyclic;

      final out = snapshotData(cyclic);
      check(out['note']).equals('x');
      check(out['self']).equals('<cycle>');
    });

    test('cycle-safe: a self-referencing list renders <cycle>', () {
      final cyclic = <Object?>[1];
      cyclic.add(cyclic);

      final out = snapshotData({'list': cyclic});
      final list = out['list']! as List<Object?>;
      check(list[0]).equals(1);
      check(list[1]).equals('<cycle>');
    });

    test(
      'aliased map across top-level entries copies twice, never <cycle>',
      () {
        final shared = <String, Object?>{'id': 7};
        final out = snapshotData({'request': shared, 'mirror': shared});

        check(
          out['request'],
        ).isA<Map<Object?, Object?>>().deepEquals({'id': 7});
        check(out['mirror']).isA<Map<Object?, Object?>>().deepEquals({'id': 7});
      },
    );

    test('aliased siblings inside one entry copy twice, never <cycle>', () {
      final shared = <String, Object?>{'id': 7};
      final out = snapshotData({
        'wrap': {'first': shared, 'second': shared},
      });

      check(out['wrap']).isA<Map<Object?, Object?>>().deepEquals({
        'first': {'id': 7},
        'second': {'id': 7},
      });
    });

    test('aliased list referenced twice copies twice, never <cycle>', () {
      final shared = <Object?>[1, 2];
      final out = snapshotData({'a': shared, 'b': shared});

      check(out['a']).isA<List<Object?>>().deepEquals([1, 2]);
      check(out['b']).isA<List<Object?>>().deepEquals([1, 2]);
    });

    test('string-keyed nested map keeps its reified key type', () {
      final out = snapshotData({
        'body': <String, Object?>{'id': 1},
      });

      check(out['body']).isA<Map<String, Object?>>().deepEquals({'id': 1});
    });

    test('TypedData passes through by reference, not copied', () {
      final bytes = Uint8List.fromList([1, 2, 3]);
      final out = snapshotData({'bytes': bytes});
      check(identical(out['bytes'], bytes)).isTrue();
    });

    test('scalars and null pass through untouched', () {
      final out = snapshotData({'n': 1, 's': 'x', 'b': true, 'z': null});
      check(out).deepEquals({'n': 1, 's': 'x', 'b': true, 'z': null});
    });
  });
}
