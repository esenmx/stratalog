# stratalog

Opinionated structured logging for Dart & Flutter, built on [chirp](https://pub.dev/packages/chirp).

```text
▐ Network ▌ [warning] 14:03:22.114 • api_client.dart:87 • fetchUser
 ├─ ✗ 404 GET https://api.example.com/users/42
 ├─ Data: {
 │    "duration_ms": 132
 │  }
```

- **Layer loggers** — nine pre-defined, non-overlapping domains (`LogLayer.network`, `LogLayer.auth`, …), each a `const` value rendering as a colored badge with a matching left gutter. Declare your own the same way: `const payments = LogLayer('Payments', color: Ansi256.springGreen4_29)` — omit `color` for a stable contrast-verified hash pick.
- **Theme-adaptive colors** — every hue passes WCAG ≥ 3.0 contrast on solarized light/dark *and* soft-gray light/dark backgrounds, enforced by a test. Red/orange/hot-pink are reserved for severity, so hue always separates *where* from *how bad*.
- **Pluggable crash reporting** — implement the 2-method `CrashReporter` against Crashlytics, Sentry, or anything else; stratalog carries no vendor dependency.
- **Stack taps** — Dio, gRPC, ConnectRPC, Riverpod, auto_route, and FirebaseAuth integrations, each a separate `stratalog_*` package so unused dependencies stay out of your graph.
- Debug builds log via `dart:developer` (no garbled ANSI from the daemon's `print` chunker); release builds emit single-line JSON for pipelines.

## Setup

```dart
void main() {
  configureLogging(crashReporter: CrashlyticsReporter()); // before runApp
  runApp(const App());
}
```

```dart
LogLayer.auth.info('Session refreshed', data: {'expires_in': 3600});
LogLayer.storage.error('Migration failed', error: e, stackTrace: s);
const payments = LogLayer('Payments'); // declare custom layers once
payments.success('Order captured');
```

## Layers

One crisp home per record — the taxonomy names concerns, not libraries:

| Layer | Owns |
|---|---|
| `app` | bootstrap, config, DI, business logic — the fallback |
| `state` | state-management transitions (Riverpod/Provider/bloc) |
| `route` | navigation, deep links, guards |
| `ui` | widget/render issues, media, animations |
| `network` | HTTP/WebSocket traffic |
| `storage` | database, prefs, secure storage, files, caches |
| `auth` | sign-in/out, token refresh, session expiry |
| `platform` | Flutter↔OS boundary: channels, plugins, permissions, app lifecycle |
| `analytics` | events dispatched, crash-report forwarding |

There is deliberately no `lifecycle` or `background` layer: an `AppLifecycleState` change *is* a platform signal, and a background task's scheduling logs to `platform` while its work logs to that work's own domain.

## Crash reporting

Ready-made adapters: [`stratalog_crashlytics`](https://pub.dev/packages/stratalog_crashlytics) and [`stratalog_sentry`](https://pub.dev/packages/stratalog_sentry).

```dart
configureLogging(crashReporter: const CrashlyticsCrashReporter());
// or: configureLogging(crashReporter: const SentryCrashReporter());
```

Any other backend is a 2-method `CrashReporter` implementation away.

`error`+ records become reports (`critical`/`wtf` → `fatal: true`), `info`+ records become breadcrumbs. Tune thresholds or veto expected failures by constructing the writer yourself:

```dart
configureLogging(writers: [
  CrashReporterWriter(SentryReporter(), shouldReport: (r) => r.error is! Failure),
]);
```

## Integrations

Each lives in its own package, so its dependency stays out of your graph:

```dart
// stratalog_dio
dio.interceptors.add(LoggerDioInterceptor(LogLayer.network)); // add LAST

// stratalog_grpc
FooServiceClient(channel, interceptors: [LoggerGrpcInterceptor(LogLayer.network)]);

// stratalog_connectrpc — Connect / gRPC / gRPC-Web protocols
Transport(..., interceptors: [loggerConnectInterceptor(LogLayer.network)]);

// stratalog_riverpod
ProviderScope(observers: [const RiverpodLogger(LogLayer.state)], child: app);

// stratalog_auto_route
router.config(navigatorObservers: () => [AppRouterObserver(LogLayer.route)]);

// stratalog_firebase_auth — OAuth2 providers (Google/Apple/OIDC) included
FirebaseAuthLogger(FirebaseAuth.instance).attach();
```

## Changing colors

Custom layers carry their color at the declaration (`LogLayer('Payments', color: …)`); `configureLogging(domainColors: {'Auth': …})` overlays the pre-defined ones. Before picking a color, sweep candidates with `dart run tool/contrast_report.dart` — `flutter test` fails if a palette color drops below 3.0 contrast on any target background.
