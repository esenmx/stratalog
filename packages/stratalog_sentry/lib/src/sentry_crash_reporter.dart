import 'dart:async';

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
/// the record's layer/message as an attached hint; breadcrumbs land on the
/// current scope. Before `Sentry.init` the hub is disabled and every call
/// no-ops — safe in any order.
final class SentryCrashReporter implements CrashReporter {
  /// Const: all state lives in Sentry's hub.
  const SentryCrashReporter();

  @override
  void recordError(
    Object error,
    StackTrace? stackTrace, {
    String? reason,
    bool fatal = false,
  }) {
    unawaited(
      Sentry.captureException(
        error,
        stackTrace: stackTrace,
        hint: reason == null ? null : Hint.withMap({'reason': reason}),
        withScope: (scope) =>
            scope.level = fatal ? SentryLevel.fatal : SentryLevel.error,
      ),
    );
  }

  @override
  void addBreadcrumb(String message) {
    unawaited(Sentry.addBreadcrumb(Breadcrumb(message: message)));
  }
}
