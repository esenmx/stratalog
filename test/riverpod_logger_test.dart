import 'package:checks/checks.dart';
import 'package:chirp/chirp.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:riverpod/riverpod.dart';
import 'package:stratalog/riverpod.dart';
import 'package:stratalog/stratalog.dart';

final class _Counter extends Notifier<int> {
  @override
  int build() => 0;

  void increment() => state++;
}

final class _CapturingWriter extends ChirpWriter {
  final records = <LogRecord>[];

  @override
  void write(LogRecord record) => records.add(record);
}

void main() {
  late _CapturingWriter writer;

  setUp(() {
    writer = _CapturingWriter();
    Chirp.root = ChirpLogger().addWriter(writer);
  });

  tearDown(() => Chirp.root = null);

  Iterable<String> messages() => writer.records.map((r) => '${r.message}');

  test('provider add and dispose are traced', () {
    final container =
        ProviderContainer(observers: [const RiverpodLogger(LogLayer.state)]);
    final provider = Provider((ref) => 'hello');
    container
      ..read(provider)
      ..dispose();

    check(messages()).contains('+ Provider<String> | initial: hello');
    check(messages()).contains('- Provider<String>');
  });

  test('update is traced with both values', () {
    final container =
        ProviderContainer(observers: [const RiverpodLogger(LogLayer.state)]);
    final provider = NotifierProvider<_Counter, int>(_Counter.new);
    container.read(provider.notifier).increment();

    check(messages().any((m) => m.contains('0 ➔ 1'))).isTrue();
    container.dispose();
  });

  test('fat states are ellipsized', () {
    final container = ProviderContainer(
      observers: [const RiverpodLogger(LogLayer.state, maxValueLength: 16)],
    );
    final provider = Provider((ref) => 'x' * 100);
    container
      ..read(provider)
      ..dispose();

    final add = messages().firstWhere((m) => m.startsWith('+'));
    check(add).contains('…(+84 chars)');
  });

  test('Exception failure -> warning, Error failure -> error', () {
    final container =
        ProviderContainer(observers: [const RiverpodLogger(LogLayer.state)]);

    final throwsException = Provider<int>((ref) => throw Exception('x'));
    check(() => container.read(throwsException)).throws<Object>();
    check(writer.records.last.level).equals(ChirpLogLevel.warning);

    final throwsError = Provider<int>((ref) => throw StateError('y'));
    check(() => container.read(throwsError)).throws<Object>();
    check(writer.records.last.level).equals(ChirpLogLevel.error);

    container.dispose();
  });
}
