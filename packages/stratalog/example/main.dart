import 'package:chirp/chirp.dart';
import 'package:stratalog/stratalog.dart';

/// Console demo — `dart run example/main.dart`. In an app, call
/// [configureLogging] once before `runApp`; see the sibling stratalog_*
/// packages for Dio/gRPC/Riverpod/auto_route/FirebaseAuth taps.
void main() {
  configureLogging(
    // Terminal `dart run` drops `dart:developer log()` output — replace the
    // IDE writer with a print-backed one so the demo prints outside an IDE
    // debug console, wrapped in the same per-layer elision the debug console
    // gets. `console:` replaces rather than appends: a second console writer
    // would double-emit every record in an IDE session. An app needs only
    // `configureLogging()`.
    console: PrintConsoleWriter(
      formatter: ElidingFormatter.of(
        StructuredLogFormatter(),
        const ElisionConfig(),
        layerElision: defaultLayerElision,
      ),
      capabilities: const TerminalCapabilities(colorSupport: .ansi256),
    ),
  );

  LogLayer.app.info('Bootstrap complete', data: {'flavor': 'dev'});
  LogLayer.auth.success('Signed in', data: {'method': 'apple'});

  const payments = LogLayer('Payments');
  // Declared once, logged through everywhere — the variable IS the point.
  payments
    ..info('Charging card', data: {'orderId': 8123})
    ..warning('Card near expiry');

  // Network/Storage bodies render flush-left — SQL and JSON copy-pastable
  // as-is.
  LogLayer.network.info(
    '← 200 GET https://api.example.com/users/42',
    data: {
      'status': 200,
      'body': {'id': 42, 'name': 'Jane'},
    },
  );
  LogLayer.storage.trace(
    '''
SELECT * FROM users
WHERE id = ?''',
    data: {
      'args': [42],
      'duration_ms': 3,
    },
  );

  try {
    throw StateError('demo failure');
  } on Object catch (e, s) {
    LogLayer.app.error('Flow failed', error: e, stackTrace: s);
  }

  // Per-layer elision: Network JSON is a copy-out artifact → full payload;
  // the same oversized data on an unlisted layer (App) still elides.
  final bigBody = {
    'id': 'ord_8123',
    'note': 'n' * 1200, // past the 1024-char default budget
    'items': List<Map<String, Object?>>.generate(
      40, // past the 32-item default budget
      (i) => {'sku': 'SKU-$i', 'qty': i},
    ),
  };
  LogLayer.network.info('POST /orders → 201', data: {'body': bigBody});
  LogLayer.app.info('Same payload through App', data: {'body': bigBody});
}
