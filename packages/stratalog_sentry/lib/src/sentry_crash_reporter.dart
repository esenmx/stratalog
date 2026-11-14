import 'package:sentry/sentry.dart';
import 'package:stratalog/stratalog.dart';

/// [CrashReporter] over Sentry's static hub — works with both `sentry`
/// (server/CLI) and `sentry_flutter` (they share the hub). Init Sentry
/// first, then:
///
/// ```dart
/// configureLogging(crashReporter: const SentryCrashReporter());
/// ```
///
/// Reports become Sentry events (`fatal` maps to [SentryLevel.fatal]) with
/// the record's layer/message under the `stratalog` context's `reason` key
/// (also passed as a hint for `beforeSend`); breadcrumbs land on the
/// current scope. Before `Sentry.init` the hub is disabled and every call
/// no-ops — safe in any order.
final class SentryCrashReporter implements CrashReporter {
  /// Const: all state lives in Sentry's hub.
  const new();

  @override
  void recordError(
    Object error,
    StackTrace? stackTrace, {
    String? reason,
    bool fatal = false,
  }) {
    Sentry.captureException(
      error,
      stackTrace: stackTrace,
      hint: reason == null ? null : .withMap({'reason': reason}),
      withScope: (scope) async {
        scope.level = fatal ? .fatal : .error;
        if (reason != null) {
          await scope.setContexts('stratalog', {'reason': reason});
        }
      },
    ).ignore();
  }

  @override
  void addBreadcrumb(String message, {Map<String, Object?>? data}) {
    Sentry.addBreadcrumb(.new(message: message, data: data)).ignore();
  }
}
