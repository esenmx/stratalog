# stratalog

Opinionated structured logging for Dart & Flutter, built on [chirp](https://pub.dev/packages/chirp). Melos monorepo — the core is pure Dart; every integration is its own package so its dependency stays out of your graph:

| Package | Taps |
|---|---|
| [`stratalog`](packages/stratalog) | core: layers, palette, formatter, crash-reporter boundary |
| [`stratalog_dio`](packages/stratalog_dio) | Dio HTTP client |
| [`stratalog_drift`](packages/stratalog_drift) | Drift database statements |
| [`stratalog_grpc`](packages/stratalog_grpc) | gRPC clients |
| [`stratalog_connectrpc`](packages/stratalog_connectrpc) | ConnectRPC transports (Connect / gRPC / gRPC-Web) |
| [`stratalog_riverpod`](packages/stratalog_riverpod) | Riverpod providers & mutations |
| [`stratalog_bloc`](packages/stratalog_bloc) | bloc/cubit lifecycles & transitions |
| [`stratalog_auto_route`](packages/stratalog_auto_route) | auto_route navigation |
| [`stratalog_firebase_auth`](packages/stratalog_firebase_auth) | FirebaseAuth incl. OAuth2 providers |
| [`stratalog_crashlytics`](packages/stratalog_crashlytics) | Firebase Crashlytics crash reporting |
| [`stratalog_sentry`](packages/stratalog_sentry) | Sentry crash reporting |
| [`stratalog_firebase_analytics`](packages/stratalog_firebase_analytics) | FirebaseAnalytics event mirroring |
| [`stratalog_viewer`](packages/stratalog_viewer) | in-app log browser (ring buffer + page) |

Start with the [core package README](packages/stratalog/README.md). `Network`/`Storage` payloads print as gutter-free copyable JSON by default — see [Copyable payloads](packages/stratalog/README.md#copyable-payloads).

## Development

```sh
dart pub get           # resolves the whole workspace
dart run melos analyze
dart run melos test
```
