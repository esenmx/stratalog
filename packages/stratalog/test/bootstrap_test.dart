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
    check(Chirp.root.writers.single).isA<IdeDebugConsoleWriter>();
  });

  test('console: replaces the default console writer instead of appending', () {
    final console = _StubWriter();
    configureLogging(console: console);

    final writers = Chirp.root.writers;
    check(writers.single).identicalTo(console);
    check(writers.whereType<IdeDebugConsoleWriter>()).isEmpty();
    check(writers.whereType<PrintConsoleWriter>()).isEmpty();
  });

  test('console: with extra writers still adds no default console writer', () {
    final console = _StubWriter();
    final extra = _StubWriter();
    configureLogging(console: console, writers: [extra]);

    final writers = Chirp.root.writers;
    check(writers.length).equals(2);
    check(writers).contains(console);
    check(writers).contains(extra);
    check(writers.whereType<IdeDebugConsoleWriter>()).isEmpty();
    check(writers.whereType<PrintConsoleWriter>()).isEmpty();
  });
}

final class _StubWriter extends ChirpWriter {
  @override
  void write(LogRecord record) {}
}
