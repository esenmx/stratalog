import 'dart:convert';

import 'package:chirp/chirp.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stratalog/stratalog.dart';
import 'package:stratalog_viewer/stratalog_viewer.dart';

void main() {
  late MemoryLogWriter writer;

  setUp(() {
    writer = MemoryLogWriter(capacity: 3);
    Chirp.root = ChirpLogger().addWriter(writer);
  });

  tearDown(() => Chirp.root = null);

  /// Captures every `Clipboard.setData` text until the test ends.
  List<String> mockClipboard(WidgetTester tester) {
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add(
            (call.arguments as Map<Object?, Object?>)['text']! as String,
          );
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    return copied;
  }

  test('ring buffer evicts the oldest beyond capacity and notifies', () {
    var notifications = 0;
    writer.addListener(() => notifications++);

    for (var i = 1; i <= 4; i++) {
      LogLayer.app.info('m$i');
    }

    expect(writer.records.map((r) => '${r.message}'), ['m2', 'm3', 'm4']);
    expect(notifications, 4);
  });

  testWidgets('renders records newest first and expands the body', (
    tester,
  ) async {
    LogLayer.network.warning('slow response', data: {'ms': 132});
    LogLayer.auth.info('signed in');

    await tester.pumpWidget(
      MaterialApp(home: LogViewerPage(writer: writer)),
    );

    expect(find.text('slow response'), findsOneWidget);
    expect(find.text('signed in'), findsOneWidget);
    final firstTile = tester.getTopLeft(find.text('signed in'));
    final secondTile = tester.getTopLeft(find.text('slow response'));
    expect(firstTile.dy < secondTile.dy, isTrue); // newest on top

    await tester.tap(find.text('slow response'));
    await tester.pumpAndSettle();
    expect(find.textContaining('"ms": 132'), findsOneWidget);
  });

  testWidgets('search filters by message and layer name', (tester) async {
    LogLayer.network.info('token refreshed');
    LogLayer.storage.info('migration applied');

    await tester.pumpWidget(
      MaterialApp(home: LogViewerPage(writer: writer)),
    );
    await tester.enterText(find.byType(TextField), 'Storage');
    await tester.pump();

    expect(find.text('migration applied'), findsOneWidget);
    expect(find.text('token refreshed'), findsNothing);
  });

  testWidgets('search matches text inside data payloads', (tester) async {
    LogLayer.network.info(
      'user loaded',
      data: {
        'user': {'id': 'usr_42'},
      },
    );
    LogLayer.storage.info('migration applied');

    await tester.pumpWidget(
      MaterialApp(home: LogViewerPage(writer: writer)),
    );
    await tester.enterText(find.byType(TextField), 'usr_42');
    await tester.pump();

    expect(find.text('user loaded'), findsOneWidget);
    expect(find.text('migration applied'), findsNothing);
  });

  testWidgets('payload hit auto-expands and highlights the match', (
    tester,
  ) async {
    LogLayer.network.info(
      'user loaded',
      data: {
        'user': {'id': 'usr_42'},
      },
    );

    await tester.pumpWidget(
      MaterialApp(home: LogViewerPage(writer: writer)),
    );
    await tester.enterText(find.byType(TextField), 'usr_42');
    await tester.pumpAndSettle();

    // Expanded without a tap.
    expect(find.textContaining('"usr_42"'), findsOneWidget);

    // The hit run carries a background highlight.
    final block = tester.widget<SelectableText>(
      find.byWidgetPredicate(
        (widget) => widget is SelectableText && widget.textSpan != null,
      ),
    );
    final spans = <InlineSpan>[];
    block.textSpan!.visitChildren((span) {
      spans.add(span);
      return true;
    });
    expect(
      spans.whereType<TextSpan>().map((span) => span.style?.backgroundColor),
      contains(isNotNull),
    );
  });

  testWidgets('refining a non-empty query re-applies payload auto-expand', (
    tester,
  ) async {
    LogLayer.network.info(
      'user loaded',
      data: {
        'user': {'id': 'usr_42'},
      },
    );

    await tester.pumpWidget(
      MaterialApp(home: LogViewerPage(writer: writer)),
    );
    await tester.enterText(find.byType(TextField), 'loaded'); // message hit
    await tester.pumpAndSettle();
    expect(find.textContaining('"usr_42"'), findsNothing);

    await tester.enterText(find.byType(TextField), 'usr_42'); // payload hit
    await tester.pumpAndSettle();
    expect(find.textContaining('"usr_42"'), findsOneWidget);
  });

  testWidgets('non-encodable payload falls back to toString under search', (
    tester,
  ) async {
    LogLayer.app.info(
      'odd payload',
      data: {
        'weird': {1: 'x'},
      },
    );

    await tester.pumpWidget(
      MaterialApp(home: LogViewerPage(writer: writer)),
    );
    await tester.enterText(find.byType(TextField), 'odd');
    await tester.pump();

    expect(find.text('odd payload'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('expand-all toggle reveals data blocks', (tester) async {
    LogLayer.network.warning('slow response', data: {'ms': 132});

    await tester.pumpWidget(
      MaterialApp(home: LogViewerPage(writer: writer)),
    );
    expect(find.textContaining('"ms": 132'), findsNothing);

    await tester.tap(find.byIcon(Icons.unfold_more));
    await tester.pumpAndSettle();
    expect(find.textContaining('"ms": 132'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.unfold_less));
    await tester.pumpAndSettle();
    expect(find.textContaining('"ms": 132'), findsNothing);
  });

  testWidgets('chips list distinct layers present in the buffer', (
    tester,
  ) async {
    LogLayer.network.info('token refreshed');
    LogLayer.network.info('profile fetched');
    LogLayer.storage.info('migration applied');

    await tester.pumpWidget(
      MaterialApp(home: LogViewerPage(writer: writer)),
    );

    expect(find.byType(FilterChip), findsNWidgets(2));
    expect(find.widgetWithText(FilterChip, 'Network'), findsOneWidget);
    expect(find.widgetWithText(FilterChip, 'Storage'), findsOneWidget);
  });

  testWidgets('chip toggles the layer filter on and off', (tester) async {
    LogLayer.network.info('token refreshed');
    LogLayer.storage.info('migration applied');

    await tester.pumpWidget(
      MaterialApp(home: LogViewerPage(writer: writer)),
    );
    await tester.tap(find.widgetWithText(FilterChip, 'Storage'));
    await tester.pump();

    expect(find.text('migration applied'), findsOneWidget);
    expect(find.text('token refreshed'), findsNothing);

    await tester.tap(find.widgetWithText(FilterChip, 'Storage'));
    await tester.pump();

    expect(find.text('migration applied'), findsOneWidget);
    expect(find.text('token refreshed'), findsOneWidget);
  });

  testWidgets('stale selection self-deactivates once its layer is evicted', (
    tester,
  ) async {
    LogLayer.network.info('token refreshed');

    await tester.pumpWidget(
      MaterialApp(home: LogViewerPage(writer: writer)),
    );
    await tester.tap(find.widgetWithText(FilterChip, 'Network'));
    await tester.pump();

    writer.clear();
    LogLayer.storage.info('migration applied');
    await tester.pump();

    expect(find.text('migration applied'), findsOneWidget);
    expect(find.text('No records'), findsNothing);
  });

  testWidgets('collapsed tile previews keep-key fields with a count tail', (
    tester,
  ) async {
    LogLayer.network.info(
      'user loaded',
      data: {
        'user': {'id': 'usr_42'},
        'status': 'ok',
        'payload': List.generate(20, (i) => 'row$i'),
      },
    );

    await tester.pumpWidget(
      MaterialApp(home: LogViewerPage(writer: writer)),
    );

    // Visible on the collapsed tile — no tap/expand before these asserts.
    expect(find.textContaining('id: usr_42'), findsOneWidget);
    expect(find.textContaining('status: ok'), findsOneWidget);
    expect(find.textContaining('3 fields'), findsOneWidget);
  });

  testWidgets('single-entry data pluralizes as 1 field', (tester) async {
    LogLayer.network.info('ping', data: {'ms': 132});

    await tester.pumpWidget(
      MaterialApp(home: LogViewerPage(writer: writer)),
    );

    expect(find.textContaining('1 field'), findsOneWidget);
    expect(find.textContaining('1 fields'), findsNothing);
  });

  testWidgets('keepKeys override drives the preview', (tester) async {
    LogLayer.network.info('order placed', data: {'orderId': 'ord_7'});

    await tester.pumpWidget(
      MaterialApp(
        home: LogViewerPage(writer: writer, keepKeys: const {'orderId'}),
      ),
    );

    expect(find.textContaining('orderId: ord_7'), findsOneWidget);
  });

  testWidgets('no preview line for records without data', (tester) async {
    LogLayer.app.info('plain message');

    await tester.pumpWidget(
      MaterialApp(home: LogViewerPage(writer: writer)),
    );

    expect(find.textContaining('fields'), findsNothing);
  });

  testWidgets('live updates arrive without rebuild plumbing', (tester) async {
    await tester.pumpWidget(
      MaterialApp(home: LogViewerPage(writer: writer)),
    );
    expect(find.text('No records'), findsOneWidget);

    LogLayer.app.info('late arrival');
    await tester.pump();

    expect(find.text('late arrival'), findsOneWidget);
  });

  testWidgets('Copy JSON puts valid JSON on the clipboard', (tester) async {
    final copied = mockClipboard(tester);
    LogLayer.network.info('payload', data: {'id': 42, 'ok': true});

    await tester.pumpWidget(
      MaterialApp(home: LogViewerPage(writer: writer)),
    );
    await tester.tap(find.text('payload'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Copy JSON'));
    await tester.pump();

    expect(copied, hasLength(1));
    expect(jsonDecode(copied.single), {'id': 42, 'ok': true});
  });

  testWidgets('copy-all embeds JSON-encoded data, not Dart toString', (
    tester,
  ) async {
    final copied = mockClipboard(tester);
    LogLayer.network.info('payload', data: {'id': 42});

    await tester.pumpWidget(
      MaterialApp(home: LogViewerPage(writer: writer)),
    );
    await tester.tap(find.byIcon(Icons.copy_all));
    await tester.pump();

    expect(copied.single, contains('"id": 42'));
    expect(copied.single, isNot(contains('{id: 42}')));
  });

  testWidgets('copy paths survive unencodable (cyclic) data', (tester) async {
    final copied = mockClipboard(tester);
    final cyclic = <String, Object?>{'id': 1};
    cyclic['self'] = cyclic;
    LogLayer.app.info('loop', data: cyclic);

    await tester.pumpWidget(
      MaterialApp(home: LogViewerPage(writer: writer)),
    );
    await tester.tap(find.text('loop'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Copy JSON'));
    await tester.pump();
    await tester.tap(find.byIcon(Icons.copy_all));
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(copied, hasLength(2));
    expect(copied.first, contains('self')); // toString fallback, not a crash
  });

  testWidgets('Copy JSON button is absent for records without data', (
    tester,
  ) async {
    LogLayer.app.error('boom', error: StateError('bad'));

    await tester.pumpWidget(
      MaterialApp(home: LogViewerPage(writer: writer)),
    );
    await tester.tap(find.text('boom'));
    await tester.pumpAndSettle();

    expect(find.text('Copy record'), findsOneWidget);
    expect(find.text('Copy JSON'), findsNothing);
  });
}
