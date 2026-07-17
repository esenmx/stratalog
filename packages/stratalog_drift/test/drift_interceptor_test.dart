import 'package:checks/checks.dart';
import 'package:chirp/chirp.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:stratalog_drift/stratalog_drift.dart';
import 'package:test/test.dart';

final class _CapturingWriter extends ChirpWriter {
  final records = <LogRecord>[];

  @override
  void write(LogRecord record) => records.add(record);
}

/// Minimal schema-less database — raw SQL only, no codegen.
final class _Db extends GeneratedDatabase {
  _Db(super.executor);

  @override
  Iterable<TableInfo<Table, dynamic>> get allTables => const [];

  @override
  int get schemaVersion => 1;
}

void main() {
  late _CapturingWriter writer;
  late _Db db;

  setUp(() {
    writer = _CapturingWriter();
    Chirp.root = ChirpLogger().addWriter(writer);
    db = _Db(
      NativeDatabase.memory().interceptWith(LoggerQueryInterceptor(.storage)),
    );
  });

  tearDown(() async {
    await db.close();
    Chirp.root = null;
  });

  Iterable<String> messages() => writer.records.map((r) => '${r.message}');

  test('statements trace with args, duration, and result counts', () async {
    await db.customStatement('CREATE TABLE t (id INTEGER PRIMARY KEY)');
    await db.customInsert(
      'INSERT INTO t (id) VALUES (?)',
      variables: [.withInt(7)],
    );
    final rows = await db.customSelect('SELECT * FROM t').get();

    check(rows).length.equals(1);
    check(messages()).contains('▸ CREATE TABLE t (id INTEGER PRIMARY KEY)');

    final insert = writer.records.firstWhere(
      (r) => '${r.message}'.startsWith('▸ INSERT'),
    );
    check(insert.data['args']).isA<List<Object?>>().deepEquals([7]);
    check(insert.data['duration_ms']).isA<int>();

    final select = writer.records.firstWhere(
      (r) => '${r.message}'.startsWith('▸ SELECT'),
    );
    check(select.data['rows']).equals(1);
  });

  test('failures log the statement at warning and rethrow', () async {
    await check(
      db.customStatement('SELECT * FROM missing_table'),
    ).throws<Object>();

    final failure = writer.records.firstWhere(
      (r) => '${r.message}'.startsWith('✗'),
    );
    check(failure.level).equals(.warning);
    check('${failure.message}').contains('missing_table');
  });

  test('logArgs false keeps bound values out of every sink', () async {
    await db.close();
    db = _Db(
      NativeDatabase.memory().interceptWith(
        LoggerQueryInterceptor(.storage, logArgs: false),
      ),
    );
    await db.customStatement('CREATE TABLE t (secret TEXT)');
    await db.customInsert(
      'INSERT INTO t (secret) VALUES (?)',
      variables: [.withString('hunter2')],
    );

    check(
      '${writer.records.map((r) => r.data).toList()}',
    ).not((it) => it.contains('hunter2'));
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
    final interceptor = LoggerQueryInterceptor(.storage, maxStatementChars: 16);
    await db.close();
    db = _Db(NativeDatabase.memory().interceptWith(interceptor));

    await db.customStatement('CREATE TABLE another_rather_long_name (id INT)');

    final created = messages().firstWhere((m) => m.contains('CREATE TABLE a'));
    check(created).contains('…(+');
  });
}
