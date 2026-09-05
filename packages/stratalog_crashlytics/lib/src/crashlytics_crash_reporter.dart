import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:stratalog/stratalog.dart';

/// [CrashReporter] over Firebase Crashlytics:
///
/// ```dart
/// configureLogging(crashReporter: const CrashlyticsCrashReporter());
/// ```
///
/// `FirebaseCrashlytics.instance` is resolved lazily per forward, so
/// constructing the adapter before `Firebase.initializeApp` is fine — on a
/// build where Firebase never comes up (e.g. a secretless checkout without
/// config files), `.instance` throws and `CrashReporterWriter`'s catch-all
/// drops the forward instead of crashing the app.
final class const CrashlyticsCrashReporter([
  final FirebaseCrashlytics? _crashlytics,
]) implements CrashReporter {
  /// The optional constructor argument is injectable for tests; defaults to
  /// `FirebaseCrashlytics.instance` resolved lazily.
  this;

  FirebaseCrashlytics get _instance => _crashlytics ?? .instance;

  @override
  void recordError(
    Object error,
    StackTrace? stackTrace, {
    String? reason,
    bool fatal = false,
  }) {
    _instance
        .recordError(error, stackTrace, reason: reason, fatal: fatal)
        .ignore();
  }

  @override
  void addBreadcrumb(String message, {Map<String, Object?>? data}) {
    // Crashlytics breadcrumbs are single strings — inline the data map.
    _instance.log(data == null ? message : '$message $data').ignore();
  }
}
