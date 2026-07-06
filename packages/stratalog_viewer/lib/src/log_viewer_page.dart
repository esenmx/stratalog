import 'dart:convert';

import 'package:chirp/chirp.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:stratalog/stratalog.dart';
import 'package:stratalog_viewer/src/memory_log_writer.dart';

/// In-app log browser over a [MemoryLogWriter] — newest first, layer badges
/// in stratalog's palette colors, minimum-level filter, substring search,
/// tap to expand data/error/stack, long-press to copy a record.
///
/// ```dart
/// Navigator.push(context,
///     MaterialPageRoute(builder: (_) => LogViewerPage(writer: memoryWriter)));
/// ```
class LogViewerPage extends StatefulWidget {
  /// Browses [writer]'s buffer; updates live as records arrive.
  const LogViewerPage({required this.writer, super.key});

  /// The buffer to browse.
  final MemoryLogWriter writer;

  @override
  State<LogViewerPage> createState() => _LogViewerPageState();
}

class _LogViewerPageState extends State<LogViewerPage> {
  ChirpLogLevel _minLevel = ChirpLogLevel.trace;
  String _query = '';

  static const _levels = [
    ChirpLogLevel.trace,
    ChirpLogLevel.debug,
    ChirpLogLevel.info,
    ChirpLogLevel.notice,
    ChirpLogLevel.warning,
    ChirpLogLevel.error,
  ];

  List<LogRecord> _visible() {
    final query = _query.toLowerCase();
    return [
      for (final record in widget.writer.records.reversed)
        if (record.level >= _minLevel &&
            (query.isEmpty ||
                '${record.message}'.toLowerCase().contains(query) ||
                (record.loggerName ?? '').toLowerCase().contains(query)))
          record,
    ];
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          decoration: const InputDecoration(
            hintText: 'Search message or layer',
            border: InputBorder.none,
          ),
          onChanged: (value) => setState(() => _query = value),
        ),
        actions: [
          PopupMenuButton<ChirpLogLevel>(
            icon: const Icon(Icons.filter_list),
            tooltip: 'Minimum level',
            initialValue: _minLevel,
            onSelected: (level) => setState(() => _minLevel = level),
            itemBuilder: (context) => [
              for (final level in _levels)
                PopupMenuItem(value: level, child: Text(level.name)),
            ],
          ),
          IconButton(
            icon: const Icon(Icons.copy_all),
            tooltip: 'Copy visible records',
            onPressed: () => _copy(_visible().map(_describe).join('\n\n')),
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Clear',
            onPressed: widget.writer.clear,
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: widget.writer,
        builder: (context, _) {
          final records = _visible();
          if (records.isEmpty) {
            return const Center(child: Text('No records'));
          }
          return ListView.builder(
            itemCount: records.length,
            itemBuilder: (context, index) => _RecordTile(
              record: records[index],
              onCopy: () => _copy(_describe(records[index])),
            ),
          );
        },
      ),
    );
  }

  void _copy(String text) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('Copied')));
  }

  String _describe(LogRecord record) {
    final buffer = StringBuffer(
      '${record.formattedTime} [${record.loggerName ?? 'App'}]'
      ' ${record.level.name}: ${record.message}',
    );
    if (record.data.isNotEmpty) buffer.write('\n  data: ${record.data}');
    if (record.error != null) buffer.write('\n  error: ${record.error}');
    if (record.stackTrace case final stack?) buffer.write('\n$stack');
    return buffer.toString();
  }
}

class _RecordTile extends StatelessWidget {
  const _RecordTile({required this.record, required this.onCopy});

  final LogRecord record;
  final VoidCallback onCopy;

  static Color _toColor(ConsoleColor color) =>
      Color.fromARGB(0xff, color.r, color.g, color.b);

  @override
  Widget build(BuildContext context) {
    final name = record.loggerName ?? 'App';
    final layerColor = _toColor(
      LogLayer.declaredColorOf(name) ?? LogPalette.colorFor(name),
    );
    final levelConsoleColor = LogPalette.levelColor(record.level);
    final levelColor = levelConsoleColor == null
        ? Theme.of(context).colorScheme.onSurfaceVariant
        : _toColor(levelConsoleColor);
    final hasBody = record.data.isNotEmpty ||
        record.error != null ||
        record.stackTrace != null;

    final title = Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: ' $name ',
            style: TextStyle(
              backgroundColor: layerColor,
              color: _onBadge(layerColor),
              fontWeight: FontWeight.bold,
            ),
          ),
          TextSpan(
            text: ' [${record.level.name}]',
            style: TextStyle(color: levelColor, fontWeight: FontWeight.bold),
          ),
          TextSpan(
            text: ' ${record.formattedTime}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
    final message = Text(
      '${record.message}',
      style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
    );

    if (!hasBody) {
      return ListTile(
        dense: true,
        title: title,
        subtitle: message,
        onLongPress: onCopy,
      );
    }
    return ExpansionTile(
      dense: true,
      title: title,
      subtitle: message,
      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      expandedCrossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (record.data.isNotEmpty)
          _MonoBlock(
            const JsonEncoder.withIndent('  ', _stringify)
                .convert(record.data),
          ),
        if (record.error case final error?) _MonoBlock('Error: $error'),
        if (record.stackTrace case final stack?) _MonoBlock('$stack'),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            onPressed: onCopy,
            icon: const Icon(Icons.copy, size: 16),
            label: const Text('Copy'),
          ),
        ),
      ],
    );
  }

  static Object? _stringify(Object? o) => o.toString();

  /// Same luminance flip as the console badge text.
  static Color _onBadge(Color background) {
    final luma = 0.299 * (background.r * 255) +
        0.587 * (background.g * 255) +
        0.114 * (background.b * 255);
    return luma > 140 ? Colors.black : Colors.white;
  }
}

class _MonoBlock extends StatelessWidget {
  const _MonoBlock(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: SelectableText(
        text,
        style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
      ),
    );
  }
}
