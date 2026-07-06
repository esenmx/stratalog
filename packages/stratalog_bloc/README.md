# stratalog_bloc

bloc integration for [stratalog](https://pub.dev/packages/stratalog).

```dart
Bloc.observer = const BlocLogger(LogLayer.state);
```

Create/change/transition/close for every bloc and cubit, mirroring `stratalog_riverpod`'s format (`+`, `~`, `-`, `⚡`). Blocs log transitions with the event; the duplicate `onChange` line is suppressed. `Exception` failures log at `warning`, `Error`s at `error`; fat states are ellipsized.

See the [stratalog README](https://github.com/esenmx/stratalog) for the layer taxonomy and theming.
