// The release path must emit one record as ONE intact JSON line. A
// print()-backed writer (chirp's addConsoleWriter default) chunks at
// platformPrintMaxChunkLength (1024-100 on Android, liblog's LOG_BUF_SIZE),
// so a long record became several logcat entries of broken JSON and
// concurrent printers could interleave between them. bootstrap.dart now
// constructs PrintConsoleWriter with a line-atomic `stdout.writeln` sink and
// chunking forced off.

import 'dart:convert';
import 'dart:io';

import 'package:checks/checks.dart';
import 'package:chirp/chirp.dart';
import 'package:stratalog/stratalog.dart';
import 'package:test/test.dart';

/// What platformPrintMaxChunkLength returns on Android
/// (chirp-0.9.0/lib/src/platform/platform_info_io.dart:29): `1024 - 100`.
/// A record longer than this proves the assertions below are not vacuous —
/// the default print() writer would have torn it.
const int androidPrintChunkLength = 1024 - 100;

void main() {
  test('release branch wires a line-atomic stdout JSON writer', () async {
    final result = await Process.run(Platform.resolvedExecutable, [
      '-Ddart.vm.product=true',
      'run',
      'test/release_branch_probe.dart',
    ]);
    check(
      because: 'probe stderr: ${result.stderr}',
      result.exitCode,
    ).equals(0);
    final out = result.stdout as String;
    check(out).contains('writerType=PrintConsoleWriter');
    check(out).contains('outputIsCorePrint=false');
    check(out).contains('outputIsStdoutLineSink=true');
    check(
      because: 'record must bypass print() entirely',
      out,
    ).contains('zonePrintCount=0');

    final lines = const LineSplitter().convert(out);
    final jsonLines = [
      for (final line in lines)
        if (line.startsWith('{')) line,
    ];
    check(
      because: 'one record must reach stdout as one intact line',
      jsonLines.length,
    ).equals(1);
    check(jsonLines.single.length).isGreaterThan(androidPrintChunkLength);
    check(() => jsonDecode(jsonLines.single)).returnsNormally();

    final chunkLine = lines.singleWhere((l) => l.startsWith('maxChunkLength='));
    check(
      because: 'chunking must stay off where the platform default is 924',
      int.parse(chunkLine.substring('maxChunkLength='.length)),
    ).isGreaterThan(androidPrintChunkLength);
  });

  test(
    'release JSON record over Android chunk budget stays one atomic '
    'parseable line',
    () {
      // Exactly what the release branch of configureLogging() builds —
      // JsonLogFormatter wrapped in the default ElidingFormatter, chunking
      // forced off — with the sink captured instead of stdout.
      final emitted = <String>[];
      final writer = PrintConsoleWriter(
        formatter: ElidingFormatter.of(
          const JsonLogFormatter(),
          const ElisionConfig(),
        ),
        output: emitted.add,
        maxChunkLength: 1 << 30,
      );
      final logger = ChirpLogger()..addWriter(writer);

      // Routine network-response record: ~850-char body string — UNDER the
      // default ElisionConfig.maxStringChars budget of 1024, so elision
      // passes it verbatim; the full JSON line is over the 924-char Android
      // print chunk.
      final body =
          '{${List.generate(40, (i) => '"f$i":"${'v' * 12}"').join(',')}}';
      logger.info(
        'response',
        data: {'status': 200, 'url': '/api/v1/orders', 'body': body},
      );

      check(
        because: 'record must exceed one Android print chunk',
        emitted.join().length,
      ).isGreaterThan(androidPrintChunkLength);
      check(
        because: 'one log record must be one atomic sink call',
        emitted.length,
      ).equals(1);
      check(
        because: 'the emitted line must parse as JSON',
        () => jsonDecode(emitted.single),
      ).returnsNormally();
    },
  );
}
