import 'package:chirp/chirp.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stratalog_firebase_auth/stratalog_firebase_auth.dart';

final class _CapturingWriter extends ChirpWriter {
  final records = <LogRecord>[];

  @override
  void write(LogRecord record) => records.add(record);
}

void main() {
  late _CapturingWriter writer;

  setUp(() {
    writer = _CapturingWriter();
    Chirp.root = ChirpLogger().addWriter(writer);
  });

  tearDown(() => Chirp.root = null);

  Iterable<String> messages() => writer.records.map((r) => '${r.message}');

  test('sign-in logs uid and OAuth provider ids, sign-out logs once', () async {
    final user = MockUser(
      uid: 'u1',
      email: 'jane.doe@example.com',
      providerData: [
        UserInfo.fromJson(const {
          'providerId': 'google.com',
          'uid': 'g1',
          'isAnonymous': false,
          'isEmailVerified': true,
        }),
        UserInfo.fromJson(const {
          'providerId': 'apple.com',
          'uid': 'a1',
          'isAnonymous': false,
          'isEmailVerified': true,
        }),
      ],
    );
    final auth = MockFirebaseAuth(mockUser: user);
    FirebaseAuthLogger(auth).attach();

    await auth.signInWithCredential(
      GoogleAuthProvider.credential(idToken: 't', accessToken: 'a'),
    );
    await Future<void>.delayed(Duration.zero);

    final signIn = writer.records.firstWhere(
      (r) => '${r.message}' == 'Signed in',
    );
    expect(signIn.level, ChirpLogLevel.success);
    expect(signIn.data['uid'], 'u1');
    expect(signIn.data['providers'], ['google.com', 'apple.com']);

    await auth.signOut();
    await Future<void>.delayed(Duration.zero);
    expect(messages().where((m) => m == 'Signed out').length, 1);
  });

  test('email is masked, never verbatim', () async {
    final auth = MockFirebaseAuth(
      mockUser: MockUser(uid: 'u1', email: 'jane.doe@example.com'),
    );
    FirebaseAuthLogger(auth).attach();

    await auth.signInWithEmailAndPassword(
      email: 'jane.doe@example.com',
      password: 'x',
    );
    await Future<void>.delayed(Duration.zero);

    final signIn = writer.records.firstWhere(
      (r) => '${r.message}' == 'Signed in',
    );
    expect(signIn.data['email'], 'j***@example.com');
    expect('${signIn.data}', isNot(contains('jane.doe@')));
  });

  test('cold start while signed out logs nothing', () async {
    final auth = MockFirebaseAuth();
    FirebaseAuthLogger(auth).attach();
    await Future<void>.delayed(Duration.zero);

    expect(messages().where((m) => m == 'Signed out'), isEmpty);
  });

  test('maskEmail handles degenerate inputs', () {
    expect(FirebaseAuthLogger.maskEmail('a@b.c'), 'a***@b.c');
    expect(FirebaseAuthLogger.maskEmail('no-at-sign'), '***');
    expect(FirebaseAuthLogger.maskEmail('@lead'), '***');
  });
}
