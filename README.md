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

`strata` is a terminal viewer and CLI inspector for `stratalog` records. In debug and profile builds, `configureLogging()` posts every record as JSON on the `stratalog` VM service stream (across all isolates, with payloads unelided) and buffers the last 1000 per isolate for late-attaching viewers. Release builds never post.

```sh
go install github.com/esenmx/stratalog/tools/strata@latest
```

Run it from the Flutter or Dart app directory:

```sh
flutter run --vmservice-out-file=.flutter.vmservice   # writes the service URI
strata                           # TUI on ./.flutter.vmservice ($STRATA_TARGET / $VM_SERVICE_URI fallback)
strata path/to/flutter.log       # URI file, --write-service-info JSON, or flutter/dart run stdout log
strata ws://127.0.0.1:PORT/TOKEN=/ws
strata --once --json > run.jsonl # snapshot buffered history as lossless NDJSON and exit
strata run.jsonl                 # open a saved .jsonl/.ndjson capture in the TUI (or `-` for stdin)
strata --plain -l warning -L Network,Storage -g timeout   # script/agent CLI filtering (auto-plain when piped)
```

When the app hot-restarts or relaunches, `strata` keeps its records, reconnects once the target holds the new URI, and marks the restart with a divider (worker isolates log inline with `@isolate` badges).

| Key | Action |
|---|---|
| `↑`/`↓`, `j`/`k`, `PgUp`/`PgDn`, `Ctrl-U`/`Ctrl-D` | move / page |
| `[`/`]`, `K`/`J` | jump to previous / next record header |
| `Enter`/`Space` | open or close the record, JSON node, multi-line string, or stack trace |
| `→`/`l`, `←`/`h` | open; close, or jump to parent |
| `e` | expand or collapse the whole record |
| `w` | toggle soft-wrapping for long messages, URLs, and scalar strings |
| `y` / `Y` | copy focused value/node/error/stack (`y`) or raw `record_v1` JSON (`Y`) to clipboard |
| `/` (`n`/`N`, `Esc`) | substring filter with match highlighting (`n`/`N` next/prev hit; `Esc` clears anchored on current record) |
| `f` / `F` | toggle layer filter chips (`1`–`9` / `Space`, `a` all); `F` clears layer filter |
| `L` | cycle minimum chirp level (`trace` → `debug` → `info` → `notice` → `success` → `warning` → `error` → `critical` → `wtf`) |
| `G`/`End`, `g`/`Home` | jump to the end and follow; jump to the top |
| `c`, `?`, `q`/`Ctrl-C` | clear, toggle key help bar, quit |

To leave the stream out, call `configureLogging(vmStream: false)`.

## Development

```sh
dart pub get           # resolves the whole workspace
dart run melos analyze
dart run melos test
```
