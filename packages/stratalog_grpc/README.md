# stratalog_grpc

gRPC integration for [stratalog](https://github.com/esenmx/stratalog) — taps gRPC into stratalog's colored, contrast-verified log layers.

```dart
FooServiceClient(channel, interceptors: [LoggerGrpcInterceptor()]);
```

Unary and streaming calls with method path, status code, duration, allowlisted metadata, and sensitive metadata redaction. Failures log at `warning` with the `GrpcError` attached, plus the `error-code` trailer value (configurable via `errorCodeTrailer`) as `error_code` in the record data.

## Bodies & `protobuf.omit_*_names`

By default (`logBodies: false`), records emit only stripping-proof fields: the literal method path (a stub string), the status code name (grpc's own table, not protobuf metadata), the error-code trailer, duration, and allowlisted metadata (sensitive values masked as `***` by default). Request/response bodies are stripped out of the box so large payloads never flood the console or reach release sinks. Opting in (`logBodies: true`) on a build compiled with the `protobuf.omit_field_names` / `omit_enum_names` / `omit_message_names` dart-defines degrades from proto3 JSON (needs names) to the tag-keyed `writeToJsonMap()` map — numeric keys and enum numbers that decode mechanically against the `.proto` at the release tag. `protoLogShape()` exposes the same mapping for your own message logging; never log `message.toString()`, which strips to unstructured numeric prose.

See the [stratalog README](https://github.com/esenmx/stratalog) for the layer taxonomy, theming, and crash-reporting setup.
