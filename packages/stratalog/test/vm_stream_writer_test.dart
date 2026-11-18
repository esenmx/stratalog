import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:chirp/chirp.dart';
import 'package:stratalog/stratalog.dart';
import 'package:test/test.dart';

LogRecord _record({
  Object? message = 'm',
  ChirpLogLevel level = .info,
  String? loggerName,
  Map<String, Object?>? data,
  Object? error,
  StackTrace? stackTrace,
}) {
  final at = DateTime.utc(2026, 1, 2, 3, 4, 5, 678);
  return LogRecord(
    message: message,
    timestamp: at,
    wallClock: at,
    level: level,
    loggerName: loggerName,
    data: data,
    error: error,
    stackTrace: stackTrace,
  );
}

/// The `data` field [VmStreamWriter] produces for [data].
Object? _encodedData(Map<String, Object?> data) =>
    VmStreamWriter(post: (_) {}).toRecordJson(_record(data: data), 1)['data'];

void main() {
  test('record schema v1 matches the shared contract fixture', () {
    final record = _record(
      message: '← 200 GET https://api.example.com/users/42',
      loggerName: 'Network',
      data: {
        'status': 200,
        'body': {
          'id': 42,
          'name': 'Jane',
          'tags': ['a', 'b'],
        },
        'duration_ms': 12,
      },
    );
    final fixture = File('../../tools/strata/testdata/record_v1.json')
        .readAsStringSync();

    final json = VmStreamWriter(post: (_) {}).toRecordJson(record, 1);

    check(json).deepEquals(jsonDecode(fixture) as Map<String, Object?>);
    // Key order too, everywhere: strata renders payloads in wire order.
    check(jsonEncode(json)).equals(jsonEncode(jsonDecode(fixture)));
  });

  test('optional keys appear only when the record carries them', () {
    final json = VmStreamWriter(post: (_) {}).toRecordJson(
      _record(
        level: .error,
        error: StateError('boom'),
        stackTrace: .fromString('#0 main (a.dart:1:1)'),
      ),
      7,
    );

    check(json['layer']).equals('App');
    check(json['color']).equals(LogPalette.hex(LogPalette.app));
    check(json['levelColor']).equals('#ff0000');
    check(json['error']).equals('Bad state: boom');
    check(json['stack']).equals('#0 main (a.dart:1:1)');
    check(json.keys).not((it) => it.contains('data'));
    check(json.keys).not((it) => it.contains('file'));
  });

  test('caller info is captured through a real logger', () {
    final posted = <Map<String, Object?>>[];
    ChirpLogger().addWriter(VmStreamWriter(post: posted.add)).info('here');

    check(posted.single['file']).equals('vm_stream_writer_test');
    check(posted.single['line']).isA<int>();
    check(posted.single['method']).isA<String>();
  });

  test('caller info omits empty method', () {
    final record = LogRecord(
      message: 'partial caller',
      timestamp: .utc(2026),
      wallClock: .utc(2026),
      caller: .fromString('#0      (package:app/boot.dart:12:3)'),
    );
    final json = VmStreamWriter(post: (_) {}).toRecordJson(record, 1);

    check(json['file']).equals('boot');
    check(json['line']).equals(12);
    check(json.keys).not((it) => it.contains('method'));
  });

  test('post test seam does not clobber shared VM history', () {
    configureLogging();
    LogLayer.app.info('live record');
    final live = Chirp.root.writers.whereType<VmStreamWriter>().single;

    VmStreamWriter(post: (_) {}).write(_record(message: 'isolated test'));

    check(live.history.last['message']).equals('live record');
  });

  test('layer color follows the formatter, LogLayer declarations included', () {
    const custom = LogLayer('VmStreamCustom', color: Ansi256.green3_34);
    final posted = <Map<String, Object?>>[];
    Chirp.root = ChirpLogger().addWriter(VmStreamWriter(post: posted.add));
    custom.info('x');
    Chirp.root = null;

    check(posted.single['color']).equals(LogPalette.hex(Ansi256.green3_34));
  });

  group('payload is JSON-safe', () {
    final cases = <String, (Object?, Object?)>{
      'NaN': (double.nan, 'NaN'),
      'infinity': (double.infinity, 'Infinity'),
      'finite double': (1.5, 1.5),
      'blob': (Uint8List(3), '<3-byte blob elided>'),
      'non-string keys': ({1: 'a'}, {'1': 'a'}),
      'set': ({'a'}, ['a']),
      'object': (const Duration(seconds: 1), '0:00:01.000000'),
      'throwing toString': (_Bad(), '<unencodable: _Bad>'),
    };
    for (final MapEntry(key: name, value: (input, expected)) in cases.entries) {
      test(name, () {
        final data = _encodedData({'k': input})! as Map<String, Object?>;
        check(jsonEncode(data['k'])).equals(jsonEncode(expected));
        check(() => jsonEncode(data)).returnsNormally();
      });
    }

    test('cycle', () {
      final cyclic = <String, Object?>{};
      cyclic['self'] = cyclic;
      final data = _encodedData({'k': cyclic})! as Map<String, Object?>;
      check(jsonEncode(data)).equals('{"k":{"self":"<cycle>"}}');
    });
  });

  test('ring buffer keeps the newest capacity records, oldest first', () {
    final writer = VmStreamWriter(capacity: 3, post: (_) {});
    for (var i = 0; i < 5; i++) {
      writer.write(_record(message: 'r$i'));
    }

    check(writer.history.map((r) => r['seq'])).deepEquals([3, 4, 5]);
    check(writer.history.map((r) => r['message']))
        .deepEquals(['r2', 'r3', 'r4']);
  });

  test('a non-positive capacity keeps no history but still posts', () {
    final posted = <Map<String, Object?>>[];
    VmStreamWriter(capacity: -1, post: posted.add).write(_record());

    check(posted).length.equals(1);
  });

  test('seq is monotonic per writer, starting at 1', () {
    final posted = <Map<String, Object?>>[];
    final writer = VmStreamWriter(post: posted.add);
    for (var i = 0; i < 3; i++) {
      writer.write(_record());
    }

    check(posted.map((r) => r['seq'])).deepEquals([1, 2, 3]);
  });

  test('a failing post never throws into chirp or skips later writers', () {
    final later = <LogRecord>[];
    ChirpLogger()
        .addWriter(VmStreamWriter(post: (_) => throw StateError('closed')))
        .addWriter(_CaptureWriter(later.add))
        .info('survives');

    check(later.single.message).equals('survives');
  });
}

final class _Bad {
  @override
  String toString() => throw StateError('no');
}

final class _CaptureWriter(final void Function(LogRecord) onWrite)
    extends ChirpWriter {
  @override
  void write(LogRecord record) => onWrite(record);
}
