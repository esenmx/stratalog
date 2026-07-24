# 0.2.0

- `logBodies` (default: debug/profile on, product OFF) gates request/response bodies out of release records; opted-in bodies under the `protobuf.omit_*_names` defines emit the tag-keyed `protoLogShape` map (new export) instead of proto3 JSON.
- Failures log the `error-code` trailer value as `error_code` (key via `errorCodeTrailer:`).
- `maskSensitiveValues` now defaults to masking in product builds.

# 0.1.0

Initial release: gRPC tap for stratalog.
