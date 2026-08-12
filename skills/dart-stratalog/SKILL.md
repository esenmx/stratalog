---
name: dart-stratalog
description: Wire structured logging via the stratalog package family — colored layer loggers on chirp, crash-reporter adapters (Crashlytics/Sentry), and taps for Dio/gRPC/ConnectRPC/Riverpod/bloc/auto_route/drift/FirebaseAuth/FirebaseAnalytics, plus an in-app viewer. Use when adding logging, wiring a new integration or crash backend, declaring log layers, or picking log colors. Skip for print-debugging one-offs.
---

# stratalog

Core (`stratalog`) is pure Dart; every integration is a sibling package — add only what the project uses:

|Package|Entry point|
|---|---|
|`stratalog_dio`|`dio.interceptors.add(LoggerDioInterceptor())` — add **FIRST**: dio runs hooks FIFO, so first position logs the raw wire (response before any interceptor can mutate/throw/swallow it, and the errors they raise — last position goes blind to both). Failure lines name their cause: `✗ 500` server, `✗ connectionError` wire, `✗ unknown` client pipeline (raw body on the `←` trace line above). Deserialized failures log via `stratalog_riverpod`|
|`stratalog_grpc`|`Client(channel, interceptors: [LoggerGrpcInterceptor()])`|
|`stratalog_connectrpc`|`Transport(..., interceptors: [loggerConnectInterceptor()])`|
|`stratalog_riverpod`|`ProviderScope(observers: [const RiverpodLogger()])`|
|`stratalog_bloc`|`Bloc.observer = const BlocLogger()`|
|`stratalog_auto_route`|`router.config(navigatorObservers: () => [AppRouterObserver()])`|
|`stratalog_drift`|`executor.interceptWith(LoggerQueryInterceptor())`|
|`stratalog_firebase_auth`|`FirebaseAuthLogger(FirebaseAuth.instance).attach()` after `Firebase.initializeApp`|
|`stratalog_firebase_analytics`|`LoggerAnalytics(FirebaseAnalytics.instance)` — a facade; call through it|
|`stratalog_crashlytics` / `stratalog_sentry`|`configureLogging(crashReporter: const CrashlyticsCrashReporter())`|
|`stratalog_viewer`|`MemoryLogWriter` in `writers:` + `LogViewerPage(writer: ...)`|

## Bootstrap

`configureLogging()` once, first line of bootstrap, before `runApp`. Reconfigure by calling again — never mutate `Chirp.root` in place; `LogLayer` re-resolves automatically. Debug → colored structured console via `dart:developer` (never `print`); release → single-line JSON.

Global handlers route through the same pipeline: `FlutterError.onError` → `LogLayer.ui.error(details.context?.toDescription() ?? 'flutter framework error', error: details.exception, stackTrace: details.stack)` (guard `if (details.silent) return;` first); `PlatformDispatcher.instance.onError` → `LogLayer.app.error(...)` then `return true`. Never also call `FlutterError.presentError`/chain the previous handler, and never `return false` — either re-prints the error as the framework's `════ Exception caught by ════` dump (console shows it twice). No `recordFlutterFatalError` wiring either: `CrashReporterWriter` already forwards `error`+ records, so direct SDK calls double-report to the backend.

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

`error`+ → report (`critical`/`wtf` → fatal); `info`+ → breadcrumb (message + the record's `data:` map). Veto expected failures via the writer form:

```dart
configureLogging(writers: [
  CrashReporterWriter(const SentryCrashReporter(),
      shouldReport: (r) => r.error is! Failure),
]);
```

Adapter throws are swallowed by design — a log call must never crash the app (uninitialized Firebase/Sentry degrades to no-op). Other backends: implement 2-method `CrashReporter`.

## Proto name stripping & release body discipline

Apps ship release AOT with `protobuf.omit_enum_names` / `omit_field_names` / `omit_message_names` dart-defines → `GeneratedMessage.toString()`/`ProtobufEnum.toString()` print numbers and proto3 JSON is unusable there (debug/profile keep names). The gRPC/Connect taps are aligned:

- Release/breadcrumb records carry only stripping-proof fields: literal method path, status code name (grpc's `StatusCode` table / Connect's plain Dart enum — never protobuf `.name`/`qualifiedMessageName`), the `error-code` trailer as `error_code` (key via `errorCodeTrailer:`), `duration_ms`, and caller `data:` fields.
- Bodies are opt-in via `logBodies:` — defaults on in debug/profile, **off in product**. Opted-in bodies under the omit defines emit the tag-keyed `writeToJson()` map (numeric keys, enum numbers — decodable against the `.proto` at the release tag), not proto3 JSON. Logging a message yourself: `protoLogShape(msg)` (exported by both taps), never `toString()`.
- `maskSensitiveValues` defaults to masking in product builds only.
- Release-shape tests pin this contract (`logBodies false pins the release shape` in both tap suites) — a tap change reintroducing body dumps fails there.

## Non-obvious invariants

- Network taps log failures at `warning`, never `error` — non-2xx/non-OK is control flow the repository maps to a typed failure. Reserve `error` for bugs — judged by **nature, not Dart type**: mapped/expected control flow → `warning` (usually surfaces as `Exception`); bug-grade conditions → `error` even when they arrive as an `Exception` (canonical case: a failed bootstrap init `.wait` — half-initialized app must reach the crash reporter); `Error` → `error` always.
- Sensitive header/metadata redaction is allowlist-based; extending it means passing `sensitiveHeaders`/`sensitiveMetadata`, not logging raw dumps.
- **`trace` has no release floor.** `configureLogging` calls `setMinLogLevel` only when handed an explicit `minLevel`, and chirp defaults to none — so the taps' `→`/`←` trace lines reach the release console writer and persist in logcat / os_log. Anything that must not survive a release build is redacted at the tap, never left to the sink or to `kReleaseMode`.
- `stratalog_dio`: `redactKeys` masks values `***` at any depth of bodies and in query strings, message-line URI included (defaults cover passwords, `cvv`/`cvc`, `pin`, `otp`, tokens, secrets; matching ignores case and `_`/`-`) and is **always on**, unlike header masking. String bodies pass through unparsed. `redactBodyPaths` drops a whole body — request, response and error — for endpoints sensitive as such (`{'/checkout/pay'}`); prefer it over key lists there, since it still covers the next field added to that payload. Card PAN/CVV under PCI-DSS is the canonical case. The gRPC/ConnectRPC taps need no equivalent — their `logBodies` already defaults off in product builds.
- `stratalog_firebase_auth` logs streams only — sign-in *failures* throw at the call site; catch and `LogLayer.auth.warning(...)` there. OAuth providers surface as `google.com`/`apple.com`/`oidc.*` in `providers`.
- `stratalog_drift`: `logArgs: false` when tables hold PII — bound args are row data.
- Constraint traps: `stratalog_grpc` needs `grpc >=4.2.0 <6.0.0` (protobuf overlap with connectrpc); `stratalog_drift` floors drift at 2.31.
- Never published to pub.dev by design (opinionated, single-org package) — every consumer wires it via path deps + `dependency_overrides: stratalog: {path: ...}` at the consumer's resolution root (workspace root for a melos/pub workspace, the app's own `pubspec.yaml` otherwise); integrations declare stratalog hosted `^0.1.0`, which is what forces the override. This is permanent, not a stopgap.
