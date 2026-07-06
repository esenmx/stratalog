# stratalog_crashlytics

Firebase Crashlytics `CrashReporter` adapter for [stratalog](https://pub.dev/packages/stratalog).

```dart
configureLogging(crashReporter: const CrashlyticsCrashReporter());
```

`error`+ records become Crashlytics reports (`critical`/`wtf` → `fatal: true`), `info`+ records become Crashlytics log breadcrumbs. `FirebaseCrashlytics.instance` resolves lazily per forward, so a build where Firebase never initializes degrades to a no-op instead of crashing.

Veto expected failures or tune thresholds by constructing the writer yourself:

```dart
configureLogging(writers: [
  CrashReporterWriter(
    const CrashlyticsCrashReporter(),
    shouldReport: (record) => record.error is! Failure,
  ),
]);
```
