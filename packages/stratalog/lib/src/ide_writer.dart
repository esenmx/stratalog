import 'dart:async';
import 'dart:developer' as developer;

import 'package:chirp/chirp.dart';

/// Emits via `dart:developer log()` instead of `print()` so the Flutter
/// daemon never chunks long lines mid-ANSI-sequence, while forcing 256-color
/// output on (chirp's built-in `DeveloperLogConsoleWriter` strips it).
///
/// Records written in one event-loop turn are coalesced into a single `log()`
/// call, flushed by microtask: the IDE's DAP handler fetches each event's
/// string asynchronously and drops the future, so back-to-back events can
/// reach the debug console out of order — one call per burst keeps the burst
/// atomic and ordered (cross-batch reordering by the DAP remains possible).
/// Trap: lines still buffered when the process hard-crashes before the
/// microtask runs are lost — debug-console output only; uncaught errors
/// surface via `FlutterError` separately.
class IdeDebugConsoleWriter({
  /// Renders each record into the buffer handed to `dart:developer log()`.
  required final ChirpFormatter formatter,

  /// Defaults to ANSI-256, which every IDE debug console renders.
  final TerminalCapabilities capabilities = const TerminalCapabilities(
    colorSupport: .ansi256,
  ),
  void Function(String message, int level)? emit,
}) extends ChirpWriter {
  /// Renders through [formatter] with [capabilities].
  ///
  /// [emit] is the test seam: receives the joined batch and the highest
  /// mapped level in it; defaults to a `dart:developer log()` wrapper.
  this;

  final void Function(String message, int level) _emit = emit ?? _developerLog;

  final List<String> _pending = [];
  int _pendingLevel = 0;

  @override
  bool get requiresCallerInfo => formatter.requiresCallerInfo;

  @override
  void write(LogRecord record) {
    final buffer = MessageBuffer.console(capabilities: capabilities);
    formatter.format(record, buffer);

    // Caller zone on purpose: tester.pump/fakeAsync must be able to drive
    // the flush deterministically in tests.
    if (_pending.isEmpty) scheduleMicrotask(_flush);
    _pending.add(buffer.toString());
    final level = mapToDeveloperLevel(record.level);
    if (level > _pendingLevel) _pendingLevel = level;
  }

  void _flush() {
    final message = _pending.join('\n');
    final level = _pendingLevel;
    _pending.clear();
    _pendingLevel = 0;
    _emit(message, level);
  }

  static void _developerLog(String message, int level) =>
      developer.log(message, level: level);

  /// Maps chirp severities onto `package:logging`-style values, which is
  /// what `dart:developer log(level:)` expects.
  static int mapToDeveloperLevel(ChirpLogLevel level) {
    return switch (level.severity) {
      < 100 => 300, // trace -> FINEST
      < 200 => 500, // debug -> FINE
      < 400 => 800, // info/notice/success -> INFO
      < 500 => 900, // warning -> WARNING
      < 600 => 1000, // error -> SEVERE
      _ => 1200, // critical/wtf -> SHOUT
    };
  }
}
