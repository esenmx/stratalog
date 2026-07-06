import 'package:checks/checks.dart';
import 'package:chirp/chirp.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stratalog/stratalog.dart';

final class _CapturingWriter extends ChirpWriter {
  final records = <LogRecord>[];

  @override
  void write(LogRecord record) => records.add(record);
}

void main() {
  tearDown(() => Chirp.root = null);

  test('layer resolves against the CURRENT root after replacement', () {
    final writerA = _CapturingWriter();
    final writerB = _CapturingWriter();

    Chirp.root = ChirpLogger().addWriter(writerA);
    LogLayer.network.info('to A');

    // Reconfiguration (test setUp, hot restart) replaces the root entirely.
    Chirp.root = ChirpLogger().addWriter(writerB);
    LogLayer.network.info('to B');

    check(writerA.records.map((r) => '${r.message}')).deepEquals(['to A']);
    check(writerB.records.map((r) => '${r.message}')).deepEquals(['to B']);
  });

  test('same layer instance is cached under a stable root', () {
    Chirp.root = ChirpLogger();
    check(LogLayer.auth).identicalTo(LogLayer.auth);
    check(LogLayer.layer('Payments')).identicalTo(LogLayer.layer('Payments'));
  });

  test('layer names carry into records', () {
    final writer = _CapturingWriter();
    Chirp.root = ChirpLogger().addWriter(writer);

    LogLayer.storage.info('x');
    LogLayer.layer('Payments').info('y');

    check(writer.records.map((r) => r.loggerName))
        .deepEquals(['Storage', 'Payments']);
  });

  test('accessing a layer before configureLogging throws a package hint', () {
    check(() => LogLayer.app).throws<StateError>()
        .has((e) => e.message, 'message')
        .contains('configureLogging');
  });

  test('custom layers get a stable contrast-verified color', () {
    final color = LogPalette.colorFor('Payments');
    check(LogPalette.hashPool).contains(color);
    check(LogPalette.colorFor('Payments')).equals(color); // stable
    check(LogPalette.colorFor('Auth')).equals(LogPalette.auth); // listed
  });
}
