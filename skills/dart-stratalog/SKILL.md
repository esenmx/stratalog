---
name: dart-stratalog
description: Wire structured logging via the stratalog package family — colored layer loggers on chirp, crash-reporter adapters (Crashlytics/Sentry), and taps for Dio/gRPC/ConnectRPC/Riverpod/bloc/auto_route/drift/FirebaseAuth/FirebaseAnalytics — and read a running app's records with the `strata` CLI. Use when adding logging, wiring a new integration or crash backend, declaring log layers, picking log colors, or inspecting/capturing a stratalog app's live logs while debugging. Skip for print-debugging one-offs.
---

# stratalog

Core (`stratalog`) is pure Dart; every integration is a sibling package — add only what the project uses:

|Package|Entry point|
|---|---|
|`stratalog_dio`|`dio.interceptors.add(LoggerDioInterceptor())` — add **FIRST** (see invariants)|
|`stratalog_grpc`|`Client(channel, interceptors: [LoggerGrpcInterceptor()])`|
|`stratalog_connectrpc`|`Transport(..., interceptors: [loggerConnectInterceptor()])`|
|`stratalog_riverpod`|`ProviderScope(observers: [const RiverpodLogger()])`|
|`stratalog_bloc`|`Bloc.observer = const BlocLogger()`|
|`stratalog_auto_route`|`router.config(navigatorObservers: () => [AppRouterObserver()])`|
|`stratalog_drift`|`executor.interceptWith(LoggerQueryInterceptor())`|
|`stratalog_firebase_auth`|`FirebaseAuthLogger(FirebaseAuth.instance).attach()` after `Firebase.initializeApp`|
|`stratalog_firebase_analytics`|`LoggerAnalytics(FirebaseAnalytics.instance)` — a facade; call through it|
|`stratalog_crashlytics` / `stratalog_sentry`|`configureLogging(crashReporter: const CrashlyticsCrashReporter())`|

## Setup (main.dart)

`configureLogging()` once, first line of `main()`, before `runApp`. Reconfigure by calling again — never mutate `Chirp.root` in place; `LogLayer` re-resolves automatically. Debug → colored structured console via `dart:developer` (never `print`); release → single-line JSON.

Global handlers route through the same pipeline: `FlutterError.onError` → `LogLayer.ui.error(details.context?.toDescription() ?? 'flutter framework error', error: details.exception, stackTrace: details.stack)` (guard `if (details.silent) return;` first); `PlatformDispatcher.instance.onError` → `LogLayer.app.critical(...)` then `return true`. Never also call `FlutterError.presentError`/chain the previous handler, and never `return false` — either re-prints the error as the framework's `════ Exception caught by ════` dump (console shows it twice). No `recordFlutterFatalError` wiring either: `CrashReporterWriter` already forwards `error`+ records, so direct SDK calls double-report to the backend.

## Reading a running app — `strata`

Debug/profile builds post every record, payload unelided, as JSON on the `stratalog` VM service stream and buffer the last 1000 per isolate (kept across `configureLogging()` re-calls); release never posts. `configureLogging(vmStream: false)` opts out and clears the buffer. The `strata` CLI reads that stream — a TUI on a terminal, line output for scripts and agents:

```sh
go install github.com/esenmx/stratalog/tools/strata@latest
flutter run --vmservice-out-file=.flutter.vmservice      # app dir, kept running: writes strata's default target
strata --once --json > run.jsonl                         # buffered history as lossless NDJSON, then exit
strata --once -l warning -L Network,Storage -g timeout   # min level, layers, substring; one plain line per record
strata run.jsonl -l error                                # replay a capture (`-` reads stdin); TUI on a terminal
```

- Target: `./.flutter.vmservice`, falling back to `$STRATA_TARGET`/`$VM_SERVICE_URI`; or pass a `ws://`/`http://` URI, a `--write-service-info` JSON, or a `flutter run`/`dart run` stdout log.
- Agents use `--once`: without it `--plain`/`--json` follow the live stream until the app exits (exit 0, `strata: target disconnected` on stderr) — bound a live tail with `timeout`. Piped output is plain automatically.
- Exit 1: `--once` when no isolate serves history; any CLI mode whose target is missing — `--wait` polls for it instead.

## Layers

`LogLayer` is a **const value type** — declare custom layers once, never strings at call sites:

```dart
const payments = LogLayer('Payments', color: Ansi256.springGreen4_29);
payments.info('Order captured', data: {'id': 8123});
```

- Nine pre-defined: `app state route ui network storage auth platform analytics`. Taxonomy names *concerns*, not libraries; no `lifecycle`/`background` layer — both are `platform`, a background task's work logs to its own domain.
- Omit `color:` → stable contrast-verified hash pick. APIs wanting a raw `ChirpLogger` take `LogLayer.x.logger`.

## Colors — never hand-pick

Every color must pass WCAG ≥ 3.0 on solarized light/dark AND soft-gray light/dark. Sweep candidates with `dart run tool/contrast_report.dart` from `packages/stratalog` in the stratalog repo; its `test/palette_contrast_test.dart` enforces. Red/orange/hot-pink band = severity only, never a layer.

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
- Bodies are opt-in via `logBodies: true` across all network taps (`stratalog_dio`, `stratalog_grpc`, `stratalog_connectrpc`) — `logBodies` defaults to `false` everywhere. Opted-in proto bodies under the omit defines emit the tag-keyed `writeToJsonMap()` map (numeric keys, enum numbers — decodable against the `.proto` at the release tag), not proto3 JSON. Logging a message yourself: `protoLogShape(msg)` (exported by both taps), never `toString()`.
- `maskSensitiveValues` defaults to `true` across all build modes.
- Release-shape tests pin this contract (`logBodies defaults to false and pins the release shape` in the grpc and connectrpc tap suites) — a tap change reintroducing body dumps fails there.

## Non-obvious invariants

- Network taps log failures at `warning`, never `error` — non-2xx/non-OK is control flow the repository maps to a typed failure. Reserve `error` for bugs — judged by **nature, not Dart type**: mapped/expected control flow → `warning` (usually surfaces as `Exception`); bug-grade conditions → `error` even when they arrive as an `Exception` (canonical case: a failed startup init `.wait` — half-initialized app must reach the crash reporter); `Error` → `error` always.
- Sensitive header/metadata redaction is allowlist-based across `stratalog_dio`, `stratalog_grpc`, and `stratalog_connectrpc` (`headerAllowlist`/`metadataAllowlist` + `sensitiveHeaders`/`sensitiveMetadata`); extend it through those parameters, never by logging raw dumps.
- **`trace` has no release floor.** `configureLogging` calls `setMinLogLevel` only when handed an explicit `minLevel`, and chirp defaults to none — so the taps' `→`/`←` trace lines reach the release console writer (or its `console:` replacement) and every extra writer without its own level floor; crash breadcrumbs start at `info`, so there only the `✗` warning line lands. Anything that must not survive a release build is redacted at the tap, never left to the sink or to `kReleaseMode`.
- Default release output is single-line JSON on raw `stdout`, which reaches neither logcat nor os_log; a device-log-scraping pipeline passes its own `console:` writer.
- `stratalog_dio` goes **first** in `dio.interceptors`: dio runs hooks FIFO, so first position logs the raw wire — the response before any later interceptor can mutate, throw or swallow it, plus the errors those raise; last position is blind to both. Failure lines name their cause: `✗ 500` server, `✗ connectionError` wire, `✗ unknown` client pipeline (with `logBodies: true` the raw body is on the `←` trace line above). The tap is wire-only: deserialized results and their failures log where they land (e.g. `stratalog_riverpod`).
- `stratalog_dio` redaction: `redactKeys` masks values `***` in query strings (message-line URI included) whatever `logBodies` is, and at any depth of bodies once `logBodies: true` (defaults cover passwords, `cvv`/`cvc`, `pin`, `otp`, tokens, secrets; matching ignores case and `_`/`-`). Header masking and `redactKeys` are both on by default and independent: `maskSensitiveValues: false` reveals header values for local debugging, `redactKeys: const {}` turns key redaction off. String bodies pass through unparsed. `redactBodyPaths` drops a whole body — request, response and error — for endpoints sensitive as such (`{'/checkout/pay'}`); prefer it over key lists there, since it still covers the next field added to that payload. Card PAN/CVV under PCI-DSS is the canonical case.
- `stratalog_grpc`, `stratalog_connectrpc`: once `logBodies: true`, `redactKeys` (same defaults and matching as Dio) masks values `***` at any depth of unary request and response bodies; `redactBodyPaths` drops both bodies for a method path matched as a substring (`{'/auth.v1.AuthService/'}`); failure errors are always sanitised across both taps regardless of `logBodies`. Under the omit defines keys are tag numbers, so `redactKeys` matches nothing — release builds that log bodies need `redactBodyPaths`. A body proto3 JSON rejects (a packed `Any`) logs as `<unloggable body: ArgumentError>` and the call proceeds.
- `stratalog_firebase_auth` logs streams only — sign-in *failures* throw at the call site; catch and `LogLayer.auth.warning(...)` there. OAuth providers surface as `google.com`/`apple.com`/`oidc.*` in `providers`.
- `stratalog_drift`: `logArgs: false` when tables hold PII — bound args are row data.
- Constraint traps: `stratalog_grpc` needs `grpc ^5.1.0` (`protobuf ^6`, shared with connectrpc, rules out anything older); `stratalog_drift` floors drift at 2.31.
- Never published to pub.dev by design (opinionated, single-org package). Integrations reach stratalog via `path: ../stratalog`, so it travels with them: consumers declare each stratalog package as a git dep (`path: packages/<name>`) pinned to one commit SHA, or as path deps into a local checkout — no `dependency_overrides`. Pin by SHA, never a branch: pub rewrites an integration's inner path dep to the resolved SHA, so `ref: main` on the direct `stratalog` dep conflicts with it; mixed SHAs fail resolution by design.
