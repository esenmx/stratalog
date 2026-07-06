# stratalog_dio

Dio integration for [stratalog](https://pub.dev/packages/stratalog) — taps Dio into stratalog's colored, contrast-verified log layers.

```dart
dio.interceptors.add(LoggerDioInterceptor(LogLayer.network)); // add LAST
```

Redacts sensitive headers (`authorization`, `cookie`, `x-api-key`), allowlists the rest, truncates bodies (default 2 KiB), and times every request. Failures log at `warning` — a non-2xx is expected control flow, not a crash.

See the [stratalog README](https://github.com/esenmx/stratalog) for the layer taxonomy, theming, and crash-reporting setup.
