import 'package:chirp/chirp.dart';

/// A named logging domain ("layer") with an optional dedicated color —
/// a const value you declare once and log through everywhere:
///
/// ```dart
/// const payments = LogLayer('Payments', color: Ansi256.springGreen4_29);
/// payments.info('Order captured', data: {'id': 8123});
/// ```
///
/// Omit [color] to get a stable, contrast-verified hue from
/// `LogPalette.hashPool`; when picking one, sweep candidates with
/// `dart run tool/contrast_report.dart` so it stays readable on light and
/// dark backgrounds, and stay off the red/orange/hot-pink severity band.
///
/// The nine pre-defined layers each name a *concern*, not a library, and the
/// set is deliberately non-overlapping — one crisp home per record. There is
/// intentionally no `lifecycle` or `background` layer: an `AppLifecycleState`
/// change *is* an OS signal ([platform]); background-task *scheduling* logs
/// to [platform] while the work a task performs logs to its own domain.
///
/// The backing [logger] resolves against the *current* `Chirp.root` on every
/// access, so replacing the root (tests, reconfiguration) never strands a
/// layer — unlike a `static final` child, which binds to whichever root
/// existed at first touch.
final class LogLayer {
  /// Declares the layer named [name]; [color] paints its badge and gutter.
  const LogLayer(this.name, {this.color});

  /// Badge text and `LogRecord.loggerName` for records logged through this
  /// layer.
  final String name;

  /// Badge/gutter color; `null` falls back to `LogPalette.colorFor(name)`.
  final ConsoleColor? color;

  /// Bootstrap, config, DI wiring, business logic; the fallback layer.
  static const app = LogLayer('App');

  /// State-management transitions (provider lifecycles, mutations).
  static const state = LogLayer('State');

  /// Navigation: pushes/pops, tab switches, deep links, guards.
  static const route = LogLayer('Route');

  /// Presentation: widget/render issues, media loading, animations.
  static const ui = LogLayer('UI');

  /// HTTP/WebSocket traffic.
  static const network = LogLayer('Network');

  /// Local persistence: database, prefs, secure storage, files, caches.
  static const storage = LogLayer('Storage');

  /// Identity: sign-in/out, token refresh, session expiry.
  static const auth = LogLayer('Auth');

  /// The Flutter↔OS boundary: channels, plugins, permissions, lifecycle.
  static const platform = LogLayer('Platform');

  /// Instrumentation: events dispatched, crash-report forwarding.
  static const analytics = LogLayer('Analytics');

  /// Declared color of the layer named [name], if it has logged yet —
  /// consulted by `StructuredLogFormatter` (a record can only exist after
  /// its layer's [logger] was accessed, so registration always precedes
  /// rendering).
  static ConsoleColor? declaredColorOf(String name) => _declaredColors[name];
  static final Map<String, ConsoleColor> _declaredColors = {};

  static ChirpLogger? _cachedRoot;
  static final Map<String, ChirpLogger> _cache = {};

  /// The chirp logger backing this layer under the current root — the escape
  /// hatch for APIs that want a raw `ChirpLogger`.
  ChirpLogger get logger {
    final ChirpLogger root;
    try {
      root = Chirp.root;
      // ignore: avoid_catching_errors -- rethrown with a package-level hint
    } on StateError {
      throw StateError(
        'Chirp.root is not configured. '
        'Call configureLogging() before logging through a LogLayer.',
      );
    }
    if (!identical(root, _cachedRoot)) {
      _cache.clear();
      _cachedRoot = root;
    }
    if (color case final color?) _declaredColors[name] = color;
    return _cache.putIfAbsent(name, () => root.child(name: name));
  }

  /// Logs [message] at [level]. The level helpers below cover the standard
  /// levels; use this for custom [ChirpLogLevel]s.
  void log(
    Object? message, {
    ChirpLogLevel level = .info,
    Object? error,
    StackTrace? stackTrace,
    Map<String, Object?>? data,
  }) {
    // skipFrames hides the delegation frame so caller info points at the
    // call site, not this file.
    logger.log(
      message,
      level: level,
      error: error,
      stackTrace: stackTrace,
      data: data,
      skipFrames: 1,
    );
  }

  /// Logs at `trace`.
  void trace(
    Object? message, {
    Object? error,
    StackTrace? stackTrace,
    Map<String, Object?>? data,
  }) => _log(.trace, message, error, stackTrace, data);

  /// Logs at `debug`.
  void debug(
    Object? message, {
    Object? error,
    StackTrace? stackTrace,
    Map<String, Object?>? data,
  }) => _log(.debug, message, error, stackTrace, data);

  /// Logs at `info`.
  void info(
    Object? message, {
    Object? error,
    StackTrace? stackTrace,
    Map<String, Object?>? data,
  }) => _log(.info, message, error, stackTrace, data);

  /// Logs at `notice`.
  void notice(
    Object? message, {
    Object? error,
    StackTrace? stackTrace,
    Map<String, Object?>? data,
  }) => _log(.notice, message, error, stackTrace, data);

  /// Logs at `success`.
  void success(
    Object? message, {
    Object? error,
    StackTrace? stackTrace,
    Map<String, Object?>? data,
  }) => _log(.success, message, error, stackTrace, data);

  /// Logs at `warning`.
  void warning(
    Object? message, {
    Object? error,
    StackTrace? stackTrace,
    Map<String, Object?>? data,
  }) => _log(.warning, message, error, stackTrace, data);

  /// Logs at `error`.
  void error(
    Object? message, {
    Object? error,
    StackTrace? stackTrace,
    Map<String, Object?>? data,
  }) => _log(.error, message, error, stackTrace, data);

  /// Logs at `wtf` (What a Terrible Failure).
  void wtf(
    Object? message, {
    Object? error,
    StackTrace? stackTrace,
    Map<String, Object?>? data,
  }) => _log(.wtf, message, error, stackTrace, data);

  void _log(
    ChirpLogLevel level,
    Object? message,
    Object? error,
    StackTrace? stackTrace,
    Map<String, Object?>? data,
  ) {
    // skipFrames hides the two delegation frames so caller info points at
    // the call site, not this file.
    logger.log(
      message,
      level: level,
      error: error,
      stackTrace: stackTrace,
      data: data,
      skipFrames: 2,
    );
  }

  @override
  String toString() => 'LogLayer($name)';
}
