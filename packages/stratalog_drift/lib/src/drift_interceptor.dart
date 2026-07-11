import 'package:drift/drift.dart';
import 'package:stratalog/stratalog.dart';

/// Observability-only drift [QueryInterceptor] — wrap the executor when
/// opening the database:
///
/// ```dart
/// AppDatabase(
///   NativeDatabase.createInBackground(file)
///       .interceptWith(LoggerQueryInterceptor(LogLayer.storage)),
/// );
/// ```
///
/// Statements trace at `trace` with duration and row/affected counts;
/// failures log at `warning` with the statement attached and rethrow
/// untouched. Transaction begin/commit/rollback and batches are traced too.
final class LoggerQueryInterceptor extends QueryInterceptor {
  /// Logs statements to [logger], typically `LogLayer.storage`.
  LoggerQueryInterceptor(
    this.logger, {
    this.logArgs = true,
    this.maxStatementChars = 1024,
  });

  /// Destination layer.
  final LogLayer logger;

  /// Bound arguments carry row data — set `false` when tables hold
  /// sensitive values that must not reach any sink.
  final bool logArgs;

  /// Statements beyond this length are ellipsized in the message.
  final int maxStatementChars;

  @override
  TransactionExecutor beginTransaction(QueryExecutor parent) {
    logger.trace('▸ BEGIN TRANSACTION');
    return super.beginTransaction(parent);
  }

  @override
  Future<void> commitTransaction(TransactionExecutor inner) {
    return _run('COMMIT', const [], () => super.commitTransaction(inner));
  }

  @override
  Future<void> rollbackTransaction(TransactionExecutor inner) {
    return _run('ROLLBACK', const [], () => super.rollbackTransaction(inner));
  }

  @override
  Future<void> runBatched(
    QueryExecutor executor,
    BatchedStatements statements,
  ) {
    return _run(
      'BATCH (${statements.arguments.length} statements)',
      const [],
      () => super.runBatched(executor, statements),
    );
  }

  @override
  Future<void> runCustom(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    return _run(
      statement,
      args,
      () => super.runCustom(executor, statement, args),
    );
  }

  @override
  Future<int> runInsert(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    return _run(
      statement,
      args,
      () => super.runInsert(executor, statement, args),
      describe: (rowId) => {'row_id': rowId},
    );
  }

  @override
  Future<int> runUpdate(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    return _run(
      statement,
      args,
      () => super.runUpdate(executor, statement, args),
      describe: (rows) => {'affected': rows},
    );
  }

  @override
  Future<int> runDelete(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    return _run(
      statement,
      args,
      () => super.runDelete(executor, statement, args),
      describe: (rows) => {'affected': rows},
    );
  }

  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    return _run(
      statement,
      args,
      () => super.runSelect(executor, statement, args),
      describe: (rows) => {'rows': rows.length},
    );
  }

  Future<T> _run<T>(
    String statement,
    List<Object?> args,
    Future<T> Function() operation, {
    Map<String, Object?> Function(T result)? describe,
  }) async {
    final watch = Stopwatch()..start();
    try {
      final result = await operation();
      logger.trace(
        '▸ ${_ellipsize(statement)}',
        data: {
          if (logArgs && args.isNotEmpty) 'args': args,
          'duration_ms': watch.elapsedMilliseconds,
          ...?describe?.call(result),
        },
      );
      return result;
    } on Object catch (error, stackTrace) {
      logger.warning(
        '✗ ${_ellipsize(statement)}',
        data: {
          if (logArgs && args.isNotEmpty) 'args': args,
          'duration_ms': watch.elapsedMilliseconds,
        },
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  String _ellipsize(String statement) =>
      clipString(statement, maxStatementChars);
}
