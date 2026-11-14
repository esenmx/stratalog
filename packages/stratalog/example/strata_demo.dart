import 'dart:io';

import 'package:stratalog/stratalog.dart';

/// Emitter for `tools/strata/e2e.sh`: boot records a late viewer only gets
/// through `ext.stratalog.history`, then live records, then exit.
///
/// `dart run --enable-vm-service example/strata_demo.dart`, then
/// `strata --plain <service uri>`.
Future<void> main() async {
  configureLogging();

  LogLayer.app.info('demo boot');
  LogLayer.network.info(
    '← 200 GET https://api.example.com/users/42',
    data: {
      'status': 200,
      'body': {
        'id': 42,
        'name': 'Jane',
        'tags': ['a', 'b'],
      },
    },
  );
  LogLayer.state.trace(
    'demo state',
    data: {
      'cart': {'items': 3, 'total': 1.5},
    },
  );
  LogLayer.storage.warning(
    'cache miss',
    error: StateError('stale entry'),
  );
  // e2e.sh attaches strata only after this line, so the records above can
  // only reach it as history.
  stdout.writeln('strata-demo: booted');

  await Future<void>.delayed(const Duration(seconds: 3));
  for (var i = 0; i < 40; i++) {
    LogLayer.app.info('live $i');
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
}
