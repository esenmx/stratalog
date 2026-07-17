# stratalog_drift

Drift integration for [stratalog](https://pub.dev/packages/stratalog).

```dart
AppDatabase(NativeDatabase.createInBackground(file)
    .interceptWith(LoggerQueryInterceptor(LogLayer.storage)));
```

Statements trace with duration and row/affected counts; transactions and batches included. Failures log at `warning` with the statement attached. `logArgs: false` keeps bound row data out of every sink; full SQL is logged by default — pass `maxStatementChars` to clip long statements.

See the [stratalog README](https://github.com/esenmx/stratalog) for the layer taxonomy and theming.
