import 'dart:typed_data';

import 'package:chirp/chirp.dart';

/// chirp hands every writer the caller's own `data` map **by reference**
/// (synchronous dispatch loop, no copy) — any sink that *retains* a
/// [LogRecord] past the log call, rather than rendering it immediately, must
/// snapshot [data] at ingress or it silently aliases a collection the caller
/// keeps mutating.
///
/// Deep-copies every [Map] and [Iterable] reachable from [data] so the
/// result shares no mutable structure with the caller; scalars and
/// [TypedData] pass through by reference. Cycle-safe: a Map/Iterable
/// re-entered on the current traversal path renders as the string
/// `'<cycle>'` instead of recursing forever — detection is path-based, so
/// aliased (DAG) substructure copies normally at every occurrence.
Map<String, Object?> snapshotData(Map<String, Object?> data) {
  final seen = Set<Object?>.identity()..add(data);
  return {
    for (final MapEntry(:key, :value) in data.entries)
      key: _snapshot(value, seen),
  };
}

// `seen` holds the current traversal path, not all visited nodes — each node
// is removed after its subtree is walked, so an alias reached twice via
// different paths copies both times and only a true back-edge is a cycle.
Object? _snapshot(Object? value, Set<Object?> seen) {
  switch (value) {
    case TypedData():
      return value;
    case final Map<Object?, Object?> map:
      if (!seen.add(map)) return '<cycle>';
      // String-keyed maps keep their reified key type so downcasts on
      // retained records (`data['body'] as Map<String, Object?>`) survive
      // the copy; nested lists come back as List<Object?>.
      final copy = map is Map<String, Object?>
          ? <String, Object?>{
              for (final MapEntry(:key, :value) in map.entries)
                key: _snapshot(value, seen),
            }
          : <Object?, Object?>{
              for (final MapEntry(:key, :value) in map.entries)
                key: _snapshot(value, seen),
            };
      seen.remove(map);
      return copy;
    case final Iterable<Object?> iterable:
      if (!seen.add(iterable)) return '<cycle>';
      final copy = [for (final e in iterable) _snapshot(e, seen)];
      seen.remove(iterable);
      return copy;
    default:
      return value;
  }
}
