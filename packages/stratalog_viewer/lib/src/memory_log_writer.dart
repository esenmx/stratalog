import 'dart:collection';

import 'package:chirp/chirp.dart';
import 'package:flutter/foundation.dart';

/// Ring-buffer chirp writer backing the in-app viewer — keeps the newest
/// [capacity] records in memory and notifies listeners on every write.
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

  /// Snapshot of the buffered records, oldest first.
  List<LogRecord> get records => List.unmodifiable(_records);

  @override
  void write(LogRecord record) {
    _records.addLast(record);
    if (_records.length > capacity) _records.removeFirst();
    notifyListeners();
  }

  /// Empties the buffer.
  void clear() {
    _records.clear();
    notifyListeners();
  }
}
