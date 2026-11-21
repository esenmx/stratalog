import 'dart:convert';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:chirp/chirp.dart';
import 'package:stratalog/stratalog.dart';
import 'package:test/test.dart';

/// Renders through the real pipeline (logger -> console writer -> formatter)
/// with ANSI-256 forced on, capturing the final string.
List<String> render(
  void Function(LogLayer logger) log, {
  StructuredLogFormatter? formatter,
  LogLayer layer = .network,
}) {
  final lines = <String>[];
  final root = ChirpLogger().addConsoleWriter(
    formatter: formatter ?? StructuredLogFormatter(),
    output: lines.add,
    capabilities: const TerminalCapabilities(colorSupport: .ansi256),
  );
  Chirp.root = root;
  log(layer);
  Chirp.root = null;
  return lines;
}

String stripAnsi(String s) => s.replaceAll(RegExp('\x1B\\[[0-9;]*m'), '');

void main() {
  test('header shows badge, level, and body carries the gutter', () {
    final out = stripAnsi(
      render((l) => l.warning('slow response'), layer: .auth).single,
    );
    final lines = out.split('\n');

    check(lines.first).startsWith(' Auth ');
    check(lines.first).contains('[warning]');
    check(lines[1]).startsWith(' ├─ slow response');
  });

  test('every body line is bordered, none dangling', () {
    final out = stripAnsi(
      render(
        (l) => l.info(
          'line1\nline2',
          data: {'k': 'v'},
          error: Exception('boom'),
          stackTrace: .current,
        ),
        layer: .auth,
      ).single,
    );
    final lines = out.split('\n');

    final body = lines.skip(1).where((l) => l.isNotEmpty);
    for (final line in body) {
      check(
        line,
      ).anyOf([(it) => it.startsWith(' ├─ '), (it) => it.startsWith(' │  ')]);
    }
    check(lines.last.trim()).isNotEmpty(); // no dangling border line
    check(out).contains('Data: ');
    check(out).contains('Error:');
    check(out).contains('Exception: boom');
    check(out).contains('Stack Trace:');
  });

  test('unencodable data objects fall back to toString', () {
    final out = stripAnsi(
      render((l) => l.info('x', data: {'obj': Object()})).single,
    );
    check(out).contains("Instance of 'Object'");
  });

  test('a payload whose toString throws renders an unencodable marker', () {
    // chirp's writer dispatch loop has no try/catch around a sink — this
    // must render, not throw, or every writer queued after this one is
    // skipped for the record.
    final out = stripAnsi(
      render((l) => l.info('x', data: {'obj': _ThrowsOnToString()})).single,
    );
    check(out).contains('<unencodable: _ThrowsOnToString>');
  });

  test('a cyclic data map never crashes the format call', () {
    final cyclic = <String, Object?>{};
    cyclic['self'] = cyclic;
    check(() => render((l) => l.info('x', data: cyclic))).returnsNormally();
  });

  test('showTimestamp/showLocation strip header segments and caller cost', () {
    final formatter = StructuredLogFormatter(
      showTimestamp: false,
      showLocation: false,
    );
    check(formatter.requiresCallerInfo).isFalse();

    final out = stripAnsi(
      render((l) => l.info('x'), formatter: formatter).single,
    );
    check(out.split('\n').first).not((it) => it.contains(' • '));
  });

  test('caller info points at the call site, not the delegation frames', () {
    final out = stripAnsi(render((l) => l.info('x')).single);
    final header = out.split('\n').first;

    check(header).contains('formatter_test');
    check(header).not((it) => it.contains('layers'));
  });

  test('raw layer renders the whole body flush-left, no gutter anywhere', () {
    final out = stripAnsi(
      render(
        (l) => l.error(
          '''
SELECT * FROM users
WHERE id = ?''',
          data: {
            'args': [42],
            'duration_ms': 3,
          },
          error: Exception('boom'),
          stackTrace: .current,
        ),
        layer: .storage,
      ).single,
    );
    final lines = out.split('\n');

    check(out).not((it) => it.contains('├─'));
    check(out).not((it) => it.contains('│'));
    check(lines[1]).equals('SELECT * FROM users');
    check(lines[2]).equals('WHERE id = ?'); // continuation at column 0
    check(lines.singleWhere((l) => l.contains('Data ▼'))).equals('Data ▼');
    check(lines.singleWhere((l) => l.contains('Error:'))).startsWith('Error:');
    check(lines.singleWhere((l) => l.contains('Stack Trace:')))
        .startsWith('Stack Trace:');
  });

  test('raw layer renders the Data block flush-left as valid JSON', () {
    final out = stripAnsi(
      render(
        (l) => l.info(
          '← 200 GET https://api.example.com/users/42',
          data: {
            'status': 200,
            'body': {'id': 42, 'name': 'Jane'},
          },
        ),
      ).single,
    );
    final lines = out.split('\n');

    check(lines[1]).equals('← 200 GET https://api.example.com/users/42');
    final labelIdx = lines.indexOf('Data ▼');
    check(labelIdx).isGreaterThan(1);

    final jsonLines = lines.sublist(labelIdx + 1);
    // Flush-left: braces at column 0, inner indentation is JSON's own, and
    // deepest leaf objects (`body`) collapse onto one line when they fit.
    check(jsonLines).deepEquals([
      '{',
      '  "status": 200,',
      '  "body": {"id": 42, "name": "Jane"}',
      '}',
    ]);
    check(jsonDecode(jsonLines.join('\n')))
        .isA<Map<String, Object?>>()
        .deepEquals({
          'status': 200,
          'body': {'id': 42, 'name': 'Jane'},
        });
  });

  test('deepest objects and arrays collapse onto one line when they fit and '
      'wrap when they exceed maxInlineDataWidth', () {
    check(StructuredLogFormatter.formatJson({'duration_ms': 132}))
        .equals('{"duration_ms": 132}');

    const longDesc =
        'A long leaf value that pushes this deepest object past 80 characters';
    check(
      StructuredLogFormatter.formatJson({
        'args': [42, 'ok'],
        'user': {'id': 42, 'name': 'Jane'},
        'wide': {'id': 42, 'description': longDesc},
      }),
    ).equals(
      '{\n'
      '  "args": [42, "ok"],\n'
      '  "user": {"id": 42, "name": "Jane"},\n'
      '  "wide": {\n'
      '    "id": 42,\n'
      '    "description": "$longDesc"\n'
      '  }\n'
      '}',
    );
  });

  test('inline width counts the key or array-indent prefix; arrays wrap '
      'like objects', () {
    // At width 20: "ab" (prefix 8) + 8 fits; "longer_key" (prefix 16) + 12
    // does not; array items carry a 4-column prefix, so 16 fits and 17
    // wraps; "kk" (prefix 8) + 15 wraps its leaf array.
    check(
      StructuredLogFormatter.formatJson({
        'ab': {'x': 1},
        'longer_key': {'x': 12345},
        'rows': [
          {'x': 123456789},
          {'x': 1234567890},
        ],
        'kk': [1, 2, 3, 4, 5],
      }, maxInlineWidth: 20),
    ).equals(
      '{\n'
      '  "ab": {"x": 1},\n'
      '  "longer_key": {\n'
      '    "x": 12345\n'
      '  },\n'
      '  "rows": [\n'
      '    {"x": 123456789},\n'
      '    {\n'
      '      "x": 1234567890\n'
      '    }\n'
      '  ],\n'
      '  "kk": [\n'
      '    1,\n'
      '    2,\n'
      '    3,\n'
      '    4,\n'
      '    5\n'
      '  ]\n'
      '}',
    );
  });

  group('formatJson keeps non-JSON leaves encodable', () {
    final cases = <String, (Object?, Object?)>{
      'NaN': (double.nan, 'NaN'),
      'infinity': (double.infinity, 'Infinity'),
      'TypedData': (Uint8List(3), '<3-byte blob elided>'),
      'Set': ({'a'}, ['a']),
    };
    for (final MapEntry(key: name, value: (leaf, decoded)) in cases.entries) {
      test(name, () {
        final json = StructuredLogFormatter.formatJson({'k': leaf});
        check(jsonDecode(json))
            .isA<Map<String, Object?>>()
            .deepEquals({'k': decoded});
      });
    }
  });

  test('a non-String nested map key renders the unencodable marker', () {
    final out = stripAnsi(
      render(
        (l) => l.info(
          'x',
          data: {
            'm': {1: 'a'},
          },
        ),
      ).single,
    );
    check(out).contains('<unencodable: ');
  });

  test('rawDataLayers: const {} restores the gutter for Network', () {
    final out = stripAnsi(
      render(
        (l) => l.info('x', data: {'k': 'v'}),
        formatter: StructuredLogFormatter(rawDataLayers: const {}),
      ).single,
    );

    check(out).contains('Data: ');
    for (final line in out.split('\n').skip(1).where((l) => l.isNotEmpty)) {
      check(
        line,
      ).anyOf([(it) => it.startsWith(' ├─ '), (it) => it.startsWith(' │  ')]);
    }
  });

  test('non-listed layer keeps the bordered Data rendering', () {
    final out = stripAnsi(
      render((l) => l.info('x', data: {'k': 'v'}), layer: .auth).single,
    );

    check(out).contains('Data: ');
    check(out).not((it) => it.contains('Data ▼'));
  });

  test('custom domain colors overlay, palette fills the rest', () {
    final formatter = StructuredLogFormatter(
      domainColors: const {'Payments': Ansi256.springGreen4_29},
    );
    check(formatter.domainColors['Payments']).equals(Ansi256.springGreen4_29);
    check(formatter.domainColors['Network']).equals(LogPalette.network);
  });
}

final class _ThrowsOnToString {
  @override
  String toString() => throw StateError('poison');
}
