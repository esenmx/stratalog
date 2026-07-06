import 'package:checks/checks.dart';
import 'package:chirp/chirp.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stratalog/stratalog.dart';

/// Renders through the real pipeline (logger -> console writer -> formatter)
/// with ANSI-256 forced on, capturing the final string.
List<String> render(
  void Function(ChirpLogger logger) log, {
  StructuredLogFormatter? formatter,
}) {
  final lines = <String>[];
  final root = ChirpLogger().addConsoleWriter(
    formatter: formatter ?? StructuredLogFormatter(),
    output: lines.add,
    capabilities:
        const TerminalCapabilities(colorSupport: TerminalColorSupport.ansi256),
  );
  Chirp.root = root;
  log(LogLayer.network);
  Chirp.root = null;
  return lines;
}

String stripAnsi(String s) => s.replaceAll(RegExp('\x1B\\[[0-9;]*m'), '');

void main() {
  test('header shows badge, level, and body carries the gutter', () {
    final out = stripAnsi(render((l) => l.warning('slow response')).single);
    final lines = out.split('\n');

    check(lines.first).startsWith(' Network ');
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
          stackTrace: StackTrace.current,
        ),
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

  test('showTimestamp/showLocation strip header segments and caller cost',
      () {
    final formatter =
        StructuredLogFormatter(showTimestamp: false, showLocation: false);
    check(formatter.requiresCallerInfo).isFalse();

    final out =
        stripAnsi(render((l) => l.info('x'), formatter: formatter).single);
    check(out.split('\n').first).not((it) => it.contains(' • '));
  });

  test('custom domain colors overlay, palette fills the rest', () {
    final formatter = StructuredLogFormatter(
      domainColors: const {'Payments': Ansi256.springGreen4_29},
    );
    check(formatter.domainColors['Payments'])
        .equals(Ansi256.springGreen4_29);
    check(formatter.domainColors['Network']).equals(LogPalette.network);
  });
}
