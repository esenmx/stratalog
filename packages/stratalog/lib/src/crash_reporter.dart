import 'package:chirp/chirp.dart';

import 'package:stratalog/src/snapshot.dart';

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
///   void addBreadcrumb(String message, {Map<String, Object?>? data}) =>
///       FirebaseCrashlytics.instance
///           .log(data == null ? message : '$message $data');
/// }
/// ```
///
/// Sentry:
/// ```dart
/// final class SentryReporter implements CrashReporter {
///   @override
///   void recordError(Object error, StackTrace? stackTrace,
///           {String? reason, bool fatal = false}) =>
///       Sentry.captureException(error, stackTrace: stackTrace,
///           hint: reason == null ? null : Hint.withMap({'reason': reason}))
///           .ignore();
///
///   @override
///   void addBreadcrumb(String message, {Map<String, Object?>? data}) =>
///       Sentry.addBreadcrumb(Breadcrumb(message: message, data: data))
///           .ignore();
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

  /// Attach a low-severity record as context for the next report. [data] is
  /// the record's structured `data:` map — under the breadcrumb discipline
  /// that means method paths, status/error codes, durations, entity ids;
  /// never message bodies (network taps keep bodies out of release records
  /// by default — see their `logBodies`).
  void addBreadcrumb(String message, {Map<String, Object?>? data});
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
          // record.data aliases the caller's live map (chirp hands writers
          // the reference, no copy) — a backend that retains the breadcrumb
          // past this call must not alias it.
          data: record.data.isEmpty ? null : snapshotData(record.data),
        );
      }
    } on Object catch (_) {
      // Crash backend unavailable — drop the forward, never the app.
    }
  }
}
