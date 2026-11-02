import 'package:checks/checks.dart';
import 'package:chirp/chirp.dart';
import 'package:riverpod/experimental/mutation.dart';
import 'package:riverpod/riverpod.dart';
import 'package:stratalog_riverpod/stratalog_riverpod.dart';
import 'package:test/test.dart';

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
    final container = ProviderContainer(observers: [const RiverpodLogger()]);
    final provider = Provider((ref) => 'hello');
    container
      ..read(provider)
      ..dispose();

    check(messages()).contains('✚ add Provider<String> | initial: hello');
    check(messages()).contains('⊘ dispose Provider<String>');
  });

  test('update is traced with both values', () {
    final container = ProviderContainer(observers: [const RiverpodLogger()]);
    final provider = NotifierProvider<_Counter, int>(_Counter.new);
    container.read(provider.notifier).increment();

    check(messages().any((m) => m.contains('0 ➔ 1'))).isTrue();
    container.dispose();
  });

  test('fat states are ellipsized', () {
    final container = ProviderContainer(
      observers: [const RiverpodLogger(maxValueLength: 16)],
    );
    final provider = Provider((ref) => 'x' * 100);
    container
      ..read(provider)
      ..dispose();

    final add = messages().firstWhere((m) => m.startsWith('✚'));
    check(add).contains('…(+84 chars)');
  });

  test('Exception failure -> warning, Error failure -> error', () {
    final container = ProviderContainer(observers: [const RiverpodLogger()]);

    final throwsException = Provider<int>((ref) => throw Exception('x'));
    check(() => container.read(throwsException)).throws<Object>();
    check(writer.records.last.level).equals(.warning);

    final throwsError = Provider<int>((ref) => throw StateError('y'));
    check(() => container.read(throwsError)).throws<Object>();
    check(writer.records.last.level).equals(.error);

    container.dispose();
  });

  test('mutation lifecycle logs provider name and label without literal null '
      'or duplicate keys', () async {
    final container = ProviderContainer(observers: [const RiverpodLogger()]);
    final save = Mutation<String>(label: 'saveUser');

    await save.run(container, (tsx) async => 'ok');
    save.reset(container);

    final keyed = save('42');
    await check(
      keyed.run(container, (tsx) async => throw Exception('conflict')),
    ).throws<Exception>();

    final mutLines = messages().where((m) => m.startsWith('⚡')).toList();
    check(mutLines).any(
      (it) => it
        ..contains('mutation start: saveUser')
        ..not((m) => m.contains('null')),
    );
    check(mutLines).any((it) => it.contains('mutation success: saveUser ➔ ok'));
    check(mutLines).any((it) => it.contains('mutation reset: saveUser'));
    check(mutLines).any(
      (it) => it
        ..contains('mutation error: saveUser(key: 42)')
        ..not((m) => m.startsWith('⚡ 42 |')),
    );

    container.dispose();
  });
}
