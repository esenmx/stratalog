import 'dart:async';

import 'package:checks/checks.dart';
import 'package:chirp/chirp.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:stratalog/stratalog.dart';
import 'package:stratalog_crashlytics/stratalog_crashlytics.dart';

import 'crashlytics_crash_reporter_test.mocks.dart';

@GenerateNiceMocks([MockSpec<FirebaseCrashlytics>()])
void main() {
  late MockFirebaseCrashlytics crashlytics;

  setUp(() {
    crashlytics = MockFirebaseCrashlytics();
    Chirp.root = ChirpLogger().addWriter(
      CrashReporterWriter(CrashlyticsCrashReporter(crashlytics)),
    );
  });

  tearDown(() => Chirp.root = null);

  // Matches recordError on the given values, any other argument wildcarded.
  Future<void> recordError({Object? error, String? reason, bool? fatal}) =>
      crashlytics.recordError(
        error ?? any,
        any,
        reason: reason ?? anyNamed('reason'),
        fatal: fatal ?? anyNamed('fatal'),
        information: anyNamed('information'),
        printDetails: anyNamed('printDetails'),
      );

  test('error record forwards with reason and non-fatal', () {
    final boom = Exception('boom');
    LogLayer.auth.error('Refresh failed', error: boom);

    verify(
      recordError(error: boom, reason: '[Auth] Refresh failed', fatal: false),
    ).called(1);
  });

  test('above-error records forward as fatal', () {
    LogLayer.app.wtf('Invariant violated', error: StateError('x'));

    verify(recordError(fatal: true)).called(1);
  });

  test('info records become Crashlytics log breadcrumbs', () {
    LogLayer.network.info('token refreshed');

    verify(crashlytics.log('[Network/info] token refreshed')).called(1);
    verifyNever(recordError());
  });

  test('breadcrumb data is inlined into the Crashlytics log string', () {
    LogLayer.network.info(
      '✗ NOT_FOUND /geo.v1.GeoService/GetCity',
      data: {'duration_ms': 12, 'error_code': 'geo.404'},
    );

    verify(
      crashlytics.log(
        '[Network/info] ✗ NOT_FOUND /geo.v1.GeoService/GetCity '
        '{duration_ms: 12, error_code: geo.404}',
      ),
    ).called(1);
  });

  test('a throwing backend never propagates to the log call', () {
    when(crashlytics.log(any)).thenThrow(StateError('no default app'));
    check(() => LogLayer.app.info('crumb')).returnsNormally();
  });

  for (final (method, call, emit) in [
    (
      'recordError',
      recordError,
      () => LogLayer.app.error('boom', error: Exception('x')),
    ),
    (
      'log',
      () => crashlytics.log(any),
      () => LogLayer.network.info('token refreshed'),
    ),
  ]) {
    test('a rejected $method future never surfaces as a zone error', () async {
      when(call())
          .thenAnswer((_) => Future<void>.error(StateError('sdk unreachable')));
      final uncaught = <Object>[];

      await runZonedGuarded(() async {
        emit();
        await Future<void>.delayed(.zero);
      }, (error, stackTrace) => uncaught.add(error));

      check(uncaught).isEmpty();
    });
  }
}
