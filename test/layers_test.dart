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

  test('backing logger is cached under a stable root', () {
    Chirp.root = ChirpLogger();
    check(LogLayer.auth.logger).identicalTo(LogLayer.auth.logger);
    const payments = LogLayer('Payments');
    check(payments.logger).identicalTo(const LogLayer('Payments').logger);
  });

  test('layer names carry into records', () {
    final writer = _CapturingWriter();
    Chirp.root = ChirpLogger().addWriter(writer);

    LogLayer.storage.info('x');
    const LogLayer('Payments').info('y');

    check(
      writer.records.map((r) => r.loggerName),
    ).deepEquals(['Storage', 'Payments']);
  });

  test(
    'logging through a layer before configureLogging throws a package hint',
    () {
      check(() => LogLayer.app.info('x'))
          .throws<StateError>()
          .has((e) => e.message, 'message')
          .contains('configureLogging');
    },
  );

  test('declared layer color registers on first log', () {
    Chirp.root = ChirpLogger();
    const payments = LogLayer('Payments', color: Ansi256.springGreen4_29);

    check(LogLayer.declaredColorOf('Payments')).isNull(); // not logged yet
    payments.info('x');
    check(LogLayer.declaredColorOf('Payments')).equals(Ansi256.springGreen4_29);
  });

  test('colorless custom layers get a stable contrast-verified hash color', () {
    final color = LogPalette.colorFor('Shipping');
    check(LogPalette.hashPool).contains(color);
    check(LogPalette.colorFor('Shipping')).equals(color); // stable
    check(LogPalette.colorFor('Auth')).equals(LogPalette.auth); // listed
  });
}
