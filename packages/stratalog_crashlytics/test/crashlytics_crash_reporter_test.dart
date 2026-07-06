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
    when(
      crashlytics.recordError(
        any,
        any,
        reason: anyNamed('reason'),
        fatal: anyNamed('fatal'),
        information: anyNamed('information'),
        printDetails: anyNamed('printDetails'),
      ),
    ).thenAnswer((_) async {});
    when(crashlytics.log(any)).thenAnswer((_) async {});

    Chirp.root = ChirpLogger().addWriter(
      CrashReporterWriter(CrashlyticsCrashReporter(crashlytics)),
    );
  });

  tearDown(() => Chirp.root = null);

  test('error record forwards with reason and non-fatal', () {
    final boom = Exception('boom');
    LogLayer.auth.error('Refresh failed', error: boom);

    verify(
      crashlytics.recordError(
        boom,
        any,
        reason: '[Auth] Refresh failed',
        // Asserting the non-fatal path explicitly, not passing a default.
        // ignore: avoid_redundant_argument_values
        fatal: false,
        information: anyNamed('information'),
        printDetails: anyNamed('printDetails'),
      ),
    ).called(1);
  });

  test('above-error records forward as fatal', () {
    LogLayer.app.wtf('Invariant violated', error: StateError('x'));

    verify(
      crashlytics.recordError(
        any,
        any,
        reason: anyNamed('reason'),
        fatal: true,
        information: anyNamed('information'),
        printDetails: anyNamed('printDetails'),
      ),
    ).called(1);
  });

  test('info records become Crashlytics log breadcrumbs', () {
    LogLayer.network.info('token refreshed');

    verify(crashlytics.log('[Network/info] token refreshed')).called(1);
    verifyNever(
      crashlytics.recordError(
        any,
        any,
        reason: anyNamed('reason'),
        fatal: anyNamed('fatal'),
        information: anyNamed('information'),
        printDetails: anyNamed('printDetails'),
      ),
    );
  });

  test('a throwing backend never propagates to the log call', () {
    when(crashlytics.log(any)).thenThrow(StateError('no default app'));
    check(() => LogLayer.app.info('crumb')).returnsNormally();
  });
}
