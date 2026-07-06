import 'package:checks/checks.dart';
import 'package:chirp/chirp.dart';
import 'package:sentry/sentry.dart';
import 'package:stratalog/stratalog.dart';
import 'package:stratalog_sentry/stratalog_sentry.dart';
import 'package:test/test.dart';

void main() {
  final captured = <SentryEvent>[];

  setUp(() async {
    captured.clear();
    await Sentry.init((options) {
      options
        ..dsn = 'https://public@sentry.example.com/1'
        ..beforeSend = (event, hint) {
          captured.add(event);
          return null; // capture locally, never send
        };
    });
    Chirp.root = ChirpLogger()
        .addWriter(CrashReporterWriter(const SentryCrashReporter()));
  });

  tearDown(() async {
    Chirp.root = null;
    await Sentry.close();
  });

  // captureException is fired unawaited by the adapter; give the hub's task
  // queue a beat before asserting.
  Future<void> settle() => Future<void>.delayed(Duration.zero);

  test('error record becomes a Sentry event with the thrown error', () async {
    final boom = Exception('boom');
    LogLayer.auth.error('Refresh failed', error: boom);
    await settle();

    check(captured).length.equals(1);
    check(captured.single.throwable).equals(boom);
    check(captured.single.level).equals(SentryLevel.error);
  });

  test('above-error records are fatal', () async {
    LogLayer.app.wtf('Invariant violated', error: StateError('x'));
    await settle();

    check(captured.single.level).equals(SentryLevel.fatal);
  });

  test('info records become breadcrumbs on the next event', () async {
    LogLayer.network.info('token refreshed');
    LogLayer.network.error('boom', error: Exception('x'));
    await settle();

    final crumbs = captured.single.breadcrumbs ?? [];
    check(crumbs.map((b) => b.message ?? ''))
        .contains('[Network/info] token refreshed');
  });

  test('uninitialized hub no-ops instead of throwing', () async {
    await Sentry.close();
    check(() => LogLayer.app.error('boom', error: Exception('x')))
        .returnsNormally();
  });
}
