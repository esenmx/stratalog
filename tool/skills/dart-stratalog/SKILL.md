---
name: dart-stratalog
description: Wire structured logging via the stratalog package family — colored layer loggers on chirp, crash-reporter adapters (Crashlytics/Sentry), and taps for Dio/gRPC/ConnectRPC/Riverpod/bloc/auto_route/drift/FirebaseAuth/FirebaseAnalytics, plus an in-app viewer. Use when adding logging, wiring a new integration or crash backend, declaring log layers, or picking log colors. Skip for print-debugging one-offs.
---

# stratalog

Core (`stratalog`) is pure Dart; every integration is a sibling package — add only what the project uses:

|Package|Entry point|
|---|---|
|`stratalog_dio`|`dio.interceptors.add(LoggerDioInterceptor(LogLayer.network))` — add **FIRST**: dio runs hooks FIFO, so first position logs the raw wire (response before any interceptor can mutate/throw/swallow it, and the errors they raise — last position goes blind to both). Failure lines name their cause: `✗ 500` server, `✗ connectionError` wire, `✗ unknown` client pipeline (raw body on the `←` trace line above). Deserialized failures log via `stratalog_riverpod`|
|`stratalog_grpc`|`Client(channel, interceptors: [LoggerGrpcInterceptor(LogLayer.network)])`|
|`stratalog_connectrpc`|`Transport(..., interceptors: [loggerConnectInterceptor(LogLayer.network)])`|
|`stratalog_riverpod`|`ProviderScope(observers: [const RiverpodLogger(LogLayer.state)])`|
|`stratalog_bloc`|`Bloc.observer = const BlocLogger(LogLayer.state)`|
|`stratalog_auto_route`|`router.config(navigatorObservers: () => [AppRouterObserver(LogLayer.route)])`|
|`stratalog_drift`|`executor.interceptWith(LoggerQueryInterceptor(LogLayer.storage))`|
|`stratalog_firebase_auth`|`FirebaseAuthLogger(FirebaseAuth.instance).attach()` after `Firebase.initializeApp`|
|`stratalog_firebase_analytics`|`LoggerAnalytics(FirebaseAnalytics.instance)` — a facade; call through it|
|`stratalog_crashlytics` / `stratalog_sentry`|`configureLogging(crashReporter: const CrashlyticsCrashReporter())`|
|`stratalog_viewer`|`MemoryLogWriter` in `writers:` + `LogViewerPage(writer: ...)`|

## Bootstrap

`configureLogging()` once, first line of bootstrap, before `runApp`. Reconfigure by calling again — never mutate `Chirp.root` in place; `LogLayer` re-resolves automatically. Debug → colored structured console via `dart:developer` (never `print`); release → single-line JSON.

## Layers

`LogLayer` is a **const value type** — declare custom layers once, never strings at call sites:

```dart
const payments = LogLayer('Payments', color: Ansi256.springGreen4_29);
payments.info('Order captured', data: {'id': 8123});
```

- Nine pre-defined: `app state route ui network storage auth platform analytics`. Taxonomy names *concerns*, not libraries; no `lifecycle`/`background` layer — both are `platform`, a background task's work logs to its own domain.
- Omit `color:` → stable contrast-verified hash pick. APIs wanting a raw `ChirpLogger` take `LogLayer.x.logger`.

## Colors — never hand-pick

Every color must pass WCAG ≥ 3.0 on solarized light/dark AND soft-gray light/dark. Sweep candidates with `dart run tool/contrast_report.dart` (in the stratalog repo); `test/palette_contrast_test.dart` enforces. Red/orange/hot-pink band = severity only, never a layer.

## Crash reporting

`error`+ → report (`critical`/`wtf` → fatal); `info`+ → breadcrumb. Veto expected failures via the writer form:

```dart
configureLogging(writers: [
  CrashReporterWriter(const SentryCrashReporter(),
      shouldReport: (r) => r.error is! Failure),
]);
```

Adapter throws are swallowed by design — a log call must never crash the app (uninitialized Firebase/Sentry degrades to no-op). Other backends: implement 2-method `CrashReporter`.

## Non-obvious invariants

- Network taps log failures at `warning`, never `error` — non-2xx/non-OK is control flow the repository maps to a typed failure. Reserve `error` for bugs; same split everywhere: `Exception` → warning, `Error` → error.
- Sensitive header/metadata redaction is allowlist-based; extending it means passing `sensitiveHeaders`/`sensitiveMetadata`, not logging raw dumps.
- `stratalog_firebase_auth` logs streams only — sign-in *failures* throw at the call site; catch and `LogLayer.auth.warning(...)` there. OAuth providers surface as `google.com`/`apple.com`/`oidc.*` in `providers`.
- `stratalog_drift`: `logArgs: false` when tables hold PII — bound args are row data.
- Constraint traps: `stratalog_grpc` needs `grpc >=4.2.0 <6.0.0` (protobuf overlap with connectrpc); `stratalog_drift` floors drift at 2.31.
- Never published to pub.dev by design (opinionated, single-org package) — every consumer wires it via path deps + `dependency_overrides: stratalog: {path: ...}` at the consumer's resolution root (workspace root for a melos/pub workspace, the app's own `pubspec.yaml` otherwise); integrations declare stratalog hosted `^0.1.0`, which is what forces the override. This is permanent, not a stopgap.
