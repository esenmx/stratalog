# Unreleased

- Streaming calls now log their real terminal outcome: grpc's `trailers` future never errors (it completes before the status check, and with `{}` on cancel/transport teardown), so failed and cancelled streams used to print `⇄ done`. The interceptor now returns a pass-through `ResponseStream` proxy that observes the caller's own subscription — failures log `✗ <STATUS>` at warning exactly once (with the `error-code` trailer), clean ends log `⇄ done` exactly once, and cancellation (subscription cancel or `cancel()`) logs a distinct `⇄ cancelled` trace line. Client-streaming calls consumed via `.single` get the same treatment. Caller-visible stream semantics are unchanged.
- Fixed: `interceptUnary` wrapped its side-listener future in `unawaited` — a no-op that leaves the future's error unhandled, so a writer throwing during the outcome log erupted as an unhandled zone error after the caller already had its result. Now `.ignore()`, matching the streaming `.single` seam.

# 0.2.0

- `logBodies` (default: debug/profile on, product OFF) gates request/response bodies out of release records; opted-in bodies under the `protobuf.omit_*_names` defines emit the tag-keyed `protoLogShape` map (new export) instead of proto3 JSON.
- Failures log the `error-code` trailer value as `error_code` (key via `errorCodeTrailer:`).
- `maskSensitiveValues` now defaults to masking in product builds.

# 0.1.0

Initial release: gRPC tap for stratalog.
