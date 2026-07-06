import 'package:flutter/material.dart';
import 'package:stratalog/stratalog.dart';

/// No-op in debug, real backend in release — swap the body per project
/// (Crashlytics, Sentry, ...). See README for full adapter examples.
final class ConsoleCrashReporter implements CrashReporter {
  @override
  void recordError(
    Object error,
    StackTrace? stackTrace, {
    String? reason,
    bool fatal = false,
  }) {
    // FirebaseCrashlytics.instance.recordError(...) / Sentry.captureException(...)
  }

  @override
  void addBreadcrumb(String message) {
    // FirebaseCrashlytics.instance.log(message) / Sentry.addBreadcrumb(...)
  }
}

void main() {
  configureLogging(crashReporter: ConsoleCrashReporter());

  LogLayer.app.info('Bootstrap complete', data: {'flavor': 'dev'});
  runApp(const ExampleApp());
}

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: FilledButton(
            onPressed: () {
              LogLayer.auth.success('Signed in', data: {'method': 'apple'});
              const LogLayer('Payments').warning('Card near expiry');
              try {
                throw StateError('demo failure');
              } on Object catch (e, s) {
                LogLayer.app.error('Flow failed', error: e, stackTrace: s);
              }
            },
            child: const Text('Emit sample logs'),
          ),
        ),
      ),
    );
  }
}
