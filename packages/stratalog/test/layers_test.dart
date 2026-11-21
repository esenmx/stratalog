import 'package:checks/checks.dart';
import 'package:chirp/chirp.dart';
import 'package:stratalog/stratalog.dart';
import 'package:test/test.dart';

void main() {
  tearDown(() => Chirp.root = null);

  test('layer resolves against the CURRENT root after replacement', () {
    final toA = <LogRecord>[];
    final toB = <LogRecord>[];

    Chirp.root = ChirpLogger().addWriter(DelegatedChirpWriter(toA.add));
    LogLayer.network.info('to A');

    // Reconfiguration (test setUp, hot restart) replaces the root entirely.
    Chirp.root = ChirpLogger().addWriter(DelegatedChirpWriter(toB.add));
    LogLayer.network.info('to B');

    check(toA.map((r) => '${r.message}')).deepEquals(['to A']);
    check(toB.map((r) => '${r.message}')).deepEquals(['to B']);
  });

  test('backing logger is cached under a stable root', () {
    Chirp.root = ChirpLogger();
    check(LogLayer.auth.logger).identicalTo(LogLayer.auth.logger);
    const payments = LogLayer('Payments');
    check(payments.logger).identicalTo(const LogLayer('Payments').logger);
  });

  test('layer names carry into records', () {
    final records = <LogRecord>[];
    Chirp.root = ChirpLogger().addWriter(DelegatedChirpWriter(records.add));

    LogLayer.storage.info('x');
    const LogLayer('Payments').info('y');

    check(records.map((r) => r.loggerName)).deepEquals(['Storage', 'Payments']);
  });

  test('logging through a layer before configureLogging throws StateError', () {
    check(() => LogLayer.app.info('x')).throws<StateError>();
  });

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

  final helpers = <(String, ChirpLogLevel, void Function(LogLayer, String))>[
    ('trace', .trace, (l, m) => l.trace(m)),
    ('debug', .debug, (l, m) => l.debug(m)),
    ('info', .info, (l, m) => l.info(m)),
    ('notice', .notice, (l, m) => l.notice(m)),
    ('success', .success, (l, m) => l.success(m)),
    ('warning', .warning, (l, m) => l.warning(m)),
    ('error', .error, (l, m) => l.error(m)),
    ('critical', .critical, (l, m) => l.critical(m)),
    ('wtf', .wtf, (l, m) => l.wtf(m)),
    ('log(level: .notice)', .notice, (l, m) => l.log(m, level: .notice)),
  ];
  for (final (name, level, log) in helpers) {
    test('$name logs at ChirpLogLevel.${level.name}', () {
      final records = <LogRecord>[];
      Chirp.root = ChirpLogger().addWriter(DelegatedChirpWriter(records.add));

      log(.app, 'uncaught zone error');

      check(records.single.level).equals(level);
      check('${records.single.message}').equals('uncaught zone error');
    });
  }

  // `_infoHere` reaches chirp through info → _log, `_logHere` through log:
  // each must skip exactly its own delegation frames.
  for (final (method, log) in [
    ('_infoHere', _infoHere),
    ('_logHere', _logHere),
  ]) {
    test('caller info names $method, not a LogLayer frame', () {
      final posted = <Map<String, Object?>>[];
      Chirp.root = ChirpLogger().addWriter(VmStreamWriter(post: posted.add));

      log(.app);

      check(posted.single['file']).equals('layers_test');
      check(posted.single['method']).equals(method);
    });
  }
}

void _infoHere(LogLayer layer) => layer.info('here');

void _logHere(LogLayer layer) => layer.log('here');
