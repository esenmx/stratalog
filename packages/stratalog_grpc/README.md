# stratalog_grpc

gRPC integration for [stratalog](https://github.com/esenmx/stratalog) — taps gRPC into stratalog's colored, contrast-verified log layers.

```dart
FooServiceClient(channel, interceptors: [LoggerGrpcInterceptor()]);
```

Unary and streaming calls with method path, status code, duration, allowlisted metadata, and sensitive metadata redaction. Failures log at `warning` with a `GrpcError` reduced to its code and status message attached (trailers, details and raw response stripped), or for any other error its type alone (`FormatException`, `ArgumentError`) or the first line of its text. In either text the call's masked sensitive metadata values are masked as `***`, since grpc folds a call-setup failure's text (a failing metadata provider, a rejected header) into the status message; a value of any other header, or one a metadata provider adds, is not masked there. The caller still receives the original error. Records also carry the `error-code` trailer value (configurable via `errorCodeTrailer`) as `error_code` in the record data.

## Bodies & `protobuf.omit_*_names`

By default (`logBodies: false`), records emit only stripping-proof fields: the literal method path (a stub string), the status code name (grpc's own table, not protobuf metadata), the error-code trailer, duration, allowlisted metadata (sensitive values masked as `***` by default), and on failure the attached `GrpcError`'s code and status message (masked sensitive metadata values masked there too). Request/response bodies are stripped out of the box so large payloads never flood the console or reach release sinks. Opting in (`logBodies: true`) on a build compiled with the `protobuf.omit_field_names` / `omit_enum_names` / `omit_message_names` dart-defines degrades from proto3 JSON (needs names) to the tag-keyed `writeToJsonMap()` map — numeric keys and enum numbers that decode mechanically against the `.proto` at the release tag. `protoLogShape()` exposes the same mapping for your own message logging; never log `message.toString()`, which strips to unstructured numeric prose.

## Body redaction

Opted-in bodies (`logBodies: true`) are redacted at this seam, not at the sink, because `trace` is **not** release-gated: masking is on by default as soon as `logBodies` is on. Only unary request and response bodies are ever logged; streaming lines (`⇄`) carry metadata, status and duration, never message content.

```dart
LoggerGrpcInterceptor(
  logBodies: true,
  // Masked as `***` at any depth of a request or response body — nested
  // messages, repeated fields, map-field keys, google.protobuf.Struct
  // content. Defaults cover passwords, cvv/cvc, pin, otp, tokens and
  // secrets; matching ignores case and `_`/`-`. On by default like metadata
  // masking, but independent of it: maskSensitiveValues: false reveals
  // metadata and keeps these masked. Pass an empty set to log verbatim.
  redactKeys: {...LoggerGrpcInterceptor.defaultRedactKeys, 'holderName'},
  // Whole body dropped — request and response — for methods that are
  // sensitive as such, matched as a substring of the method path, so a
  // service prefix covers every method. Keeps covering the next field
  // somebody adds to that message, which a key list cannot.
  redactBodyPaths: {'/auth.v1.AuthService/'},
)
```

`redactKeys` matches field names, so it cannot match anything on a build compiled with the `protobuf.omit_*_names` defines (the logged shape is keyed by tag numbers there), nor inside a non-protobuf message, which logs as its unparsed `toString()`. `redactBodyPaths` covers both: use it for any method whose body must never be logged on such builds. A body proto3 JSON cannot serialize (a packed `google.protobuf.Any`, a `google.protobuf.Value` with no kind) is logged as `<unloggable body: ArgumentError>`, its error type, never as its unredacted `toString()`; the call itself proceeds untouched.

See the [stratalog README](https://github.com/esenmx/stratalog) for the layer taxonomy, theming, and crash-reporting setup.
