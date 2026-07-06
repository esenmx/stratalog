import 'package:bloc/bloc.dart';
import 'package:checks/checks.dart';
import 'package:chirp/chirp.dart';
import 'package:stratalog/stratalog.dart';
import 'package:stratalog_bloc/stratalog_bloc.dart';
import 'package:test/test.dart';

final class _CapturingWriter extends ChirpWriter {
  final records = <LogRecord>[];

  @override
  void write(LogRecord record) => records.add(record);
}

final class _NoopObserver extends BlocObserver {
  const _NoopObserver();
}

final class _FatCubit extends Cubit<String> {
  _FatCubit() : super('x' * 100);
}

final class _CounterCubit extends Cubit<int> {
  _CounterCubit() : super(0);

  void increment() => emit(state + 1);

  void fail(Object error) => addError(error, StackTrace.current);
}

final class _CounterBloc extends Bloc<String, int> {
  _CounterBloc() : super(0) {
    on<String>((event, emit) => emit(state + 1));
  }
}

void main() {
  late _CapturingWriter writer;

  setUp(() {
    writer = _CapturingWriter();
    Chirp.root = ChirpLogger().addWriter(writer);
    Bloc.observer = const BlocLogger(LogLayer.state);
  });

  tearDown(() {
    Bloc.observer = const _NoopObserver();
    Chirp.root = null;
  });

  Iterable<String> messages() => writer.records.map((r) => '${r.message}');

  test('cubit create, change, and close are traced', () async {
    final cubit = _CounterCubit()..increment();
    await cubit.close();

    check(messages()).deepEquals([
      '+ _CounterCubit | initial: 0',
      '~ _CounterCubit | 0 ➔ 1',
      '- _CounterCubit',
    ]);
  });

  test('bloc logs event + transition without a duplicate change line',
      () async {
    final bloc = _CounterBloc()..add('inc');
    await Future<void>.delayed(Duration.zero);
    await bloc.close();

    check(messages()).contains('⚡ _CounterBloc | event: inc');
    check(messages()).contains('~ _CounterBloc | inc: 0 ➔ 1');
    check(messages().where((m) => m.startsWith('~'))).length.equals(1);
  });

  test('Exception -> warning, Error -> error', () {
    _CounterCubit()
      ..fail(Exception('x'))
      ..fail(StateError('y'));

    final failures =
        writer.records.where((r) => '${r.message}'.startsWith('✗')).toList();
    check(failures[0].level).equals(ChirpLogLevel.warning);
    check(failures[1].level).equals(ChirpLogLevel.error);
  });

  test('fat states are ellipsized', () async {
    Bloc.observer = const BlocLogger(LogLayer.state, maxValueLength: 8);

    final cubit = _FatCubit();
    await cubit.close();

    check(messages().first).contains('…(+92 chars)');
  });
}
