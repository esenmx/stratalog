import 'package:checks/checks.dart';
import 'package:chirp/chirp.dart';
import 'package:stratalog/stratalog.dart';
import 'package:test/test.dart';

/// Captures the record its wrapper hands down — proves what [ElidingFormatter]
/// forwards without rendering. Non-default separator/caller flag prove
/// delegation.
final class _CaptureFormatter extends ChirpFormatter {
  LogRecord? seen;

  @override
  bool get requiresCallerInfo => true;

  @override
  String get recordSeparator => '\x1E\n';

  @override
  void format(LogRecord record, MessageBuffer buffer) => seen = record;
}

LogRecord _record(Map<String, Object?> data) => LogRecord(
  message: 'm',
  timestamp: DateTime(2020),
  wallClock: DateTime(2020),
  data: data,
);

/// [elideJson] typed to its map result — the one place the necessary
/// non-null cast lives.
Map<Object?, Object?> _elideMap(
  Object? value, {
  int maxStringChars = 1024,
  int maxArrayItems = 32,
}) =>
    elideJson(
          value,
          maxStringChars: maxStringChars,
          maxArrayItems: maxArrayItems,
        )!
        as Map<Object?, Object?>;

void main() {
  group('clipString', () {
    test('keeps strings within the cap', () {
      check(clipString('short', 32)).equals('short');
    });

    test('appends the dropped-count suffix past the cap', () {
      check(clipString('x' * 40, 8)).equals('${'x' * 8}…(+32 chars)');
    });

    test('backs off a split surrogate pair rather than emit a lone half', () {
      // '😀' is a surrogate pair (2 code units). Cutting at 5 would split the
      // pair, so the cut backs off to 4 and reports 2 dropped code units.
      check(clipString('abcd😀', 5)).equals('abcd…(+2 chars)');
    });

    test('returns verbatim when the cap is non-positive', () {
      check(clipString('anything', 0)).equals('anything');
    });
  });

  group('elideJson', () {
    test('preserves map shape and every key', () {
      check(_elideMap({'a': 1, 'b': 2}).keys).deepEquals(['a', 'b']);
    });

    test('clips an oversized leaf string', () {
      final out = _elideMap({'note': 'x' * 100}, maxStringChars: 8);
      check(out['note']).equals('${'x' * 8}…(+92 chars)');
    });

    test('keeps keepKeys verbatim past every cap', () {
      final blob = 'A' * 2000; // long + base64-ish → would normally elide
      check(_elideMap({'id': blob}, maxStringChars: 8)['id']).equals(blob);
    });

    test('elides a base64/binary blob to a size summary', () {
      check(
        _elideMap({'avatar': 'A' * 600})['avatar'],
      ).equals('<600-char blob elided>');
    });

    test('elides a data URI', () {
      final uri = 'data:image/png;base64,${'Z' * 80}';
      check(
        _elideMap({'img': uri})['img'],
      ).equals('<${uri.length}-char blob elided>');
    });

    test('truncates a long list with a remainder marker', () {
      final out = _elideMap({
        'items': List<int>.generate(50, (i) => i),
      }, maxArrayItems: 10);
      final items = out['items']! as List<Object?>;
      check(items.length).equals(11);
      check(items.first).equals(0);
      check(items.last).equals('…(+40 more)');
    });

    test('passes numbers, bools and null through untouched', () {
      final out = _elideMap({'n': 42, 'b': true, 'z': null});
      check(out['n']).equals(42);
      check(out['b']).equals(true);
      check(out['z']).isNull();
    });

    test('a giant leaf never evicts its siblings', () {
      // The user's exact pain: a base64 avatar must not swallow the field you
      // opened the log for. Per-leaf elision keeps `error` intact.
      final out = _elideMap({
        'avatar': 'A' * 4000,
        'error': 'account suspended',
      });
      check(out['avatar']).equals('<4000-char blob elided>');
      check(out['error']).equals('account suspended');
    });

    test('recurses nested maps without flattening structure', () {
      final out = _elideMap({
        'user': {'name': 'Jane', 'bio': 'y' * 100},
      }, maxStringChars: 8);
      final user = out['user']! as Map<Object?, Object?>;
      check(user['name']).equals('Jane'); // keepKey, verbatim
      check(user['bio']).equals('${'y' * 8}…(+92 chars)');
    });
  });

  group('elideData', () {
    test('returns a typed map with top-level keepKeys intact', () {
      final out = elideData({
        'id': 'A' * 2000,
        'note': 'x' * 100,
      }, maxStringChars: 8);
      check(out['id']).equals('A' * 2000);
      check(out['note']).equals('${'x' * 8}…(+92 chars)');
    });
  });

  group('ElidingFormatter', () {
    test('delegates with elided data', () {
      final inner = _CaptureFormatter();
      ElidingFormatter(
        inner,
        maxStringChars: 8,
      ).format(_record({'body': 'x' * 100}), MessageBuffer.file());
      check(inner.seen!.data['body']).equals('${'x' * 8}…(+92 chars)');
    });

    test('passes an empty-data record through untouched', () {
      final inner = _CaptureFormatter();
      final record = _record({});
      ElidingFormatter(inner).format(record, MessageBuffer.file());
      check(inner.seen).identicalTo(record);
    });

    test('delegates recordSeparator and requiresCallerInfo to inner', () {
      final formatter = ElidingFormatter(_CaptureFormatter());
      check(formatter.recordSeparator).equals('\x1E\n');
      check(formatter.requiresCallerInfo).isTrue();
    });

    test('renders a dio-style body as readable elided JSON, not a flat '
        'escaped string', () {
      // The end-to-end deliverable through the real console formatter: the
      // blob is summarised, the vital field survives, and it stays indented
      // JSON — the exact failure mode of the old tail-chop.
      final buffer = ConsoleMessageBuffer(
        capabilities: const TerminalCapabilities(),
      );
      ElidingFormatter(
        StructuredLogFormatter(showTimestamp: false, showLocation: false),
      ).format(
        _record({
          'body': {'avatar': 'A' * 4000, 'error': 'account suspended'},
        }),
        MessageBuffer(buffer),
      );
      final output = buffer.toString();
      check(output).contains('<4000-char blob elided>');
      check(output).contains('"error": "account suspended"');
    });

    test('preserves caller and loggerName through the eliding copy', () {
      // copyWith(data:) must not drop the fields the header renders from,
      // else wrapping silently kills the file:line • method location.
      final inner = _CaptureFormatter();
      final caller = StackTrace.current;
      ElidingFormatter(inner).format(
        LogRecord(
          message: 'm',
          timestamp: DateTime(2020),
          wallClock: DateTime(2020),
          caller: caller,
          loggerName: 'Network',
          data: {'body': 'x' * 100},
        ),
        MessageBuffer.file(),
      );
      check(inner.seen!.caller).identicalTo(caller);
      check(inner.seen!.loggerName).equals('Network');
    });
  });

  group('ElisionConfig', () {
    test('none disables elision', () {
      check(ElisionConfig.none.enabled).isFalse();
    });

    test('vital carries the tight budget with elision enabled', () {
      check(ElisionConfig.vital.enabled).isTrue();
      check(ElisionConfig.vital.maxStringChars).equals(200);
      check(ElisionConfig.vital.maxArrayItems).equals(8);
      check(ElisionConfig.vital.keepKeys).deepEquals(defaultKeepKeys);
    });
  });

  group('layerElision', () {
    LogRecord layerRecord(String layer, Map<String, Object?> data) => LogRecord(
      message: 'm',
      timestamp: DateTime(2020),
      wallClock: DateTime(2020),
      loggerName: layer,
      data: data,
    );

    test('a Network record passes to inner verbatim — the identical '
        'instance, no copy', () {
      final inner = _CaptureFormatter();
      final record = layerRecord('Network', {'body': 'x' * 5000});
      ElidingFormatter(
        inner,
        layerElision: defaultLayerElision,
      ).format(record, MessageBuffer.file());
      check(inner.seen).identicalTo(record);
    });

    test('a State record clips at the vital budget, keepKeys verbatim', () {
      final inner = _CaptureFormatter();
      final id = 'A' * 600; // long + base64-ish → would normally blob-elide
      ElidingFormatter(inner, layerElision: defaultLayerElision).format(
        layerRecord('State', {'id': id, 'note': 'x' * 500}),
        MessageBuffer.file(),
      );
      check(inner.seen!.data['id']).equals(id);
      check(
        inner.seen!.data['note'],
      ).equals('${'x' * 200}…(+300 chars)');
    });

    test('an unlisted layer uses the instance budget', () {
      final inner = _CaptureFormatter();
      ElidingFormatter(
        inner,
        maxStringChars: 8,
        layerElision: defaultLayerElision,
      ).format(
        layerRecord('Payments', {'note': 'x' * 100}),
        MessageBuffer.file(),
      );
      check(inner.seen!.data['note']).equals('${'x' * 8}…(+92 chars)');
    });

    test('of(none) disables the instance budget — unlisted layers pass '
        'verbatim while a per-layer enabled config still elides', () {
      final inner = _CaptureFormatter();
      final formatter = ElidingFormatter.of(
        inner,
        ElisionConfig.none,
        layerElision: const {'State': .vital},
      );

      final untouched = layerRecord('App', {'body': 'x' * 5000});
      formatter.format(untouched, MessageBuffer.file());
      check(inner.seen).identicalTo(untouched);

      formatter.format(
        layerRecord('State', {'note': 'x' * 500}),
        MessageBuffer.file(),
      );
      check(inner.seen!.data['note']).equals('${'x' * 200}…(+300 chars)');
    });

    test('a per-layer enabled config overrides the instance budget', () {
      final inner = _CaptureFormatter();
      ElidingFormatter(
        inner,
        maxStringChars: 8,
        layerElision: const {'Auth': ElisionConfig(maxStringChars: 16)},
      ).format(
        layerRecord('Auth', {'note': 'x' * 100}),
        MessageBuffer.file(),
      );
      check(inner.seen!.data['note']).equals('${'x' * 16}…(+84 chars)');
    });
  });
}
