# stratalog

Opinionated structured logging for Flutter, built on [chirp](https://pub.dev/packages/chirp).

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
- **Stack taps** — `LoggerDioInterceptor` (redacted headers, truncated bodies), `RiverpodLogger` (all observer + mutation hooks), `AppRouterObserver` (auto_route), each behind its own entrypoint so unused ones stay out of your import graph.
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

```dart
final class CrashlyticsReporter implements CrashReporter {
  @override
  void recordError(Object error, StackTrace? stackTrace,
          {String? reason, bool fatal = false}) =>
      FirebaseCrashlytics.instance
          .recordError(error, stackTrace, reason: reason, fatal: fatal);

  @override
  void addBreadcrumb(String message) =>
      FirebaseCrashlytics.instance.log(message);
}
```

`error`+ records become reports (`critical`/`wtf` → `fatal: true`), `info`+ records become breadcrumbs. Tune thresholds or veto expected failures by constructing the writer yourself:

```dart
configureLogging(writers: [
  CrashReporterWriter(SentryReporter(), shouldReport: (r) => r.error is! Failure),
]);
```

## Integrations

```dart
import 'package:stratalog/dio.dart';
dio.interceptors.add(LoggerDioInterceptor(LogLayer.network)); // add LAST

import 'package:stratalog/riverpod.dart';
ProviderScope(observers: [RiverpodLogger(LogLayer.state)], child: app);

import 'package:stratalog/auto_route.dart';
router.config(navigatorObservers: () => [AppRouterObserver(LogLayer.route)]);
```

## Changing colors

Custom layers carry their color at the declaration (`LogLayer('Payments', color: …)`); `configureLogging(domainColors: {'Auth': …})` overlays the pre-defined ones. Before picking a color, sweep candidates with `dart run tool/contrast_report.dart` — `flutter test` fails if a palette color drops below 3.0 contrast on any target background.
