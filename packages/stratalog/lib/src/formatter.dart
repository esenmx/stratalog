import 'dart:convert';

import 'package:chirp/chirp.dart';
import 'package:chirp/chirp_spans.dart';

import 'package:stratalog/src/layers.dart';
import 'package:stratalog/src/palette.dart';

/// Draws a colored left border along every line of [child] — one visual
/// gutter per record instead of a full box.
class LeftBordered extends SingleChildSpan {
  /// Wraps [child] with a [color]ed gutter.
  LeftBordered({required this.color, super.child});

  /// Gutter color; `null` renders in the terminal's default foreground.
  final ConsoleColor? color;

  @override
  void render(ConsoleMessageBuffer buffer) {
    if (child == null) return;
    final temp = buffer.createChildBuffer();
    child!.render(temp);
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
/// ▐ Network ▌ [warning] 14:03:22.114 • api_client.dart:87 • fetchUser
///  ├─ ✗ 404 GET https://api.example.com/users/42
///  │  Data: {"duration_ms": 132}
/// ```
///
/// Theme adaptivity: every hue comes from [LogPalette]'s contrast-verified
/// set — readable on solarized and soft-gray backgrounds, light or dark.
/// Badge text flips black/white by background luminance; low levels render
/// in the terminal's default color.
class StructuredLogFormatter extends SpanBasedFormatter {
  /// [domainColors] entries overlay [LogPalette.domains].
  StructuredLogFormatter({
    Map<String, ConsoleColor>? domainColors,
    this.showTimestamp = true,
    this.showLocation = true,
  }) : domainColors = domainColors == null
           ? LogPalette.domains
           : {...LogPalette.domains, ...domainColors};

  /// Badge/gutter color per layer name, overlaid on [LogPalette.domains].
  final Map<String, ConsoleColor> domainColors;

  /// Renders the wall-clock time in the header.
  final bool showTimestamp;

  /// Renders `file:line • method` in the header. Costs a
  /// `StackTrace.current` per log — turn off before pointing this formatter
  /// at a hot path.
  final bool showLocation;

  @override
  bool get requiresCallerInfo => showLocation;

  @override
  LogSpan buildSpan(LogRecord record) {
    final themeColor = _colorForLogger(record.loggerName);
    final levelColor = LogPalette.levelColor(record.level);

    final bodySpans = <LogSpan>[
      // MESSAGE
      LeftBordered(
        color: themeColor,
        child: AnsiStyled(
          foreground: record.level >= .warning ? levelColor : null,
          child: LogMessage(record.message),
        ),
      ),
    ];

    // DATA
    if (record.data.isNotEmpty) {
      final jsonStr = const JsonEncoder.withIndent(
        '  ',
        _jsonFallback,
      ).convert(record.data);
      bodySpans.addAll([
        NewLine(),
        LeftBordered(
          color: themeColor,
          child: SpanSequence(
            children: [
              AnsiStyled(dim: true, child: PlainText('Data: ')),
              PlainText(jsonStr),
            ],
          ),
        ),
      ]);
    }

    // ERROR
    if (record.error != null) {
      bodySpans.addAll([
        NewLine(),
        LeftBordered(
          color: themeColor,
          child: SpanSequence(
            children: [
              AnsiStyled(
                foreground: LogPalette.error,
                bold: true,
                child: PlainText('Error:'),
              ),
              NewLine(),
              AnsiStyled(
                foreground: LogPalette.errorBody,
                child: ErrorSpan(record.error),
              ),
            ],
          ),
        ),
      ]);
    }

    // STACK TRACE
    if (record.stackTrace case final stackTrace?) {
      bodySpans.addAll([
        NewLine(),
        LeftBordered(
          color: themeColor,
          child: SpanSequence(
            children: [
              AnsiStyled(
                foreground: LogPalette.error,
                bold: true,
                child: PlainText('Stack Trace:'),
              ),
              NewLine(),
              AnsiStyled(dim: true, child: StackTraceSpan(stackTrace)),
            ],
          ),
        ),
      ]);
    }

    final callerInfo = showLocation ? record.callerInfo : null;
    return SpanSequence(
      children: [
        // HEADER
        SpanSequence(
          children: [
            AnsiStyled(
              foreground: _badgeTextOn(themeColor),
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
                  if (callerInfo?.callerFileName != null) ...[
                    if (showTimestamp) PlainText(' • '),
                    DartSourceCodeLocation(
                      fileName: callerInfo!.callerFileName,
                      line: callerInfo.line,
                    ),
                  ],
                  if (callerInfo?.callerMethod != null) ...[
                    PlainText(' • '),
                    MethodName(callerInfo!.callerMethod),
                  ],
                ],
              ),
            ),
          ],
        ),
        NewLine(),
        // INDENTED BODY SECTION(S)
        SpanSequence(children: bodySpans),
      ],
    );
  }

  static Object? _jsonFallback(Object? o) => o.toString();

  /// Pure black/white (silver washes out on mid-tone badges), flipped by
  /// perceived background luminance so any badge color stays legible.
  static ConsoleColor _badgeTextOn(ConsoleColor bg) {
    final luma = 0.299 * bg.r + 0.587 * bg.g + 0.114 * bg.b;
    return luma > 140 ? Ansi256.grey0_16 : Ansi256.grey100_231;
  }

  ConsoleColor _colorForLogger(String? name) {
    if (name == null) return LogPalette.app;
    return domainColors[name] ??
        LogLayer.declaredColorOf(name) ?? // color declared on the LogLayer
        LogPalette.colorFor(name); // stable hash for unlisted layers
  }
}
