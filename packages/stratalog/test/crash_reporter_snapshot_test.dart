import 'package:checks/checks.dart';
import 'package:chirp/chirp.dart';
import 'package:stratalog/stratalog.dart';
import 'package:test/test.dart';

final class _CapturingReporter implements CrashReporter {
  final breadcrumbs = <(String, Map<String, Object?>?)>[];

  @override
  void recordError(
    Object error,
    StackTrace? stackTrace, {
    String? reason,
    bool fatal = false,
  }) {}

  @override
  void addBreadcrumb(String message, {Map<String, Object?>? data}) =>
      breadcrumbs.add((message, data));
}

/// Emulates a Sentry-style backend: `addBreadcrumb` kicks off async
/// serialization of the data map (chunked transport write), exactly like the
/// `.ignore()`d `Sentry.addBreadcrumb(...)` adapter in the CrashReporter docs.
final class _StreamingReporter implements CrashReporter {
  final serialized = StringBuffer();
  Future<void>? pending;

  @override
  void recordError(
    Object error,
    StackTrace? stackTrace, {
    String? reason,
    bool fatal = false,
  }) {}

  @override
  void addBreadcrumb(String message, {Map<String, Object?>? data}) {
    if (data != null) pending = _serialize(data);
  }

  Future<void> _serialize(Map<String, Object?> data) async {
    for (final e in data.entries) {
      serialized.write('${e.key}=${e.value};');
      await Future<void>.delayed(Duration.zero);
    }
  }
}

void main() {
  tearDown(() => Chirp.root = null);

  ChirpLogger loggerWith(CrashReporterWriter writer) {
    Chirp.root = ChirpLogger().addWriter(writer);
    return Chirp.root.child(name: 'Auth');
  }

  test('breadcrumb data is snapshotted at write time, not aliased', () {
    final reporter = _CapturingReporter();
    final stats = <String, Object?>{'attempt': 1};
    loggerWith(CrashReporterWriter(reporter)).info('retrying', data: stats);

    // Caller keeps reusing its own map after the log call.
    stats['attempt'] = 2;

    final captured = reporter.breadcrumbs.single.$2;
    check(
      identical(captured, stats),
      because: 'writer must hand the SDK a snapshot, not the live caller map',
    ).isFalse();
    check(captured).isNotNull().deepEquals({'attempt': 1});
  });

  test(
    'caller mutation after log does not corrupt deferred serialization',
    () async {
      final reporter = _StreamingReporter();
      final stats = <String, Object?>{
        'duration_ms': 12,
        'error_code': 'geo.404',
      };
      loggerWith(CrashReporterWriter(reporter)).info('crumb', data: stats);

      // SDK began serializing (sync until first await); caller mutates its map.
      stats['retries'] = 3;

      await check(reporter.pending!).completes();
    },
  );
}
