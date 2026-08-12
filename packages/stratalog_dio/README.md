# stratalog_dio

Dio integration for [stratalog](https://pub.dev/packages/stratalog) — taps Dio into stratalog's colored, contrast-verified log layers.

```dart
dio.interceptors.add(LoggerDioInterceptor()); // add FIRST
```

Pure HTTP-wire logging — add it **first**: dio runs hooks in list order, so first position sees the raw server response before any other interceptor can mutate, throw over, or swallow it, and still catches the errors those interceptors raise. Failure lines name their cause: `✗ 500` a server error, `✗ connectionError`/`✗ receiveTimeout` the wire, `✗ unknown` a client-side pipeline failure (the raw body sits on the `←` trace line above). Deserialized results and failures are logged where they land — e.g. `stratalog_riverpod`.

Redacts sensitive headers (`authorization`, `cookie`, `x-api-key`), allowlists the rest, logs the full structured body, and times every request. Bodies aren't truncated here — the sink's `ElidingFormatter` (on by default via `configureLogging`) clips oversized leaves without collapsing the JSON shape, so a base64 blob never evicts the field you opened the log for. Failures log at `warning` — a non-2xx is expected control flow, not a crash. It logs the wire, not the app's verdict: an error later recovered by a retry/refresh interceptor still leaves its warning line.

Bodies and query strings are redacted here, not at the sink, because `trace` is **not** release-gated: `configureLogging` filters by level only when handed an explicit `minLevel`, so these lines reach the release console writer and land in logcat / os_log.

```dart
LoggerDioInterceptor(
  // Masked as `***` at any depth of a body, in every direction, and in
  // query strings — message-line URI included. Defaults cover passwords,
  // cvv/cvc, pin, otp, tokens and secrets; matching ignores case and
  // `_`/`-`. Always on — a bearer token is worth showing on a local
  // console, a password never is. String bodies pass through unparsed —
  // cover their endpoints with redactBodyPaths.
  redactKeys: {...LoggerDioInterceptor.defaultRedactKeys, 'holderName'},
  // Whole body dropped — request, response and error — for endpoints that
  // are sensitive as such. Keeps covering the next field somebody adds to
  // that payload, which a key list cannot.
  redactBodyPaths: {'/checkout/pay'},
)
```

See the [stratalog README](https://github.com/esenmx/stratalog) for the layer taxonomy, theming, and crash-reporting setup.
