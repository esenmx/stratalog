import 'package:checks/checks.dart';
import 'package:chirp/chirp.dart';
import 'package:stratalog/stratalog.dart';
import 'package:test/test.dart';

List<Type> _types() => [for (final w in Chirp.root.writers) w.runtimeType];

int _lastSeq() => switch (Chirp.root.writers
    .whereType<VmStreamWriter>()
    .single
    .history
    .last['seq']) {
  final int seq => seq,
  final other => throw StateError('expected int seq, got $other'),
};

// Tests run without dart.vm.product, so configureLogging() takes its debug
// branch — the default console writer under test is IdeDebugConsoleWriter.
// The release default is probed in release_console_writer_test.dart.
void main() {
  test('default debug console is the IDE writer', () {
    configureLogging();
    check(_types()).deepEquals([IdeDebugConsoleWriter, VmStreamWriter]);
  });

  test('vmStream: false leaves the VmStreamWriter out', () {
    configureLogging(vmStream: false);
    check(_types()).deepEquals([IdeDebugConsoleWriter]);
  });

  test('default debug console elides with defaultLayerElision', () {
    configureLogging();
    check((Chirp.root.writers.first as IdeDebugConsoleWriter).formatter)
        .isA<ElidingFormatter>()
      ..has((f) => f.inner, 'inner').isA<StructuredLogFormatter>()
      ..has(
        (f) => f.layerElision,
        'layerElision',
      ).identicalTo(defaultLayerElision);
  });

  test('elision: null leaves the debug formatter unwrapped', () {
    configureLogging(elision: null);
    check((Chirp.root.writers.first as IdeDebugConsoleWriter).formatter)
        .isA<StructuredLogFormatter>();
  });

  test('crashReporter: adds one CrashReporterWriter after the VM writer', () {
    final reporter = _NoopReporter();
    configureLogging(crashReporter: reporter);
    check(
      _types(),
    ).deepEquals([IdeDebugConsoleWriter, VmStreamWriter, CrashReporterWriter]);
    check(Chirp.root.writers.whereType<CrashReporterWriter>().single.reporter)
        .identicalTo(reporter);
  });

  test('minLevel: drops records below it', () {
    final records = <LogRecord>[];
    configureLogging(
      console: DelegatedChirpWriter(records.add),
      minLevel: .warning,
      vmStream: false,
    );
    LogLayer.app
      ..info('dropped')
      ..warning('kept');
    check(records.map((r) => '${r.message}')).deepEquals(['kept']);
  });

  test('configureLogging runs repeatedly without throwing', () {
    for (var i = 0; i < 3; i++) {
      configureLogging();
    }
    check(Chirp.root.writers.whereType<VmStreamWriter>()).length.equals(1);
  });

  test('console: replaces the default console writer instead of appending', () {
    final console = _StubWriter();
    configureLogging(console: console);

    check(Chirp.root.writers.first).identicalTo(console);
    check(_types()).deepEquals([_StubWriter, VmStreamWriter]);
  });

  test('console: with extra writers still adds no default console writer', () {
    final console = _StubWriter();
    final extra = _StubWriter();
    configureLogging(console: console, writers: [extra]);

    check(Chirp.root.writers.where((w) => w is! VmStreamWriter))
        .deepEquals([console, extra]);
  });

  test('re-calling configureLogging preserves history and monotonic seq', () {
    configureLogging(console: _StubWriter());
    LogLayer.app.info('first boot record');
    final firstSeq = _lastSeq();

    configureLogging(console: _StubWriter());
    LogLayer.app.info('after reconfigure');
    final secondWriter = Chirp.root.writers.whereType<VmStreamWriter>().single;

    final messages = secondWriter.history.map((r) => r['message']).toList();
    final tail = messages.sublist(messages.length - 2);
    check(tail).deepEquals(['first boot record', 'after reconfigure']);
    check(_lastSeq()).equals(firstSeq + 1);
  });

  test(
    'vmStream: false clears buffered history while keeping seq monotonic',
    () {
      configureLogging(console: _StubWriter());
      LogLayer.app.info('before opt-out');
      final seqBefore = _lastSeq();

      configureLogging(console: _StubWriter(), vmStream: false);
      configureLogging(console: _StubWriter());
      final writer = Chirp.root.writers.whereType<VmStreamWriter>().single;
      check(writer.history).isEmpty();

      LogLayer.app.info('after re-enable');
      final seqAfter = writer.history.single['seq']! as int;
      check(seqAfter).isGreaterThan(seqBefore);
    },
  );
}

final class _StubWriter extends ChirpWriter {
  @override
  void write(LogRecord record) {}
}

final class _NoopReporter implements CrashReporter {
  @override
  void recordError(
    Object error,
    StackTrace? stackTrace, {
    String? reason,
    bool fatal = false,
  }) {}

  @override
  void addBreadcrumb(String message, {Map<String, Object?>? data}) {}
}
