import 'package:bloc/bloc.dart';
import 'package:checks/checks.dart';
import 'package:chirp/chirp.dart';
import 'package:stratalog_bloc/stratalog_bloc.dart';
import 'package:test/test.dart';

final class _FatCubit extends Cubit<String> {
  new() : super('x' * 100);
}

final class _CounterCubit extends Cubit<int> {
  new() : super(0);

  void increment() => emit(state + 1);

  void fail(Object error) => addError(error, .current);
}

final class _CounterBloc extends Bloc<String, int> {
  new() : super(0) {
    on<String>((event, emit) => emit(state + 1));
  }
}

void main() {
  final records = <LogRecord>[];

  setUp(() {
    records.clear();
    Chirp.root = ChirpLogger().addWriter(DelegatedChirpWriter(records.add));
    final previous = Bloc.observer;
    Bloc.observer = const BlocLogger();
    addTearDown(() {
      Bloc.observer = previous;
      Chirp.root = null;
    });
  });

  Iterable<String> messages() => records.map((r) => '${r.message}');

  test('cubit create, change, and close are traced', () async {
    final cubit = _CounterCubit()..increment();
    await cubit.close();

    check(messages()).deepEquals([
      '✚ create _CounterCubit | initial: 0',
      '↻ change _CounterCubit | 0 ➔ 1',
      '⊘ close _CounterCubit',
    ]);
  });

  test('bloc logs event + transition, no duplicate change line', () async {
    final bloc = _CounterBloc()..add('inc');
    await Future<void>.delayed(.zero);
    await bloc.close();

    check(messages()).contains('⚡ _CounterBloc | event: inc');
    check(messages()).contains('↻ transition _CounterBloc | inc: 0 ➔ 1');
    check(messages().where((m) => m.startsWith('↻'))).length.equals(1);
  });

  test('Exception -> warning, Error -> error', () {
    final (exception, error) = (Exception('x'), StateError('y'));
    _CounterCubit()
      ..fail(exception)
      ..fail(error);

    final failures = records.where((r) => '${r.message}'.startsWith('✗'));
    check(failures.map((r) => (r.level, r.error))).deepEquals([
      (ChirpLogLevel.warning, exception),
      (ChirpLogLevel.error, error),
    ]);
    check(failures.map((r) => r.stackTrace)).every((it) => it.isNotNull());
  });

  test('fat states are ellipsized', () async {
    Bloc.observer = const BlocLogger(maxValueLength: 8);

    final cubit = _FatCubit();
    await cubit.close();

    check(messages().first).contains('…(+92 chars)');
  });
}
