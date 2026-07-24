# stratalog_grpc

gRPC integration for [stratalog](https://pub.dev/packages/stratalog) — taps gRPC into stratalog's colored, contrast-verified log layers.

```dart
FooServiceClient(channel, interceptors: [LoggerGrpcInterceptor()]);
```

Unary and streaming calls with method path, status code, duration, and metadata redaction. Failures log at `warning` with the `GrpcError` attached, plus the `error-code` trailer value (configurable via `errorCodeTrailer`) as `error_code` in the record data.

## Release builds & `protobuf.omit_*_names`

Product builds emit only stripping-proof fields by default: the literal method path (a stub string), the status code name (grpc's own table, not protobuf metadata), the error-code trailer, duration, and metadata (sensitive values masked in product). Request/response bodies are gated behind `logBodies` — on in debug/profile, **off in product**. Opting in (`logBodies: true`) on a build compiled with the `protobuf.omit_field_names` / `omit_enum_names` / `omit_message_names` dart-defines degrades from proto3 JSON (needs names) to the tag-keyed `writeToJson()` map — numeric keys and enum numbers that decode mechanically against the `.proto` at the release tag. `protoLogShape()` exposes the same mapping for your own message logging; never log `message.toString()`, which strips to unstructured numeric prose.

See the [stratalog README](https://github.com/esenmx/stratalog) for the layer taxonomy, theming, and crash-reporting setup.
