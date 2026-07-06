import 'package:stratalog/stratalog.dart';

/// Console demo — `dart run example/main.dart`. In an app, call
/// [configureLogging] once before `runApp`; see the sibling stratalog_*
/// packages for Dio/gRPC/Riverpod/auto_route/FirebaseAuth taps.
void main() {
  configureLogging();

  LogLayer.app.info('Bootstrap complete', data: {'flavor': 'dev'});
  LogLayer.auth.success('Signed in', data: {'method': 'apple'});

  const payments = LogLayer('Payments');
  // Declared once, logged through everywhere — the variable IS the point.
  // ignore: cascade_invocations
  payments
    ..info('Charging card', data: {'orderId': 8123})
    ..warning('Card near expiry');

  try {
    throw StateError('demo failure');
  } on Object catch (e, s) {
    LogLayer.app.error('Flow failed', error: e, stackTrace: s);
  }
}
