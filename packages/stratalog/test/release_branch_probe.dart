// Subprocess probe for release_console_writer_test.dart. Run with
// `dart -Ddart.vm.product=true run test/release_branch_probe.dart` so
// configureLogging() takes its real release branch (bootstrap.dart).
// Communicates with the parent test via stdout key=value lines; the logged
// record itself lands on stdout too, as one intact JSON line.
// ignore_for_file: avoid_print

import 'dart:async';

import 'package:chirp/chirp.dart';
import 'package:stratalog/src/console_output_io.dart';
import 'package:stratalog/stratalog.dart';

void main() {
  configureLogging();
  final writer = Chirp.root.writers.single;

  // ~850-char body — under the default ElisionConfig budget of 1024 (passes
  // verbatim), whole record over Android's 924-char print chunk.
  final body = '{${List.generate(40, (i) => '"f$i":"${'v' * 12}"').join(',')}}';

  // A print()-backed writer would emit through the zone; the stdout sink
  // must bypass it.
  final zonePrints = <String>[];
  runZoned(
    () => Chirp.info(
      'probe',
      data: {'status': 200, 'url': '/api/v1/orders', 'body': body},
    ),
    zoneSpecification: ZoneSpecification(
      print: (self, parent, zone, line) => zonePrints.add(line),
    ),
  );

  print('writerType=${writer.runtimeType}');
  if (writer case final PrintConsoleWriter w) {
    print('outputIsCorePrint=${identical(w.output, print)}');
    print('outputIsStdoutLineSink=${identical(w.output, writeConsoleLine)}');
    print('maxChunkLength=${w.maxChunkLength}');
  }
  print('zonePrintCount=${zonePrints.length}');
}
