import 'dart:async';

import 'package:checks/checks.dart';
import 'package:chirp/chirp.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stratalog_firebase_auth/stratalog_firebase_auth.dart';

/// Identity equality, as the real `User`. Unlisted members throw (`Fake`).
final class _FakeUser({
  @override required final String uid,
  @override final String? email,
  @override final List<UserInfo> providerData = const [],
  @override final bool isAnonymous = false,
  @override final bool emailVerified = false,
}) extends Fake implements User;

/// Starts signed out; [emit] flips [currentUser] (a user signs in, `null`
/// signs out), each flip emitted on [authStateChanges] and [idTokenChanges],
/// which, as the plugin does, first deliver the current user to each new
/// listener. [refreshToken] emits on [idTokenChanges] only, [fail] errors
/// [authStateChanges]. Unlisted members throw (`Fake`).
final class _FakeFirebaseAuth extends Fake implements FirebaseAuth {
  final _authStateChanges = StreamController<User?>.broadcast();
  final _idTokenChanges = StreamController<User?>.broadcast();
  User? _currentUser;

  @override
  User? get currentUser => _currentUser;

  @override
  Stream<User?> authStateChanges() => _replayed(_authStateChanges.stream);

  @override
  Stream<User?> idTokenChanges() => _replayed(_idTokenChanges.stream);

  void emit(User? user) {
    _currentUser = user;
    _authStateChanges.add(user);
    _idTokenChanges.add(user);
  }

  void refreshToken() => _idTokenChanges.add(_currentUser);

  void fail(Object error) => _authStateChanges.addError(error);

  Stream<User?> _replayed(Stream<User?> changes) => .multi((listener) {
    listener.add(_currentUser);
    listener.onCancel = changes
        .listen(listener.add, onError: listener.addError)
        .cancel;
  });
}

void main() {
  late List<LogRecord> records;

  setUp(() {
    records = [];
    Chirp.root = ChirpLogger().addWriter(DelegatedChirpWriter(records.add));
  });

  tearDown(() => Chirp.root = null);

  Iterable<String> messages() => records.map((r) => '${r.message}');

  test('sign-in logs uid and OAuth provider ids, sign-out logs once', () async {
    final user = _FakeUser(
      uid: 'u1',
      email: 'jane.doe@example.com',
      providerData: [
        for (final id in ['google.com', 'apple.com'])
          .fromJson({
            'providerId': id,
            'uid': id,
            'isAnonymous': false,
            'isEmailVerified': true,
          }),
      ],
    );
    final auth = _FakeFirebaseAuth();
    FirebaseAuthLogger(auth).attach();

    auth.emit(user);
    await Future<void>.delayed(.zero);

    final signIn = records.firstWhere((r) => '${r.message}' == 'Signed in');
    check(signIn.level).equals(.success);
    check(signIn.data['uid']).equals('u1');
    check(signIn.data['providers'])
        .isA<List<Object?>>()
        .deepEquals(['google.com', 'apple.com']);

    auth.emit(null);
    await Future<void>.delayed(.zero);
    check(messages().where((m) => m == 'Signed out')).length.equals(1);
  });

  test('email is never logged, masked or verbatim', () async {
    final auth = _FakeFirebaseAuth();
    FirebaseAuthLogger(auth).attach();

    auth.emit(_FakeUser(uid: 'u1', email: 'jane.doe@example.com'));
    await Future<void>.delayed(.zero);

    final signIn = records.firstWhere((r) => '${r.message}' == 'Signed in');
    check(signIn.data).not((it) => it.containsKey('email'));
    check('${signIn.data}').not((it) => it.contains('example.com'));
  });

  test('cold start while signed out logs nothing', () async {
    final auth = _FakeFirebaseAuth();
    FirebaseAuthLogger(auth).attach();
    await Future<void>.delayed(.zero);

    check(messages().where((m) => m == 'Signed out')).isEmpty();
  });

  test('token refresh with unchanged uid traces refresh', () async {
    final auth = _FakeFirebaseAuth();
    FirebaseAuthLogger(auth).attach();
    auth.emit(_FakeUser(uid: 'u1'));
    await Future<void>.delayed(.zero);
    records.clear();

    auth.refreshToken();
    await Future<void>.delayed(.zero);

    check(messages()).deepEquals(['ID token refreshed']);
    check(records.single.level).equals(.trace);
    check(records.single.data).deepEquals({'uid': 'u1'});
  });

  test('re-attach does not double-log', () async {
    final auth = _FakeFirebaseAuth();
    FirebaseAuthLogger(auth)
      ..attach()
      ..attach();

    auth.emit(_FakeUser(uid: 'u1'));
    await Future<void>.delayed(.zero);

    check(messages().where((m) => m == 'Signed in')).length.equals(1);
  });

  test('detach stops logging', () async {
    final auth = _FakeFirebaseAuth();
    FirebaseAuthLogger(auth)
      ..attach()
      ..detach();

    auth.emit(_FakeUser(uid: 'u1'));
    await Future<void>.delayed(.zero);

    check(records).isEmpty();
  });

  test('an auth stream error logs a warning', () async {
    final auth = _FakeFirebaseAuth();
    FirebaseAuthLogger(auth).attach();
    final error = StateError('channel down');

    auth.fail(error);
    await Future<void>.delayed(.zero);

    check(messages()).deepEquals(['Auth stream error']);
    check(records.single.level).equals(.warning);
    check(records.single.error).identicalTo(error);
  });

  test('account flags are logged only when set', () async {
    final auth = _FakeFirebaseAuth();
    FirebaseAuthLogger(auth).attach();

    auth.emit(_FakeUser(uid: 'a1', isAnonymous: true));
    await Future<void>.delayed(.zero);
    auth.emit(_FakeUser(uid: 'v1', emailVerified: true));
    await Future<void>.delayed(.zero);

    check([
      for (final r in records)
        if ('${r.message}' == 'Signed in') r.data,
    ]).deepEquals([
      {'uid': 'a1', 'providers': <String>[], 'anonymous': true},
      {'uid': 'v1', 'providers': <String>[], 'email_verified': true},
    ]);
  });
}
