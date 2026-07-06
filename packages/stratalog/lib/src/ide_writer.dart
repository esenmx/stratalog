import 'dart:developer' as developer;

import 'package:chirp/chirp.dart';

/// Emits via `dart:developer log()` instead of `print()` so the Flutter
/// daemon never chunks long lines mid-ANSI-sequence, while forcing 256-color
/// output on (chirp's built-in `DeveloperLogConsoleWriter` strips it).
class IdeDebugConsoleWriter extends ChirpWriter {
  /// Renders through [formatter] with [capabilities].
  IdeDebugConsoleWriter({
    required this.formatter,
    this.capabilities = const TerminalCapabilities(
      colorSupport: .ansi256,
    ),
  });

  /// Renders each record into the buffer handed to `dart:developer log()`.
  final ChirpFormatter formatter;

  /// Defaults to ANSI-256, which every IDE debug console renders.
  final TerminalCapabilities capabilities;

  @override
  bool get requiresCallerInfo => formatter.requiresCallerInfo;

  @override
  void write(LogRecord record) {
    final buffer = MessageBuffer.console(capabilities: capabilities);
    formatter.format(record, buffer);

    developer.log(buffer.toString(), level: mapToDeveloperLevel(record.level));
  }

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
