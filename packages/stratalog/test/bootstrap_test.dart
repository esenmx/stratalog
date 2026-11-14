import 'package:checks/checks.dart';
import 'package:chirp/chirp.dart';
import 'package:stratalog/stratalog.dart';
import 'package:test/test.dart';

// Tests run without dart.vm.product, so configureLogging() takes its debug
// branch — the default console writer under test is IdeDebugConsoleWriter.
// The release default is probed in release_console_writer_test.dart.
void main() {
  test('default debug console is the IDE writer', () {
    configureLogging();
    final writers = Chirp.root.writers;
    check(writers.whereType<IdeDebugConsoleWriter>()).length.equals(1);
    check(writers.whereType<PrintConsoleWriter>()).isEmpty();
  });

  test('debug adds one VmStreamWriter by default', () {
    configureLogging();
    final writers = Chirp.root.writers;
    check(writers.whereType<VmStreamWriter>()).length.equals(1);
    check(writers.length).equals(2);
  });

  test('vmStream: false leaves the VmStreamWriter out', () {
    configureLogging(vmStream: false);
    final writers = Chirp.root.writers;
    check(writers.whereType<VmStreamWriter>()).isEmpty();
    check(writers.single).isA<IdeDebugConsoleWriter>();
  });

  test('console: override still gets the VmStreamWriter', () {
    final console = _StubWriter();
    configureLogging(console: console);
    check(Chirp.root.writers.whereType<VmStreamWriter>()).length.equals(1);
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

    final writers = Chirp.root.writers.where((w) => w is! VmStreamWriter);
    check(writers.single).identicalTo(console);
    check(writers.whereType<IdeDebugConsoleWriter>()).isEmpty();
    check(writers.whereType<PrintConsoleWriter>()).isEmpty();
  });

  test('console: with extra writers still adds no default console writer', () {
    final console = _StubWriter();
    final extra = _StubWriter();
    configureLogging(console: console, writers: [extra]);

    final writers = Chirp.root.writers.where((w) => w is! VmStreamWriter);
    check(writers.length).equals(2);
    check(writers).contains(console);
    check(writers).contains(extra);
    check(writers.whereType<IdeDebugConsoleWriter>()).isEmpty();
    check(writers.whereType<PrintConsoleWriter>()).isEmpty();
  });

  test('re-calling configureLogging preserves history and monotonic seq', () {
    configureLogging(console: _StubWriter());
    LogLayer.app.info('first boot record');
    final firstWriter = Chirp.root.writers.whereType<VmStreamWriter>().single;
    final firstSeq = firstWriter.history.last['seq']! as int;

    configureLogging(console: _StubWriter());
    LogLayer.app.info('after reconfigure');
    final secondWriter = Chirp.root.writers.whereType<VmStreamWriter>().single;

    final messages = secondWriter.history.map((r) => r['message']).toList();
    final tail = messages.sublist(messages.length - 2);
    check(tail).deepEquals(['first boot record', 'after reconfigure']);
    final secondSeq = secondWriter.history.last['seq']! as int;
    check(secondSeq).equals(firstSeq + 1);
  });

  test(
    'vmStream: false clears buffered history while keeping seq monotonic',
    () {
    configureLogging(console: _StubWriter());
    LogLayer.app.info('before opt-out');
    final seqBefore = Chirp.root.writers
        .whereType<VmStreamWriter>()
        .single
        .history
        .last['seq']! as int;

    configureLogging(console: _StubWriter(), vmStream: false);
    configureLogging(console: _StubWriter());
    final writer = Chirp.root.writers.whereType<VmStreamWriter>().single;
    check(writer.history).isEmpty();

    LogLayer.app.info('after re-enable');
    final seqAfter = writer.history.single['seq']! as int;
    check(seqAfter).isGreaterThan(seqBefore);
  });
}

final class _StubWriter extends ChirpWriter {
  @override
  void write(LogRecord record) {}
}
