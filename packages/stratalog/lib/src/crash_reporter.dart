import 'package:chirp/chirp.dart';

/// Adapter boundary for crash backends — implement once per project against
/// whichever SDK it uses (Crashlytics, Sentry, Datadog, ...). Keeps this
/// package free of any vendor dependency.
///
/// Crashlytics:
/// ```dart
/// final class CrashlyticsReporter implements CrashReporter {
///   @override
///   void recordError(Object error, StackTrace? stackTrace,
///           {String? reason, bool fatal = false}) =>
///       FirebaseCrashlytics.instance
///           .recordError(error, stackTrace, reason: reason, fatal: fatal);
///
///   @override
///   void addBreadcrumb(String message) =>
///       FirebaseCrashlytics.instance.log(message);
/// }
/// ```
///
/// Sentry:
/// ```dart
/// final class SentryReporter implements CrashReporter {
///   @override
///   void recordError(Object error, StackTrace? stackTrace,
///           {String? reason, bool fatal = false}) =>
///       unawaited(Sentry.captureException(error, stackTrace: stackTrace,
///           hint: reason == null ? null : Hint.withMap({'reason': reason})));
///
///   @override
///   void addBreadcrumb(String message) =>
///       unawaited(Sentry.addBreadcrumb(Breadcrumb(message: message)));
/// }
/// ```
abstract interface class CrashReporter {
  /// Forward a report-worthy record to the backend.
  void recordError(
    Object error,
    StackTrace? stackTrace, {
    String? reason,
    bool fatal = false,
  });

  /// Attach a low-severity record as context for the next report.
  void addBreadcrumb(String message);
}

/// Bridges the log stream into a [CrashReporter]:
///
/// - records at/above [reportLevel] (default `error`) become
///   [CrashReporter.recordError] calls, `fatal` when above `error`;
/// - records at/above [breadcrumbLevel] (default `info`) but below
///   [reportLevel] become breadcrumbs — pass `null` to disable breadcrumbs.
///
/// `shouldReport` vetoes individual reports (breadcrumbs are unaffected).
/// Use it to keep *expected* failures out of the crash backend, e.g. typed
/// failures your repositories already map:
///
/// ```dart
/// CrashReporterWriter(reporter, shouldReport: (r) => r.error is! Failure)
/// ```
///
/// Reporter exceptions are swallowed: a logging call must never take the
/// app down because the crash SDK is unavailable.
final class CrashReporterWriter extends ChirpWriter {
  /// Gates itself at `breadcrumbLevel ?? reportLevel` via `setMinLogLevel`.
  CrashReporterWriter(
    this.reporter, {
    this.reportLevel = .error,
    this.breadcrumbLevel = .info,
    bool Function(LogRecord record)? shouldReport,
  }) : _shouldReport = shouldReport {
    setMinLogLevel(breadcrumbLevel ?? reportLevel);
  }

  /// Backend adapter all records are forwarded to.
  final CrashReporter reporter;

  /// Records at/above this become [CrashReporter.recordError] calls.
  final ChirpLogLevel reportLevel;

  /// Records in `[breadcrumbLevel, reportLevel)` become breadcrumbs;
  /// `null` disables breadcrumbs.
  final ChirpLogLevel? breadcrumbLevel;
  final bool Function(LogRecord record)? _shouldReport;

  @override
  void write(LogRecord record) {
    try {
      if (record.level >= reportLevel) {
        if (_shouldReport?.call(record) ?? true) {
          reporter.recordError(
            record.error ?? '${record.message}',
            record.stackTrace,
            reason: '[${record.loggerName ?? 'root'}] ${record.message}',
            fatal: record.level > .error,
          );
        }
      } else if (breadcrumbLevel != null) {
        reporter.addBreadcrumb(
          '[${record.loggerName ?? 'root'}/${record.level.name}] '
          '${record.message}',
        );
      }
    } on Object catch (_) {
      // Crash backend unavailable — drop the forward, never the app.
    }
  }
}
