import 'dart:convert';

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
    capabilities: const TerminalCapabilities(
      colorSupport: .ansi256,
    ),
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
      check(line).anyOf([
        (it) => it.startsWith(' ├─ '),
        (it) => it.startsWith(' │  '),
      ]);
    }
    check(lines.last.trim()).isNotEmpty(); // no dangling border line
    check(out).contains('Data: ');
    check(out).contains('Error:');
    check(out).contains('Stack Trace:');
  });

  test('unencodable data objects fall back to toString', () {
    final out = stripAnsi(
      render((l) => l.info('x', data: {'obj': Object()})).single,
    );
    check(out).contains("Instance of 'Object'");
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
    check(lines[1]).equals('▸ SELECT * FROM users');
    check(lines[2]).equals('WHERE id = ?'); // continuation at column 0
    check(lines.singleWhere((l) => l.contains('Data ▼'))).equals('Data ▼');
    check(lines.singleWhere((l) => l.contains('Error:'))).startsWith('Error:');
    check(
      lines.singleWhere((l) => l.contains('Stack Trace:')),
    ).startsWith('Stack Trace:');
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

    check(lines[1]).equals('▸ ← 200 GET https://api.example.com/users/42');
    final labelIdx = lines.indexOf('Data ▼');
    check(labelIdx).isGreaterThan(1);

    final jsonLines = lines.sublist(labelIdx + 1);
    // Flush-left: braces at column 0, inner indentation is JSON's own.
    check(jsonLines.first).equals('{');
    check(jsonLines.last).equals('}');
    check(
      jsonDecode(jsonLines.join('\n')),
    ).isA<Map<String, Object?>>().deepEquals({
      'status': 200,
      'body': {'id': 42, 'name': 'Jane'},
    });
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
      check(line).anyOf([
        (it) => it.startsWith(' ├─ '),
        (it) => it.startsWith(' │  '),
      ]);
    }
  });

  test('non-listed layer keeps the bordered Data rendering', () {
    final out = stripAnsi(
      render((l) => l.info('x', data: {'k': 'v'}), layer: .auth).single,
    );

    check(out).contains('Data: ');
    check(out).not((it) => it.contains('Data ▼'));
  });

  test('defaultRawDataLayers covers Network and Storage', () {
    check(
      StructuredLogFormatter.defaultRawDataLayers,
    ).unorderedEquals({'Network', 'Storage'});
  });

  test('custom domain colors overlay, palette fills the rest', () {
    final formatter = StructuredLogFormatter(
      domainColors: const {'Payments': Ansi256.springGreen4_29},
    );
    check(formatter.domainColors['Payments']).equals(Ansi256.springGreen4_29);
    check(formatter.domainColors['Network']).equals(LogPalette.network);
  });
}
