import 'dart:async';
import 'dart:collection';

import 'package:chirp/chirp.dart';
import 'package:flutter/foundation.dart';
import 'package:stratalog/stratalog.dart';

/// Ring-buffer chirp writer backing the in-app viewer — keeps the newest
/// [capacity] records in memory.
///
/// An async event bus, not a synchronous callback: [write] enqueues onto the
/// ring buffer immediately (chirp dispatches writers synchronously, so this
/// runs in the logging call's own stack) but snapshots `data` at ingress via
/// [snapshotData] so a retained record never aliases a map the caller keeps
/// mutating. Listener notification is a single microtask coalesced across
/// every write/clear in the same turn — never synchronous — so a log emitted
/// mid-build cannot mark a listening widget dirty during that same build.
///
/// ```dart
/// final memoryWriter = MemoryLogWriter();
/// configureLogging(writers: [memoryWriter]);
/// // later: LogViewerPage(writer: memoryWriter)
/// ```
final class MemoryLogWriter extends ChirpWriter with ChangeNotifier {
  /// Keeps the newest [capacity] records.
  MemoryLogWriter({this.capacity = 1000});

  /// Ring-buffer size; the oldest record is evicted beyond it.
  final int capacity;

  final ListQueue<LogRecord> _records = ListQueue();
  bool _notifyScheduled = false;
  bool _disposed = false;

  /// Snapshot of the buffered records, oldest first.
  List<LogRecord> get records => .unmodifiable(_records);

  @override
  void write(LogRecord record) {
    final stored = record.data.isEmpty
        ? record
        : record.copyWith(data: snapshotData(record.data));
    _records.addLast(stored);
    if (_records.length > capacity) _records.removeFirst();
    _scheduleNotify();
  }

  /// Empties the buffer.
  void clear() {
    _records.clear();
    _scheduleNotify();
  }

  void _scheduleNotify() {
    if (_notifyScheduled) return;
    _notifyScheduled = true;
    // Caller zone on purpose: tester.pump/fakeAsync must be able to drive
    // the flush deterministically in tests.
    scheduleMicrotask(() {
      _notifyScheduled = false;
      if (_disposed) return;
      notifyListeners();
    });
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
