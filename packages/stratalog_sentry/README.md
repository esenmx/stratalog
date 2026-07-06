# stratalog_sentry

Sentry `CrashReporter` adapter for [stratalog](https://pub.dev/packages/stratalog).

```dart
configureLogging(crashReporter: const SentryCrashReporter());
```

`error`+ records become Sentry events (`critical`/`wtf` → `SentryLevel.fatal`), `info`+ records become scope breadcrumbs. Pure Dart on `package:sentry` — works identically under `sentry_flutter`, which shares the same hub. Before `Sentry.init` every call no-ops.

Veto expected failures or tune thresholds by constructing the writer yourself:

```dart
configureLogging(writers: [
  CrashReporterWriter(
    const SentryCrashReporter(),
    shouldReport: (record) => record.error is! Failure,
  ),
]);
```
