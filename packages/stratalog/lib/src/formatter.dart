import 'dart:convert';
import 'dart:typed_data';

import 'package:chirp/chirp.dart';
import 'package:chirp/chirp_spans.dart';

import 'package:stratalog/src/palette.dart';

/// Draws a colored left border along every line of [child] — one visual
/// gutter per record instead of a full box.
final class LeftBordered({
  /// Gutter color; `null` renders in the terminal's default foreground.
  required final ConsoleColor? color,
  super.child,
}) extends SingleChildSpan {
  /// Wraps [child] with a [color]ed gutter.
  this;

  @override
  void render(ConsoleMessageBuffer buffer) {
    final child = this.child;
    if (child == null) return;
    final temp = buffer.createChildBuffer();
    child.render(temp);
    final content = temp.toString();
    if (content.isEmpty) return;

    final lines = content.split('\n');
    // Trim one trailing empty segment so the border never emits a dangling
    // bar; sections compose via explicit NewLine()s, not trailing newlines.
    var lastIdx = lines.length - 1;
    if (lastIdx > 0 && lines[lastIdx].isEmpty) lastIdx--;

    for (var i = 0; i <= lastIdx; i++) {
      buffer
        ..pushStyle(foreground: color)
        ..write(i == 0 ? ' ├─ ' : ' │  ')
        ..popStyle();
      if (i < lastIdx) {
        buffer.writeln(lines[i]);
      } else {
        buffer.write(lines[i]);
      }
    }
  }
}

/// Header + left-bordered body sections (message / data / error / stack).
///
/// ```text
/// ▐ Auth ▌ [warning] 14:03:22.114 • auth_repository.dart:87 • refresh
///  ├─ Token refresh slow
///  │  Data: {"duration_ms": 132}
/// ```
///
/// Layers in [rawDataLayers] drop the gutter — the entire body renders
/// flush-left at column 0 for copy-pastable SQL and JSON (the `▸` below is
/// the producer's own message prefix, not a formatter addition):
///
/// ```text
/// ▐ Storage ▌ [trace] 14:03:22.114 • dao.dart:42
/// ▸ SELECT * FROM users
/// WHERE id = ?
/// Data ▼
/// {
///   "args": [42],
///   "duration_ms": 3
/// }
/// ```
///
/// Theme adaptivity: every hue comes from [LogPalette]'s contrast-verified
/// set — readable on solarized and soft-gray backgrounds, light or dark.
/// Badge text flips black/white by background luminance; low levels render
/// in the terminal's default color.
final class StructuredLogFormatter({
  Map<String, ConsoleColor>? domainColors,

  /// Renders the wall-clock time in the header.
  final bool showTimestamp = true,

  /// Renders `file:line • method` in the header. Costs a
  /// `StackTrace.current` per log — turn off before pointing this formatter
  /// at a hot path.
  final bool showLocation = true,

  /// Layers whose entire body renders flush-left with no gutter — copyable
  /// multi-line SQL in messages and valid, selectable JSON straight off the
  /// console. Pass `const {}` to restore the gutter everywhere.
  final Set<String> rawDataLayers = defaultRawDataLayers,
}) extends SpanBasedFormatter {
  /// [domainColors] entries overlay [LogPalette.domains].
  this;

  /// Badge/gutter color per layer name, overlaid on [LogPalette.domains].
  final Map<String, ConsoleColor> domainColors = domainColors == null
      ? LogPalette.domains
      : {...LogPalette.domains, ...domainColors};

  /// String literals, not `LogLayer` field accesses — a const field access
  /// isn't a const expression (precedent: [LogPalette.domains]).
  static const Set<String> defaultRawDataLayers = {'Network', 'Storage'};

  @override
  bool get requiresCallerInfo => showLocation;

  @override
  LogSpan buildSpan(LogRecord record) {
    final themeColor = _colorForLogger(record.loggerName);
    final levelColor = LogPalette.levelColor(record.level);
    // Raw layers drop the gutter entirely — every body line at column 0 so
    // multi-line SQL messages and JSON payloads copy-paste clean. No
    // formatter-added marker: producers carry their own (drift's `▸ `/`✗ `,
    // dio's `←`/`→`); the next record's colored badge header separates.
    final isRaw = rawDataLayers.contains(record.loggerName);
    LogSpan bordered(LogSpan child) =>
        isRaw ? child : LeftBordered(color: themeColor, child: child);

    LogSpan section(String title, LogSpan body) => bordered(
      SpanSequence(
        children: [
          AnsiStyled(
            foreground: LogPalette.error,
            bold: true,
            child: PlainText(title),
          ),
          NewLine(),
          body,
        ],
      ),
    );

    return SpanSequence(
      children: [
        _header(record, themeColor, levelColor),
        NewLine(),
        // INDENTED BODY SECTION(S)
        SpanSequence(
          children: [
            // MESSAGE
            bordered(
              AnsiStyled(
                foreground: record.level >= .warning ? levelColor : null,
                child: LogMessage(record.message),
              ),
            ),
            // DATA
            if (record.data.isNotEmpty) ...[
              NewLine(),
              if (isRaw) ...[
                AnsiStyled(dim: true, child: PlainText('Data ▼')),
                NewLine(),
                PlainText(_encodeData(record.data)),
              ] else
                LeftBordered(
                  color: themeColor,
                  child: SpanSequence(
                    children: [
                      AnsiStyled(dim: true, child: PlainText('Data: ')),
                      PlainText(_encodeData(record.data)),
                    ],
                  ),
                ),
            ],
            if (record.error != null) ...[
              NewLine(),
              section(
                'Error:',
                AnsiStyled(
                  foreground: LogPalette.errorBody,
                  child: ErrorSpan(record.error),
                ),
              ),
            ],
            if (record.stackTrace case final stackTrace?) ...[
              NewLine(),
              section(
                'Stack Trace:',
                AnsiStyled(dim: true, child: StackTraceSpan(stackTrace)),
              ),
            ],
          ],
        ),
      ],
    );
  }

  LogSpan _header(
    LogRecord record,
    ConsoleColor themeColor,
    ConsoleColor? levelColor,
  ) {
    final callerInfo = showLocation ? record.callerInfo : null;
    return SpanSequence(
      children: [
        AnsiStyled(
          foreground: LogPalette.onColor(themeColor),
          background: themeColor,
          bold: true,
          child: PlainText(' ${record.loggerName ?? "App"} '),
        ),
        Whitespace(),
        AnsiStyled(
          foreground: levelColor,
          bold: true,
          child: BracketedLogLevel(record.level),
        ),
        Whitespace(),
        AnsiStyled(
          dim: true, // dim adapts to the terminal theme
          child: SpanSequence(
            children: [
              if (showTimestamp) Timestamp(record.wallClock),
              if (callerInfo?.callerFileName case final file?) ...[
                if (showTimestamp) PlainText(' • '),
                DartSourceCodeLocation(fileName: file, line: callerInfo?.line),
              ],
              if (callerInfo?.callerMethod case final method?) ...[
                PlainText(' • '),
                MethodName(method),
              ],
            ],
          ),
        ),
      ],
    );
  }

  /// Maximum line width (including indentation and `"key": ` prefix) for
  /// collapsing a deepest (leaf) object or array onto a single line.
  static const int maxInlineDataWidth = 80;

  /// Formats [data] as indented JSON while collapsing deepest (leaf) objects
  /// and arrays — those containing no non-empty [Map] or [Iterable] children —
  /// onto a single line when they fit within [maxInlineWidth].
  ///
  /// Throws [JsonUnsupportedObjectError] if a map contains non-[String] keys
  /// or [JsonCyclicError] on cyclic structures.
  static String formatJson(
    Map<String, Object?> data, {
    int maxInlineWidth = maxInlineDataWidth,
  }) => _formatJsonValue(data, 0, 0, .identity(), maxInlineWidth);

  /// chirp's writer dispatch loop has no try/catch around a sink — a throw
  /// here would skip every writer queued after this one. `_jsonFallback`
  /// handles a non-encodable leaf; this belt covers what it can't, cyclic
  /// data throwing from the encoder's own walk before any leaf is reached.
  static String _encodeData(Map<String, Object?> data) {
    try {
      return formatJson(data);
    } on Object catch (_) {
      return '<unencodable: ${data.runtimeType}>';
    }
  }

  static bool _isCompound(Object? v) => switch (v) {
    TypedData() => false,
    final Map<Object?, Object?> m => m.isNotEmpty,
    final Iterable<Object?> it => it.isNotEmpty,
    _ => false,
  };

  static String _formatJsonValue(
    Object? value,
    int depth,
    int prefixWidth,
    Set<Object> active,
    int maxInlineWidth,
  ) {
    String child(Object? v, int prefix) =>
        _formatJsonValue(v, depth + 1, prefix, active, maxInlineWidth);
    switch (value) {
      case null || bool() || String():
        return jsonEncode(value);
      case final num n when n.isFinite:
        return jsonEncode(n);
      case final TypedData bytes:
        return jsonEncode('<${bytes.lengthInBytes}-byte blob elided>');
      case final Map<Object?, Object?> map:
        if (map.isEmpty) return '{}';
        if (!active.add(map)) throw JsonCyclicError(map);
        try {
          final budget = map.values.any(_isCompound)
              ? null
              : maxInlineWidth - prefixWidth;
          final parts = <String>[];
          for (final MapEntry(:key, :value) in map.entries) {
            if (key is! String) throw JsonUnsupportedObjectError(map);
            final k = jsonEncode(key);
            parts.add('$k: ${child(value, (depth + 1) * 2 + k.length + 2)}');
          }
          return _container(parts, '{', '}', depth, budget);
        } finally {
          active.remove(map);
        }
      case final Iterable<Object?> list:
        if (list.isEmpty) return '[]';
        if (!active.add(list)) throw JsonCyclicError(list);
        try {
          final budget = list.any(_isCompound)
              ? null
              : maxInlineWidth - prefixWidth;
          final parts = [for (final item in list) child(item, (depth + 1) * 2)];
          return _container(parts, '[', ']', depth, budget);
        } finally {
          active.remove(list);
        }
      default:
        return jsonEncode(_jsonFallback(value));
    }
  }

  /// [parts] between [open] and [close]: on one line when that fits
  /// [inlineBudget] (`null` for containers with non-empty children: never),
  /// else one part per line, indented one level past [depth].
  static String _container(
    List<String> parts,
    String open,
    String close,
    int depth,
    int? inlineBudget,
  ) {
    if (inlineBudget != null) {
      final inline = '$open${parts.join(', ')}$close';
      if (inline.length <= inlineBudget) return inline;
    }
    final indent = '  ' * depth;
    return '$open\n$indent  ${parts.join(',\n$indent  ')}\n$indent$close';
  }

  static Object? _jsonFallback(Object? o) {
    if (o case final TypedData bytes) {
      return '<${bytes.lengthInBytes}-byte blob elided>';
    }
    try {
      return o.toString();
    } on Object catch (_) {
      return '<unencodable: ${o.runtimeType}>';
    }
  }

  ConsoleColor _colorForLogger(String? name) =>
      LogPalette.resolve(name, overrides: domainColors);
}
