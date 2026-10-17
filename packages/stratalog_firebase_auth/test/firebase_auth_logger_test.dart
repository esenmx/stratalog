import 'dart:async';

import 'package:chirp/chirp.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stratalog_firebase_auth/stratalog_firebase_auth.dart';

final class _CapturingWriter extends ChirpWriter {
  final records = <LogRecord>[];

  @override
  void write(LogRecord record) => records.add(record);
}

/// Identity equality, as the real `User`. Unlisted members throw (`Fake`).
final class _FakeUser({
  @override required final String uid,
  @override final String? email,
  @override final List<UserInfo> providerData = const [],
}) extends Fake implements User {
  @override
  bool get isAnonymous => false;

  @override
  bool get emailVerified => false;
}

/// Starts signed out; any sign-in signs in [signsInAs]. [currentUser] flips
/// on sign-in/out, each flip emitted on [authStateChanges] and
/// [idTokenChanges], which, as the plugin does, first deliver the current
/// user to each new listener. Unlisted members throw (`Fake`).
final class _FakeFirebaseAuth({final User? signsInAs})
    extends Fake
    implements FirebaseAuth {
  final _authStateChanges = StreamController<User?>.broadcast();
  final _idTokenChanges = StreamController<User?>.broadcast();
  User? _currentUser;

  @override
  User? get currentUser => _currentUser;

  @override
  Stream<User?> authStateChanges() => _replayed(_authStateChanges.stream);

  @override
  Stream<User?> idTokenChanges() => _replayed(_idTokenChanges.stream);

  @override
  Future<UserCredential> signInWithCredential(
    AuthCredential credential,
  ) async => _signIn();

  @override
  Future<UserCredential> signInWithEmailAndPassword({
    required String email,
    required String password,
  }) async => _signIn();

  @override
  Future<void> signOut() async => _emit(null);

  UserCredential _signIn() {
    final user = signsInAs ?? (throw StateError('No user to sign in.'));
    _emit(user);
    return _FakeUserCredential(user);
  }

  void _emit(User? user) {
    _currentUser = user;
    _authStateChanges.add(user);
    _idTokenChanges.add(user);
  }

  Stream<User?> _replayed(Stream<User?> changes) => .multi((listener) {
    listener.add(_currentUser);
    listener.onCancel = changes.listen(listener.add).cancel;
  });
}

final class _FakeUserCredential(@override final User user)
    extends Fake
    implements UserCredential;

void main() {
  late _CapturingWriter writer;

  setUp(() {
    writer = _CapturingWriter();
    Chirp.root = ChirpLogger().addWriter(writer);
  });

  tearDown(() => Chirp.root = null);

  Iterable<String> messages() => writer.records.map((r) => '${r.message}');

  test('sign-in logs uid and OAuth provider ids, sign-out logs once', () async {
    final user = _FakeUser(
      uid: 'u1',
      email: 'jane.doe@example.com',
      providerData: [
        .fromJson(const {
          'providerId': 'google.com',
          'uid': 'g1',
          'isAnonymous': false,
          'isEmailVerified': true,
        }),
        .fromJson(const {
          'providerId': 'apple.com',
          'uid': 'a1',
          'isAnonymous': false,
          'isEmailVerified': true,
        }),
      ],
    );
    final auth = _FakeFirebaseAuth(signsInAs: user);
    FirebaseAuthLogger(auth).attach();

    await auth.signInWithCredential(
      GoogleAuthProvider.credential(idToken: 't', accessToken: 'a'),
    );
    await Future<void>.delayed(.zero);

    final signIn = writer.records.firstWhere(
      (r) => '${r.message}' == 'Signed in',
    );
    expect(signIn.level, ChirpLogLevel.success);
    expect(signIn.data['uid'], 'u1');
    expect(signIn.data['providers'], ['google.com', 'apple.com']);

    await auth.signOut();
    await Future<void>.delayed(.zero);
    expect(messages().where((m) => m == 'Signed out').length, 1);
  });

  test('email is never logged, masked or verbatim', () async {
    final auth = _FakeFirebaseAuth(
      signsInAs: _FakeUser(uid: 'u1', email: 'jane.doe@example.com'),
    );
    FirebaseAuthLogger(auth).attach();

    await auth.signInWithEmailAndPassword(
      email: 'jane.doe@example.com',
      password: 'x',
    );
    await Future<void>.delayed(.zero);

    final signIn = writer.records.firstWhere(
      (r) => '${r.message}' == 'Signed in',
    );
    expect(signIn.data, isNot(contains('email')));
    expect('${signIn.data}', isNot(contains('example.com')));
  });

  test('cold start while signed out logs nothing', () async {
    final auth = _FakeFirebaseAuth();
    FirebaseAuthLogger(auth).attach();
    await Future<void>.delayed(.zero);

    expect(messages().where((m) => m == 'Signed out'), isEmpty);
  });
}
