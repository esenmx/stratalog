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

void main() {
  final records = <LogRecord>[];

  setUp(() {
    records.clear();
    Chirp.root = ChirpLogger().addWriter(DelegatedChirpWriter(records.add));
  });

  tearDown(() => Chirp.root = null);

  Iterable<String> messages() => records.map((r) => '${r.message}');

  ProviderContainer newContainer([RiverpodLogger l = const RiverpodLogger()]) =>
      .test(observers: [l]);

  test('provider add and dispose are traced', () {
    final container = newContainer();
    final provider = Provider((ref) => 'hello');
    container
      ..read(provider)
      ..dispose();

    check(messages()).contains('✚ add Provider<String> | initial: hello');
    check(messages()).contains('⊘ dispose Provider<String>');
  });

  test('update is traced with both values', () {
    final provider = NotifierProvider<_Counter, int>(_Counter.new);
    newContainer().read(provider.notifier).increment();

    check(messages().any((m) => m.contains('0 ➔ 1'))).isTrue();
  });

  test('fat states are ellipsized', () {
    final provider = Provider((ref) => 'x' * 100);
    newContainer(const RiverpodLogger(maxValueLength: 16)).read(provider);

    final add = messages().firstWhere((m) => m.startsWith('✚'));
    check(add).contains('…(+84 chars)');
  });

  test('Exception failure -> warning, Error failure -> error', () {
    final container = newContainer();
    for (final (thrown, level) in <(Object, ChirpLogLevel)>[
      (Exception('x'), .warning),
      (StateError('y'), .error),
    ]) {
      final provider = Provider<int>(
        (ref) => Error.throwWithStackTrace(thrown, .current),
      );
      check(() => container.read(provider)).throws<Object>();
      check(records.last)
        ..has((r) => r.level, 'level').equals(level)
        ..has((r) => r.error, 'error').identicalTo(thrown)
        ..has((r) => r.stackTrace, 'stackTrace').isNotNull();
    }
  });

  test('mutation lifecycle logs provider name and label without literal null '
      'or duplicate keys', () async {
    final container = newContainer();
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
  });

  test('mutation error: Exception -> warning, Error -> error', () async {
    final container = newContainer();
    final save = Mutation<void>(label: 'save');
    for (final (thrown, level) in <(Object, ChirpLogLevel)>[
      (Exception('x'), .warning),
      (StateError('y'), .error),
    ]) {
      await check(save.run(container, (tsx) => .error(thrown)))
          .throws<Object>();
      final failure = records.lastWhere(
        (r) => '${r.message}'.contains('mutation error'),
      );
      check(failure)
        ..has((r) => r.level, 'level').equals(level)
        ..has((r) => r.error, 'error').identicalTo(thrown)
        ..has((r) => r.stackTrace, 'stackTrace').isNotNull();
    }
  });
}
