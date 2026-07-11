# stratalog_dio

Dio integration for [stratalog](https://pub.dev/packages/stratalog) — taps Dio into stratalog's colored, contrast-verified log layers.

```dart
dio.interceptors.add(LoggerDioInterceptor(LogLayer.network)); // add FIRST
```

Pure HTTP-wire logging — add it **first**: dio runs hooks in list order, so first position sees the raw server response before any other interceptor can mutate, throw over, or swallow it, and still catches the errors those interceptors raise. Failure lines name their cause: `✗ 500` a server error, `✗ connectionError`/`✗ receiveTimeout` the wire, `✗ unknown` a client-side pipeline failure (the raw body sits on the `←` trace line above). Deserialized results and failures are logged where they land — e.g. `stratalog_riverpod`.

Redacts sensitive headers (`authorization`, `cookie`, `x-api-key`), allowlists the rest, logs the full structured body, and times every request. Bodies aren't truncated here — the sink's `ElidingFormatter` (on by default via `configureLogging`) clips oversized leaves without collapsing the JSON shape, so a base64 blob never evicts the field you opened the log for. Failures log at `warning` — a non-2xx is expected control flow, not a crash. It logs the wire, not the app's verdict: an error later recovered by a retry/refresh interceptor still leaves its warning line.

See the [stratalog README](https://github.com/esenmx/stratalog) for the layer taxonomy, theming, and crash-reporting setup.
