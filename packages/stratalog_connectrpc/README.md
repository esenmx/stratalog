# stratalog_connectrpc

ConnectRPC integration for [stratalog](https://github.com/esenmx/stratalog) — taps ConnectRPC into stratalog's colored, contrast-verified log layers.

```dart
Transport(..., interceptors: [loggerConnectInterceptor()]);
```

Works with the Connect, gRPC, and gRPC-Web protocols alike: procedure, Connect code, duration, allowlisted headers, and sensitive header redaction. Failures log at `warning` with the `ConnectException` attached, plus the `error-code` trailer value (configurable via `errorCodeTrailer`) as `error_code` in the record data.

## Bodies & `protobuf.omit_*_names`

By default (`logBodies: false`), records emit only stripping-proof fields: the literal procedure path (a stub string), the Connect code name (a plain Dart enum, unaffected by protobuf stripping), the error-code trailer, duration, and allowlisted headers (sensitive values masked as `***` by default). Request/response bodies are stripped out of the box so large payloads never flood the console or reach release sinks. Opting in (`logBodies: true`) on a build compiled with the `protobuf.omit_field_names` / `omit_enum_names` / `omit_message_names` dart-defines degrades from proto3 JSON (needs names) to the tag-keyed `writeToJsonMap()` map — numeric keys and enum numbers that decode mechanically against the `.proto` at the release tag. `protoLogShape()` exposes the same mapping for your own message logging; never log `message.toString()`, which strips to unstructured numeric prose.

See the [stratalog README](https://github.com/esenmx/stratalog) for the layer taxonomy, theming, and crash-reporting setup.
