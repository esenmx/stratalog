import 'dart:collection';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:typed_data';

import 'package:chirp/chirp.dart';

import 'package:stratalog/src/palette.dart';
import 'package:stratalog/src/snapshot.dart';

/// Posts every record as structured JSON (record schema v1) on the
/// [streamId] VM service stream, for the `strata` terminal viewer.
///
/// A custom stream keeps these events out of the IDE console and the
/// DevTools Logging view. The newest [capacity] records stay in a ring
/// buffer served by the [historyExtension] service extension, so a viewer
/// attaching late still sees what came before it.
///
/// The payload is full — no `ElidingFormatter`. Never throws into chirp:
/// encoding and posting failures drop the record.
final class VmStreamWriter({
  /// Records kept for [historyExtension].
  final int capacity = 1000,

  /// Layer colors overlaid on [LogPalette.domains], as
  /// `StructuredLogFormatter.domainColors`.
  Map<String, ConsoleColor> domainColors = const {},

  /// Test seam: receives each record's JSON; defaults to
  /// `developer.postEvent` on [streamId].
  void Function(Map<String, Object?> record)? post,
}) extends ChirpWriter {
  /// Becomes the writer [historyExtension] serves when posting to the real VM
  /// stream; registers the extension once per isolate. Instances using the
  /// [post] test seam stay isolated in-memory.
  this {
    if (post == null) {
      _current = this;
      _trim(_sharedRing, capacity);
      _registerHistory();
    }
  }

  /// VM service stream the records are posted on.
  static const streamId = 'stratalog';

  /// `extensionKind` of every posted event.
  static const eventKind = 'stratalog.record';

  /// Service extension returning `{"records": [...]}`, oldest first.
  static const historyExtension = 'ext.stratalog.history';

  /// Record schema version, the `v` field.
  static const schemaVersion = 1;

  // Same merge as StructuredLogFormatter, so both sinks resolve one color.
  final Map<String, ConsoleColor> _colors = {
    ...LogPalette.domains,
    ...domainColors,
  };

  final bool _shared = post == null;
  final void Function(Map<String, Object?> record) _post = post ?? _postEvent;

  final ListQueue<Map<String, Object?>> _localRing = ListQueue();
  int _localSeq = 0;

  // Isolate-wide buffer and monotonic seq so re-calling configureLogging()
  // keeps boot history intact and never resets seq back to 1.
  static final ListQueue<Map<String, Object?>> _sharedRing = ListQueue();
  static int _sharedSeq = 0;
  static VmStreamWriter? _current;
  static bool _registered = false;

  /// Detaches the shared writer and clears its buffered history when
  /// `configureLogging(vmStream: false)` opts out, while keeping `_sharedSeq`
  /// monotonic if re-enabled later in the same isolate.
  static void detach() {
    _current = null;
    _sharedRing.clear();
  }

  @override
  bool get requiresCallerInfo => true;

  ListQueue<Map<String, Object?>> get _ring =>
      _shared ? _sharedRing : _localRing;

  /// The buffered records, oldest first.
  List<Map<String, Object?>> get history => .unmodifiable(_ring);

  @override
  void write(LogRecord record) {
    final seq = _shared ? ++_sharedSeq : ++_localSeq;
    try {
      final json = toRecordJson(record, seq);
      final ring = _ring..addLast(json);
      _trim(ring, capacity);
      _post(json);
    } on Object catch (_) {
      // Dropped: chirp's dispatch loop has no try/catch, so a throw here
      // would skip every writer queued after this one.
    }
  }

  static void _trim(ListQueue<Map<String, Object?>> ring, int capacity) {
    while (ring.isNotEmpty && ring.length > capacity) {
      ring.removeFirst();
    }
  }

  /// Record schema v1 for [record] numbered [seq]; optional keys are
  /// omitted when empty.
  Map<String, Object?> toRecordJson(LogRecord record, int seq) {
    final color = LogPalette.resolve(record.loggerName, overrides: _colors);
    final levelColor = LogPalette.levelColor(record.level);
    final caller = record.callerInfo;
    return {
      'v': schemaVersion,
      'seq': seq,
      'time': record.wallClock.toUtc().toIso8601String(),
      'level': record.level.name,
      'severity': record.level.severity,
      'layer': record.loggerName ?? 'App',
      'color': LogPalette.hex(color),
      'onColor': LogPalette.hex(LogPalette.onColor(color)),
      if (levelColor != null) 'levelColor': LogPalette.hex(levelColor),
      'message': record.message?.toString() ?? '',
      if (caller != null) ...{
        'file': caller.callerFileName,
        'line': caller.line,
        if (caller.callerMethod.isNotEmpty) 'method': caller.callerMethod,
      },
      if (record.data.isNotEmpty) 'data': _jsonSafe(snapshotData(record.data)),
      'error': ?record.error?.toString(),
      'stack': ?record.stackTrace?.toString(),
    };
  }

  static Object? _jsonSafe(Object? v) {
    switch (v) {
      case null || bool() || String() || int():
        return v;
      case final double d when d.isFinite:
        return d;
      case num():
        return v.toString();
      // Before Iterable: a Uint8List is an Iterable<int>.
      case final TypedData bytes:
        return '<${bytes.lengthInBytes}-byte blob elided>';
      case final Map<Object?, Object?> map:
        return <String, Object?>{
          for (final MapEntry(:key, :value) in map.entries)
            key.toString(): _jsonSafe(value),
        };
      case final Iterable<Object?> items:
        return [for (final item in items) _jsonSafe(item)];
      default:
        try {
          return v.toString();
        } on Object catch (_) {
          return '<unencodable: ${v.runtimeType}>';
        }
    }
  }

  static void _postEvent(Map<String, Object?> record) =>
      developer.postEvent(eventKind, record, stream: streamId);

  // registerExtension throws on a second registration, and configureLogging
  // may run many times — the handler reads _current instead. A failed
  // registration is retried by the next writer.
  static void _registerHistory() {
    if (_registered) return;
    try {
      developer.registerExtension(
        historyExtension,
        (method, params) async =>
            .result(jsonEncode({'records': _current?.history ?? const []})),
      );
      _registered = true;
    } on Object catch (_) {
      // Never fail boot: the writer is on by default.
    }
  }
}
