# stratalog_dio

Dio integration for [stratalog](https://github.com/esenmx/stratalog) — taps Dio into stratalog's colored, contrast-verified log layers.

```dart
dio.interceptors.add(LoggerDioInterceptor()); // add FIRST
```

Pure HTTP-wire logging — add it **first**: dio runs hooks in list order, so first position sees the raw server response before any other interceptor can mutate, throw over, or swallow it, and still catches the errors those interceptors raise. Failure lines name their cause: `✗ 500` a server error, `✗ connectionError`/`✗ receiveTimeout` the wire, `✗ unknown` a client-side pipeline failure. Deserialized results and failures are logged where they land — e.g. `stratalog_riverpod`.

Redacts sensitive headers (`authorization`, `cookie`, `x-api-key`), allowlists the rest, and times every request. Request, response, and failure bodies are stripped by default (`logBodies: false`) so large JSON payloads never flood the console or reach release sinks; pass `logBodies: true` when you want redacted bodies attached (the sink's `ElidingFormatter` then clips oversized leaves without collapsing the JSON shape). Failures log at `warning` — a non-2xx is expected control flow, not a crash. It logs the wire, not the app's verdict: an error later recovered by a retry/refresh interceptor still leaves its warning line.

Query strings (and opted-in bodies) are redacted here, not at the sink, because `trace` is **not** release-gated: `configureLogging` filters by level only when handed an explicit `minLevel`, so these lines reach the release console writer and any extra `writers:` entry without its own level floor; the `warning` failure line is what reaches crash breadcrumbs by default.

The warning's `error` is a redacted copy — the caller still receives the original `DioException`. URLs in its message are redacted like the message line; an inner `SocketException`, `TlsException` or `TimeoutException` keeps its text, an inner `FormatException` only its offset, and any other inner error logs as its type name (`<HttpException>`), since its text can quote a request body or a header value. The dart:io types are recognised by name, so a build compiled with `--obfuscate` logs those as their type name too.

```dart
LoggerDioInterceptor(
  logBodies: true,
  // Masked as `***` at any depth of a body, in every direction, and in
  // query strings — message-line URI included. Defaults cover passwords,
  // cvv/cvc, pin, otp, tokens and secrets; matching ignores case and
  // `_`/`-`. On by default like header masking, but independent of it:
  // maskSensitiveValues: false reveals headers and keeps these masked, and
  // query strings are covered regardless of logBodies. String bodies pass
  // through unparsed — cover their endpoints with redactBodyPaths.
  redactKeys: {...LoggerDioInterceptor.defaultRedactKeys, 'holderName'},
  // Whole body dropped — request, response and error — for endpoints that
  // are sensitive as such. Keeps covering the next field somebody adds to
  // that payload, which a key list cannot.
  redactBodyPaths: {'/checkout/pay'},
)
```

See the [stratalog README](https://github.com/esenmx/stratalog) for the layer taxonomy, theming, and crash-reporting setup.
