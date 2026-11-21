import 'package:checks/checks.dart';
import 'package:chirp/chirp.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:stratalog_drift/stratalog_drift.dart';
import 'package:test/test.dart';

/// Minimal schema-less database — raw SQL only, no codegen.
final class _Db(super.executor) extends GeneratedDatabase {
  @override
  Iterable<TableInfo<Table, dynamic>> get allTables => const [];

  @override
  int get schemaVersion => 1;
}

final class _UnprintableError {
  @override
  String toString() => throw StateError('unprintable');
}

final class _Fails(final Object error) extends QueryInterceptor {
  @override
  Future<void> runCustom(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) => .error(error);
}

void main() {
  final records = <LogRecord>[];
  late _Db db;

  setUp(() {
    records.clear();
    Chirp.root = ChirpLogger().addWriter(DelegatedChirpWriter(records.add));
    db = _Db(NativeDatabase.memory().interceptWith(LoggerQueryInterceptor()));
  });

  tearDown(() async {
    await db.close();
    Chirp.root = null;
  });

  Iterable<String> messages() => records.map((r) => '${r.message}');

  LogRecord record(String prefix) =>
      records.singleWhere((r) => '${r.message}'.startsWith(prefix));

  Future<void> reopen(LoggerQueryInterceptor interceptor) async {
    await db.close();
    db = _Db(NativeDatabase.memory().interceptWith(interceptor));
  }

  Future<int> insertSecret() => db.customInsert(
    'INSERT INTO t (secret) VALUES (?)',
    variables: [.withString('hunter2')],
  );

  test('statements trace with args, duration, and result counts', () async {
    await db.customStatement('CREATE TABLE t (id INTEGER PRIMARY KEY)');
    await db.customInsert(
      'INSERT INTO t (id) VALUES (?)',
      variables: [.withInt(7)],
    );
    final rows = await db.customSelect('SELECT * FROM t').get();

    check(rows).length.equals(1);
    check(messages()).contains('▸ CREATE TABLE t (id INTEGER PRIMARY KEY)');

    final insert = record('▸ INSERT');
    check(insert.data['args']).isA<List<Object?>>().deepEquals([7]);
    check(insert.data['duration_ms']).isA<int>();

    check(record('▸ SELECT').data['rows']).equals(1);
  });

  test('update and delete trace their affected counts', () async {
    await db.customStatement('CREATE TABLE t (id INT)');
    await db.customStatement('INSERT INTO t VALUES (1), (2)');
    await db.customUpdate('UPDATE t SET id = id + 10');
    await db.executor.runDelete('DELETE FROM t WHERE id = 11', const []);

    check(record('▸ UPDATE').data['affected']).equals(2);
    check(record('▸ DELETE').data['affected']).equals(1);
  });

  test('a batch traces its statement count', () async {
    await db.customStatement('CREATE TABLE t (id INT)');
    await db.batch((batch) {
      for (var i = 0; i < 2; i++) {
        batch.customStatement('INSERT INTO t VALUES (?)', [i]);
      }
    });

    check(messages()).contains('▸ BATCH (2 statements)');
  });

  test('a committed transaction traces BEGIN and COMMIT', () async {
    await db.transaction(() => db.customStatement('CREATE TABLE t (id INT)'));

    check(messages()).containsEqualInOrder([
      '▸ BEGIN TRANSACTION',
      '▸ CREATE TABLE t (id INT)',
      '▸ COMMIT',
    ]);
  });

  test('a failed transaction traces ROLLBACK', () async {
    final failing = db.transaction<void>(() async {
      await db.customStatement('CREATE TABLE t (id INT)');
      throw StateError('abort');
    });

    await check(failing).throws<StateError>();
    check(messages())
        .containsEqualInOrder(['▸ BEGIN TRANSACTION', '▸ ROLLBACK']);
  });

  test('failures log the statement at warning and rethrow', () async {
    await check(db.customStatement('SELECT * FROM missing_table'))
        .throws<Object>();

    final failure = record('✗');
    check(failure.level).equals(.warning);
    check('${failure.message}').contains('missing_table');
  });

  test('logArgs false keeps bound values out of every sink', () async {
    await reopen(LoggerQueryInterceptor(logArgs: false));
    await db.customStatement('CREATE TABLE t (secret TEXT)');
    await insertSecret();

    check('${records.map((r) => r.data).toList()}')
        .not((it) => it.contains('hunter2'));
  });

  group('logArgs false reduces a failure to its type and engine message', () {
    test('on a failing statement', () async {
      await reopen(LoggerQueryInterceptor(logArgs: false));
      await db.customStatement('CREATE TABLE t (secret TEXT UNIQUE)');
      await insertSecret();

      await check(insertSecret()).throws<SqliteException>(
        (it) => it.has((e) => '$e', 'toString()').contains('hunter2'),
      );
      check(record('✗')).withholds(
        'hunter2',
        error:
            'SqliteException(2067): while executing statement, UNIQUE '
            'constraint failed: t.secret, constraint failed (code 2067)',
      );
    });

    test('on a failing batch', () async {
      await reopen(LoggerQueryInterceptor(logArgs: false));
      await db.customStatement('CREATE TABLE t (secret TEXT UNIQUE)');

      await check(
        db.batch((batch) {
          for (var i = 0; i < 2; i++) {
            batch.customStatement('INSERT INTO t (secret) VALUES (?)', [
              'hunter2',
            ]);
          }
        }),
      ).throws<SqliteException>(
        (it) => it.has((e) => '$e', 'toString()').contains('hunter2'),
      );
      check(record('✗')).withholds(
        'hunter2',
        error:
            'SqliteException(2067): while executing statement, UNIQUE '
            'constraint failed: t.secret, constraint failed (code 2067)',
      );
    });

    test('keeps the message of a failure without bound values', () async {
      await reopen(LoggerQueryInterceptor(logArgs: false));

      await check(db.customStatement('SELECT * FROM missing_table'))
          .throws<SqliteException>();
      check(record('✗'))
          .has((r) => '${r.error}', 'error')
          .equals(
            'SqliteException(1): while executing, '
            'no such table: missing_table, SQL logic error (code 1)',
          );
    });

    test('when the error cannot print itself', () async {
      final thrown = _UnprintableError();
      final executor = NativeDatabase.memory()
          .interceptWith(_Fails(thrown))
          .interceptWith(LoggerQueryInterceptor(logArgs: false));
      addTearDown(executor.close);

      await check(executor.runCustom('SELECT 1'))
          .throws<Object>((it) => it.identicalTo(thrown));
      check(record('✗').error).equals('_UnprintableError');
    });
  });

  test('logArgs true attaches the raw exception on failure', () async {
    await db.customStatement('CREATE TABLE t (secret TEXT UNIQUE)');
    await insertSecret();
    await check(insertSecret()).throws<SqliteException>();

    check(record('✗').error)
        .isA<SqliteException>()
        .has((e) => e.parametersToStatement, 'parametersToStatement')
        .isNotNull()
        .deepEquals(['hunter2']);
  });

  test('long statements log in full by default', () async {
    final columns = List.generate(80, (i) => 'column_with_a_long_name_$i INT');
    final statement = 'CREATE TABLE wide (${columns.join(', ')})';
    check(statement.length).isGreaterThan(1024);

    await db.customStatement(statement);

    final created = messages().firstWhere((m) => m.contains('CREATE TABLE w'));
    check(created).contains('column_with_a_long_name_79 INT)');
    check(created).not((it) => it.contains('…(+'));
  });

  test('long statements are ellipsized in the message', () async {
    await reopen(LoggerQueryInterceptor(maxStatementChars: 16));

    await db.customStatement('CREATE TABLE another_rather_long_name (id INT)');

    final created = messages().firstWhere((m) => m.contains('CREATE TABLE a'));
    check(created).contains('…(+');
  });
}

extension on Subject<LogRecord> {
  void withholds(String secret, {required String error}) {
    has((r) => r.level, 'level').equals(.warning);
    has((r) => r.stackTrace, 'stackTrace').isNotNull();
    for (final (name, field) in [
      ('message', (LogRecord r) => '${r.message}'),
      ('data', (LogRecord r) => '${r.data}'),
      ('error', (LogRecord r) => '${r.error}'),
    ]) {
      has(field, name).not((it) => it.contains(secret));
    }
    has((r) => '${r.error}', 'error').equals(error);
  }
}
