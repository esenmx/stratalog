# Unreleased

- Stream calls no longer log `← OK` when the interceptor future completes (that only marks headers received). The interceptor now returns a `StreamResponse` wrapping the message stream — same headers/trailers — and logs the terminal line exactly once at stream end: `⇄ done` on clean completion, the `✗` failure line on error. Stream failures were previously never logged.
- Failure logging now covers non-`ConnectException` stream errors (code placeholder `-`), rethrown untouched — no more dangling request arrows.

# 0.2.0

- `logBodies` (default: debug/profile on, product OFF) gates request/response bodies out of release records; opted-in bodies under the `protobuf.omit_*_names` defines emit the tag-keyed `protoLogShape` map (new export) instead of proto3 JSON.
- Failures log the `error-code` trailer value as `error_code` (key via `errorCodeTrailer:`).
- `maskSensitiveValues` now defaults to masking in product builds.

# 0.1.0

Initial release: ConnectRPC tap for stratalog.
