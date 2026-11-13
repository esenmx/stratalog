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
| [`tools/strata`](tools/strata) | terminal viewer with foldable JSON (Go) |

Start with the [core package README](packages/stratalog/README.md). `Network`/`Storage` records print gutter-free by default — copyable SQL and JSON — see [Copyable payloads](packages/stratalog/README.md#copyable-payloads).

## strata

`strata` is a terminal viewer for a running app's records. In debug and profile builds, `configureLogging()` posts every record as JSON on the `stratalog` VM service stream, with the payload unelided, and keeps the last 1000 for a viewer that attaches late. Release builds never post. Each record shows as one collapsed line that opens into a foldable JSON tree, and new records stream in live.

```sh
go install github.com/esenmx/stratalog/tools/strata@latest
```

Run it from the Flutter app directory:

```sh
flutter run --vmservice-out-file=.flutter.vmservice   # writes the service URI
strata                    # reads ./.flutter.vmservice, waits until it exists
strata path/to/file       # a file holding the URI, or dart run --write-service-info JSON
strata ws://127.0.0.1:PORT/TOKEN=/ws   # or an http:// service URI
strata --plain            # one ANSI-free line per record on stdout, for scripts
```

When the app relaunches, `strata` keeps its records, reconnects once the file holds the new URI, and marks the restart with a divider.

| Key | Action |
|---|---|
| `↑`/`↓`, `j`/`k` | move |
| `Enter`/`Space` | open or close the record or JSON node |
| `→`/`l`, `←`/`h` | open; close, or jump to the parent |
| `e` | expand or collapse the whole record |
| `/` | filter: substring of layer, message, data, error or stack; `Esc` clears |
| `L` | cycle the minimum level (trace → debug → info → warning → error) |
| `G`/`End`, `g`/`Home` | jump to the end and follow; jump to the top |
| `c` | clear |
| `q`/`Ctrl-C` | quit |

To leave the stream out, call `configureLogging(vmStream: false)`.

## Development

```sh
dart pub get           # resolves the whole workspace
dart run melos analyze
dart run melos test
```
