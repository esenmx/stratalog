import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:stratalog/stratalog.dart';

/// Taps FirebaseAuth into the Auth log layer — attach once after
/// `Firebase.initializeApp`:
///
/// ```dart
/// final authLogger = FirebaseAuthLogger(FirebaseAuth.instance)..attach();
/// ```
///
/// Logged signals:
/// - `authStateChanges` → `Signed in` (success) / `Signed out` (info), with
///   uid and the identity providers on the account — OAuth providers show
///   as their canonical IDs (`google.com`, `apple.com`, `password`,
///   `phone`, `oidc.*`, ...), so federated sign-ins are first-class.
/// - `idTokenChanges` with an unchanged uid → `ID token refreshed` (trace);
///   OAuth2 access/ID token rotation stays visible without duplicating the
///   sign-in/out records above.
///
/// `userChanges` is deliberately not subscribed: it is a superset of both
/// streams and would double-log every event.
///
/// PII discipline: emails are masked (`j***@example.com`), display names
/// and photo URLs never logged. Sign-in *failures* throw at the call site
/// (`FirebaseAuthException`) before any stream fires — log those where you
/// catch them, e.g. `LogLayer.auth.warning(...)`.
final class FirebaseAuthLogger {
  /// Logs [auth]'s streams to [logger] once [attach]ed.
  FirebaseAuthLogger(this.auth, {this.logger = .auth});

  /// The tapped FirebaseAuth instance.
  final FirebaseAuth auth;

  /// Destination layer.
  final LogLayer logger;

  final List<StreamSubscription<User?>> _subscriptions = [];
  String? _lastUid;

  /// Subscribes to the auth streams. Idempotent: re-attaching first detaches.
  void attach() {
    if (_subscriptions.isNotEmpty) detach();
    _lastUid = auth.currentUser?.uid;
    _subscriptions
      ..add(auth.authStateChanges().listen(_onAuthState, onError: _onError))
      ..add(auth.idTokenChanges().listen(_onIdToken, onError: _onError));
  }

  /// Cancels the subscriptions.
  void detach() {
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
  }

  void _onAuthState(User? user) {
    if (user == null) {
      // First emission on a signed-out cold start is state, not an event.
      if (_lastUid != null) logger.info('Signed out');
      _lastUid = null;
      return;
    }
    _lastUid = user.uid;
    logger.success('Signed in', data: _describe(user));
  }

  void _onIdToken(User? user) {
    // Sign-in/out transitions are already logged by _onAuthState; an
    // idToken event with an unchanged uid is a pure token refresh.
    if (user == null || user.uid != _lastUid) return;
    logger.trace('ID token refreshed', data: {'uid': user.uid});
  }

  void _onError(Object error, StackTrace stackTrace) {
    logger.warning('Auth stream error', error: error, stackTrace: stackTrace);
  }

  Map<String, Object?> _describe(User user) {
    return {
      'uid': user.uid,
      // OAuth2/OIDC providers surface here: google.com, apple.com, oidc.*
      'providers': [for (final info in user.providerData) info.providerId],
      if (user.isAnonymous) 'anonymous': true,
      if (user.email case final email?) 'email': maskEmail(email),
      if (user.emailVerified) 'email_verified': true,
    };
  }

  /// `jane.doe@example.com` → `j***@example.com`. Visible for tests.
  static String maskEmail(String email) {
    final at = email.indexOf('@');
    if (at <= 0) return '***';
    return '${email[0]}***${email.substring(at)}';
  }
}
