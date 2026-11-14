# stratalog_drift

Drift integration for [stratalog](https://github.com/esenmx/stratalog).

```dart
AppDatabase(NativeDatabase.createInBackground(file)
    .interceptWith(LoggerQueryInterceptor()));
```

Statements trace with duration and row/affected counts; transactions and batches included. Failures log at `warning` with the statement attached. `logArgs: false` keeps bound arguments out of every sink — a failure line then carries the exception type and the engine's message only, which can itself echo a value in a few cases (FTS5 `MATCH`, JSON paths, trigger `RAISE`); full SQL is logged by default — pass `maxStatementChars` to clip long statements.

See the [stratalog README](https://github.com/esenmx/stratalog) for the layer taxonomy and theming.
