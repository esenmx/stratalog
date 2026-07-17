import 'package:chirp/chirp.dart';
import 'package:flutter/material.dart';
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

  testWidgets('live updates arrive without rebuild plumbing', (tester) async {
    await tester.pumpWidget(
      MaterialApp(home: LogViewerPage(writer: writer)),
    );
    expect(find.text('No records'), findsOneWidget);

    LogLayer.app.info('late arrival');
    await tester.pump();

    expect(find.text('late arrival'), findsOneWidget);
  });
}
