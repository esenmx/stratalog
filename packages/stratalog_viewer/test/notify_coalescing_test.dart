// Regression coverage for the MemoryLogWriter event-bus contract: write()
// enqueues synchronously but notification is a coalesced microtask, never
// synchronous with the log call. Before this contract, notifyListeners ran
// synchronously inside write() — a log emitted during the build phase (as
// riverpod/bloc taps do) while LogViewerPage is mounted marked the viewer's
// ListenableBuilder dirty mid-build -> FlutterError, and the README's
// FlutterError.onError -> LogLayer.ui.error wiring re-entered write() ->
// notifyListeners -> threw again: unbounded recursion.
import 'package:chirp/chirp.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stratalog/stratalog.dart';
import 'package:stratalog_viewer/stratalog_viewer.dart';

/// Stand-in for any producer that logs during build (e.g. a riverpod tap
/// observing a provider read via ref.watch inside a widget's build).
final class _BuildPhaseLogger extends StatefulWidget {
  const _BuildPhaseLogger({super.key});

  @override
  State<_BuildPhaseLogger> createState() => _BuildPhaseLoggerState();
}

final class _BuildPhaseLoggerState extends State<_BuildPhaseLogger> {
  bool _logOnBuild = false;

  void poke() => setState(() => _logOnBuild = true);

  @override
  Widget build(BuildContext context) {
    if (_logOnBuild) {
      _logOnBuild = false;
      LogLayer.state.info('provider transition observed during build');
    }
    return const SizedBox.shrink();
  }
}

void main() {
  late MemoryLogWriter writer;
  final loggerKey = GlobalKey<_BuildPhaseLoggerState>();

  Widget host() {
    return MaterialApp(
      home: Column(
        children: [
          Expanded(child: LogViewerPage(writer: writer)),
          _BuildPhaseLogger(key: loggerKey),
        ],
      ),
    );
  }

  setUp(() {
    writer = MemoryLogWriter();
    Chirp.root = ChirpLogger()..addWriter(writer);
  });

  tearDown(() => Chirp.root = null);

  testWidgets('logging during build with the viewer mounted does not raise '
      'a framework error', (tester) async {
    await tester.pumpWidget(host());
    expect(tester.takeException(), isNull); // clean mount

    loggerKey.currentState!.poke();
    await tester.pump();

    expect(tester.takeException(), isNull);
  });

  testWidgets('README FlutterError.onError wiring does not cascade on a '
      'single build-phase log', (tester) async {
    await tester.pumpWidget(host());
    expect(tester.takeException(), isNull);

    const cap = 25;
    var reports = 0;
    final original = FlutterError.onError;
    // Exact wiring from packages/stratalog/README.md "Uncaught errors",
    // except capped at [cap] so the test terminates instead of overflowing
    // the stack if the recursion regresses.
    FlutterError.onError = (details) {
      reports++;
      if (reports >= cap) return;
      if (details.silent) return;
      LogLayer.ui.error(
        details.context?.toDescription() ?? 'flutter framework error',
        error: details.exception,
        stackTrace: details.stack,
        data: {'library': ?details.library},
      );
    };
    try {
      final before = writer.records.length;
      loggerKey.currentState!.poke();
      await tester.pump();

      expect(
        reports,
        0,
        reason:
            'a single build-phase log must not recurse through '
            'FlutterError.onError',
      );
      expect(writer.records.length - before, 1);
    } finally {
      FlutterError.onError = original;
    }
  });

  test('N writes in one turn coalesce to a single notification', () async {
    var notifications = 0;
    writer.addListener(() => notifications++);

    for (var i = 0; i < 5; i++) {
      LogLayer.app.info('m$i');
    }
    expect(notifications, 0);

    await Future<void>.value();

    expect(notifications, 1);
  });

  testWidgets(
    'N writes in one turn coalesce to a single notifyListeners after pump',
    (tester) async {
      var notifications = 0;
      writer.addListener(() => notifications++);

      for (var i = 0; i < 5; i++) {
        LogLayer.app.info('m$i');
      }
      await tester.pump();

      expect(notifications, 1);
    },
  );

  test('data is snapshotted at ingress, not aliased', () async {
    final mutable = {'id': 'a'};
    LogLayer.app.info('mutable payload', data: mutable);
    mutable['id'] = 'b';

    expect(writer.records.single.data, {'id': 'a'});
  });

  test(
    'a microtask flushed after dispose does not call notifyListeners',
    () async {
      var notifications = 0;
      writer.addListener(() => notifications++);

      LogLayer.app.info('pending at dispose'); // schedules the microtask
      writer.dispose();

      await Future<void>.value(); // flush; must not assert or notify

      expect(notifications, 0);
    },
  );
}
