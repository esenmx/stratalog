import 'dart:async';

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
    Chirp.root = ChirpLogger().addWriter(
      CrashReporterWriter(const SentryCrashReporter()),
    );
  });

  tearDown(() async {
    Chirp.root = null;
    await Sentry.close();
  });

  // captureException is fired unawaited by the adapter; give the hub's task
  // queue a beat before asserting.
  Future<void> settle() => Future<void>.delayed(.zero);

  test('error record becomes a Sentry event with the thrown error', () async {
    final boom = Exception('boom');
    LogLayer.auth.error('Refresh failed', error: boom);
    await settle();

    check(captured).length.equals(1);
    check(captured.single.throwable).equals(boom);
    check(captured.single.level).equals(.error);
  });

  test('above-error records are fatal', () async {
    LogLayer.app.wtf('Invariant violated', error: StateError('x'));
    await settle();

    check(captured.single.level).equals(.fatal);
  });

  test('info records become breadcrumbs on the next event', () async {
    LogLayer.network.info('token refreshed');
    LogLayer.network.error('boom', error: Exception('x'));
    await settle();

    final crumbs = captured.single.breadcrumbs ?? [];
    check(
      crumbs.map((b) => b.message ?? ''),
    ).contains('[Network/info] token refreshed');
  });

  test('breadcrumb carries the record data map', () async {
    LogLayer.network.info(
      '✗ NOT_FOUND /geo.v1.GeoService/GetCity',
      data: {'duration_ms': 12, 'error_code': 'geo.404'},
    );
    LogLayer.network.error('boom', error: Exception('x'));
    await settle();

    final crumb = (captured.single.breadcrumbs ?? []).singleWhere(
      (b) => (b.message ?? '').contains('GetCity'),
    );
    check(
      crumb.data,
    ).isNotNull().deepEquals({'duration_ms': 12, 'error_code': 'geo.404'});
  });

  test('uninitialized hub no-ops instead of throwing', () async {
    await Sentry.close();
    check(
      () => LogLayer.app.error('boom', error: Exception('x')),
    ).returnsNormally();
  });

  test(
    'a rejected captureException future never surfaces as a zone error',
    () async {
      await Sentry.close();
      await Sentry.init((options) {
        options
          ..dsn = 'https://public@sentry.example.com/1'
          // automatedTestMode is the SDK's own documented seam for making a
          // user-closure exception rethrow instead of being swallowed —
          // without it, the hub always self-catches and this bug is
          // unreachable through public API.
          // ignore: invalid_use_of_internal_member
          ..automatedTestMode = true
          ..beforeSend = (event, hint) => throw StateError('sdk unreachable');
      });
      final uncaught = <Object>[];

      await runZonedGuarded(() async {
        LogLayer.app.error('boom', error: Exception('x'));
        await settle();
      }, (error, stackTrace) => uncaught.add(error));

      check(uncaught).isEmpty();
    },
  );

  test(
    'a rejected addBreadcrumb future never surfaces as a zone error',
    () async {
      await Sentry.close();
      await Sentry.init((options) {
        options
          ..dsn = 'https://public@sentry.example.com/1'
          // See the captureException test above for why this is needed.
          // ignore: invalid_use_of_internal_member
          ..automatedTestMode = true
          ..beforeBreadcrumb = (crumb, hint) =>
              throw StateError('sdk unreachable');
      });
      final uncaught = <Object>[];

      await runZonedGuarded(() async {
        LogLayer.network.info('token refreshed');
        await settle();
      }, (error, stackTrace) => uncaught.add(error));

      check(uncaught).isEmpty();
    },
  );
}
