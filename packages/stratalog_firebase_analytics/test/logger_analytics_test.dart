import 'package:checks/checks.dart';
import 'package:chirp/chirp.dart';
import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:stratalog/stratalog.dart';
import 'package:stratalog_firebase_analytics/stratalog_firebase_analytics.dart';

import 'logger_analytics_test.mocks.dart';

final class _CapturingWriter extends ChirpWriter {
  final records = <LogRecord>[];

  @override
  void write(LogRecord record) => records.add(record);
}

@GenerateNiceMocks([MockSpec<FirebaseAnalytics>()])
void main() {
  late _CapturingWriter writer;
  late MockFirebaseAnalytics firebase;
  late LoggerAnalytics analytics;

  setUp(() {
    writer = _CapturingWriter();
    Chirp.root = ChirpLogger().addWriter(writer);
    firebase = MockFirebaseAnalytics();
    when(
      firebase.logEvent(
        name: anyNamed('name'),
        parameters: anyNamed('parameters'),
        callOptions: anyNamed('callOptions'),
      ),
    ).thenAnswer((_) async {});
    when(
      firebase.logScreenView(
        screenName: anyNamed('screenName'),
        screenClass: anyNamed('screenClass'),
        parameters: anyNamed('parameters'),
      ),
    ).thenAnswer((_) async {});
    when(firebase.setUserId(id: anyNamed('id'))).thenAnswer((_) async {});
    analytics = LoggerAnalytics(firebase);
  });

  tearDown(() => Chirp.root = null);

  test('logEvent mirrors name and parameters, then forwards', () async {
    await analytics.logEvent(
      name: 'checkout_started',
      parameters: {'total': 42},
    );

    final record = writer.records.single;
    check('${record.message}').equals('event: checkout_started');
    check(record.data['total']).equals(42);
    check(record.loggerName).equals('Analytics');
    verify(
      firebase.logEvent(
        name: 'checkout_started',
        parameters: {'total': 42},
        callOptions: null,
      ),
    ).called(1);
  });

  test('logScreenView mirrors the screen name', () async {
    await analytics.logScreenView(screenName: 'Home');
    check('${writer.records.single.message}').equals('screen: Home');
    verify(
      firebase.logScreenView(
        screenName: 'Home',
        screenClass: null,
        parameters: null,
      ),
    ).called(1);
  });

  test('setUserId logs presence only, never the id value', () async {
    await analytics.setUserId('user-secret-42');

    check('${writer.records.single.message}').equals('user id set');
    check('${writer.records.single.data}')
        .not((it) => it.contains('user-secret-42'));
    verify(firebase.setUserId(id: 'user-secret-42')).called(1);
  });
}
