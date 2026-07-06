// Prints a representative sample of every layer/level/section through the
// real formatter with ANSI-256 forced on — eyeball the format in any
// terminal, or pipe it into an ANSI->HTML converter.
//
// dart run tool/preview.dart
import 'package:chirp/chirp.dart';
import 'package:stratalog/src/formatter.dart';
import 'package:stratalog/src/layers.dart';

void main() {
  Chirp.root = ChirpLogger().addConsoleWriter(
    formatter: StructuredLogFormatter(),
    output: print,
    capabilities: const TerminalCapabilities(
      colorSupport: .ansi256,
    ),
  );

  LogLayer.app.info('Bootstrap complete', data: {'flavor': 'dev', 'ms': 412});
  LogLayer.state.trace('~ userProvider | AsyncLoading ➔ AsyncData(User(42))');
  LogLayer.route.trace('push{SplashRoute{} => HomeRoute{tab: feed}}');
  LogLayer.ui.debug('Hero animation skipped: image not yet decoded');
  LogLayer.network.trace(
    '→ GET https://api.example.com/users/42',
    data: {
      'headers': {'content-type': 'application/json', 'authorization': '***'},
    },
  );
  LogLayer.network.warning(
    '✗ 404 GET https://api.example.com/users/42',
    data: {'duration_ms': 132},
  );
  LogLayer.storage.debug('Migration 12 -> 13 applied in 18ms');
  LogLayer.auth.notice('Session refreshed', data: {'expires_in': 3600});
  LogLayer.analytics.trace('event: checkout_started');
  LogLayer.platform.info('AppLifecycleState.resumed');
  const LogLayer('Payments').success('Order #8123 captured');

  try {
    throw StateError('emulated failure');
  } on Object catch (e, s) {
    LogLayer.app.error(
      'Unhandled flow failure',
      data: {'orderId': 8123},
      error: e,
      stackTrace: s,
    );
  }

  LogLayer.app.wtf('Invariant violated: cart total negative');
}
