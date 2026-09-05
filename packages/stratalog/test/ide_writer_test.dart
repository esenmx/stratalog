import 'package:checks/checks.dart';
import 'package:chirp/chirp.dart';
import 'package:stratalog/stratalog.dart';
import 'package:test/test.dart';

final class _MessageFormatter extends ChirpFormatter {
  const new();

  @override
  void format(LogRecord record, MessageBuffer buffer) =>
      buffer.write(record.message);
}

void main() {
  late List<(String, int)> emitted;
  late ChirpLogger logger;

  setUp(() {
    emitted = [];
    logger = ChirpLogger()
      ..addWriter(
        IdeDebugConsoleWriter(
          formatter: const _MessageFormatter(),
          emit: (message, level) => emitted.add((message, level)),
        ),
      );
  });

  test('burst within one turn coalesces into a single ordered emit '
      'at the max mapped level', () async {
    logger
      ..trace('first')
      ..error('second')
      ..info('third');
    check(because: 'flush must wait for the microtask', emitted).isEmpty();

    // The flush microtask was scheduled before this await's continuation.
    await null;

    check(emitted).deepEquals([('first\nsecond\nthird', 1000)]);
  });

  test('write after a flush schedules a new batch', () async {
    logger.info('one');
    await null;
    logger.warning('two');
    await null;

    check(emitted).deepEquals([('one', 800), ('two', 900)]);
  });
}
