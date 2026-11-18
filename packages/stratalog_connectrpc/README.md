# stratalog_connectrpc

ConnectRPC integration for [stratalog](https://github.com/esenmx/stratalog) — taps ConnectRPC into stratalog's colored, contrast-verified log layers.

```dart
Transport(..., interceptors: [loggerConnectInterceptor()]);
```

Works with the Connect, gRPC, and gRPC-Web protocols alike: procedure, Connect code, duration, allowlisted headers, and sensitive header redaction. Failures log at `warning` with a sanitised copy of the error attached regardless of `logBodies` — a `ConnectException` keeps its type, code and scrubbed first-line message while dropping metadata, details and cause (and one wrapping a decode, I/O or transport error keeps only that error's type as its message); a `FormatException` or `ArgumentError` (the HTTP clients echo a rejected header value, masked or not) becomes its type alone; any other error becomes its type and scrubbed first line (URL userinfo masked and URL queries removed, clipped at 256 characters) — plus the `error-code` trailer value (configurable via `errorCodeTrailer`) as `error_code` in the record data.

## Bodies & `protobuf.omit_*_names`

By default (`logBodies: false`), records emit only stripping-proof fields: the literal procedure path (a stub string), the Connect code name (a plain Dart enum, unaffected by protobuf stripping), the error-code trailer, duration, and allowlisted headers (sensitive values masked as `***` by default). Request/response bodies are stripped out of the box so large payloads never flood the console or reach release sinks. Opting in (`logBodies: true`) on a build compiled with the `protobuf.omit_field_names` / `omit_enum_names` / `omit_message_names` dart-defines degrades from proto3 JSON (needs names) to the tag-keyed `writeToJsonMap()` map — numeric keys and enum numbers that decode mechanically against the `.proto` at the release tag. `protoLogShape()` exposes the same mapping for your own message logging; never log `message.toString()`, which strips to unstructured numeric prose.

## Body redaction

Masking is on by default once `logBodies` is on: credential-like keys are masked as `***` at any depth of the logged request and response bodies — nested messages, elements of repeated fields, keys of map fields and `google.protobuf.Struct` content — and procedures matched by `redactBodyPaths` log `*** redacted body ***` instead of either body. Stream messages are never logged. A body that cannot be rendered — a `google.protobuf.Any` holding any type (the tap passes no `TypeRegistry`), or a message whose `toString()` throws — logs `<unloggable body: ArgumentError>`, its error type, and never fails the call.

```dart
loggerConnectInterceptor(
  logBodies: true,
  // Masked as `***` at any depth of a body, in both directions, whatever the
  // value's type. Defaults cover passwords, cvv/cvc, pin, otp, tokens and
  // secrets; matching ignores case and `_`/`-`, so `newPassword`,
  // `new_password` and `NEW-PASSWORD` all match. Independent of header
  // masking: maskSensitiveValues: false reveals headers and keeps these
  // masked. Pass an empty set to log bodies verbatim.
  redactKeys: {...defaultRedactKeys, 'holderName'},
  // Whole body dropped for procedures that are sensitive as such, matched as a
  // substring of the procedure path. Keeps covering the next field somebody
  // adds to that message, which a key list cannot.
  redactBodyPaths: {'/auth.v1.AuthService/'},
)
```

Limits: on a build compiled with the `protobuf.omit_*_names` defines the logged shape is keyed by tag numbers, so `redactKeys` matches nothing there — use `redactBodyPaths` for such builds. A non-protobuf message is logged via `toString()` and passes unparsed; cover its procedure with `redactBodyPaths`.

See the [stratalog README](https://github.com/esenmx/stratalog) for the layer taxonomy, theming, and crash-reporting setup.
