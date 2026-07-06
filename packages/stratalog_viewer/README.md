# stratalog_viewer

in-app viewer integration for [stratalog](https://pub.dev/packages/stratalog).

```dart
final memoryWriter = MemoryLogWriter();
configureLogging(writers: [memoryWriter]);
// later, e.g. behind a debug gesture:
Navigator.push(context, MaterialPageRoute(
    builder: (_) => LogViewerPage(writer: memoryWriter)));
```

`MemoryLogWriter` keeps the newest N records (default 1000) in a ring buffer; `LogViewerPage` renders them newest-first with stratalog's layer colors, a minimum-level filter, substring search, expandable data/error/stack, and copy-to-clipboard.

See the [stratalog README](https://github.com/esenmx/stratalog) for the layer taxonomy and theming.
