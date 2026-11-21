import 'package:checks/checks.dart';
import 'package:chirp/chirp.dart';
import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:stratalog_firebase_analytics/stratalog_firebase_analytics.dart';

import 'logger_analytics_test.mocks.dart';

@GenerateNiceMocks([MockSpec<FirebaseAnalytics>()])
void main() {
  late List<LogRecord> records;
  late MockFirebaseAnalytics firebase;
  late LoggerAnalytics analytics;

  setUp(() {
    records = [];
    Chirp.root = ChirpLogger().addWriter(DelegatedChirpWriter(records.add));
    firebase = MockFirebaseAnalytics();
    analytics = LoggerAnalytics(firebase);
  });

  tearDown(() => Chirp.root = null);

  test('logEvent mirrors name and parameters, then forwards', () async {
    await analytics.logEvent(
      name: 'checkout_started',
      parameters: {'total': 42},
    );

    final record = records.single;
    check('${record.message}').equals('event: checkout_started');
    check(record.data['total']).equals(42);
    check(record.loggerName).equals('Analytics');
    verify(
      firebase.logEvent(name: 'checkout_started', parameters: {'total': 42}),
    ).called(1);
  });

  test('logScreenView mirrors screenName and screenClass', () async {
    await analytics.logScreenView(screenName: 'Home', screenClass: 'HomePage');
    final record = records.single;
    check('${record.message}').equals('screen: Home');
    check(record.data['screen_class']).equals('HomePage');
    verify(firebase.logScreenView(screenName: 'Home', screenClass: 'HomePage'))
        .called(1);
  });

  for (final (label, name, screenClass, parameters, message, data) in [
    (
      'screenClass alone',
      null,
      'HomePage',
      null,
      'screen: HomePage',
      <String, Object>{},
    ),
    ('no screen', null, null, null, 'screen: unknown', <String, Object>{}),
    (
      'parameters',
      'Home',
      'HomePage',
      {'tab': 'feed'},
      'screen: Home',
      {'screen_class': 'HomePage', 'tab': 'feed'},
    ),
  ]) {
    test('logScreenView with $label mirrors $message, then forwards', () async {
      await analytics.logScreenView(
        screenName: name,
        screenClass: screenClass,
        parameters: parameters,
      );

      check('${records.single.message}').equals(message);
      check(records.single.data).deepEquals(data);
      verify(
        firebase.logScreenView(
          screenName: name,
          screenClass: screenClass,
          parameters: parameters,
        ),
      ).called(1);
    });
  }

  test('setUserId logs presence only, never the id value', () async {
    await analytics.setUserId('user-secret-42');

    check('${records.single.message}').equals('user id set');
    check('${records.single.data}').not((it) => it.contains('user-secret-42'));
    verify(firebase.setUserId(id: 'user-secret-42')).called(1);
  });

  test('setUserId(null) logs user id cleared, then forwards', () async {
    await analytics.setUserId(null);

    check('${records.single.message}').equals('user id cleared');
    verify(firebase.setUserId()).called(1);
  });

  test('setUserProperty mirrors name and value, then forwards', () async {
    await analytics.setUserProperty(name: 'plan', value: 'pro');

    check('${records.single.message}').equals('user property: plan');
    check(records.single.data).deepEquals({'value': 'pro'});
    verify(firebase.setUserProperty(name: 'plan', value: 'pro')).called(1);
  });
}
