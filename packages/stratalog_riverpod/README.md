# stratalog_riverpod

Riverpod integration for [stratalog](https://pub.dev/packages/stratalog) — taps Riverpod into stratalog's colored, contrast-verified log layers.

```dart
ProviderScope(observers: [const RiverpodLogger(LogLayer.state)], child: app);
```

All provider observer hooks plus the full `Mutation` lifecycle, with fat state `toString()`s ellipsized (default 200 chars). `Exception` failures log at `warning`, `Error`s at `error`.

See the [stratalog README](https://github.com/esenmx/stratalog) for the layer taxonomy, theming, and crash-reporting setup.
