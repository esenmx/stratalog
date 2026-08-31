# Unreleased

- **Breaking:** `maskSensitiveValues` now defaults to `true` — `sensitiveHeaders` values (`authorization`, `cookie`, `x-api-key` by default) are masked as `***` out of the box. Pass `maskSensitiveValues: false` to restore the old verbatim-for-local-debugging behavior.
- `logBodies` (default: debug/profile on, product OFF) gates `body`/`response_body` out of release records on both the success (`onRequest`/`onResponse`) and failure (`onError`) paths — bodies were reaching release sinks, and `CrashReporterWriter` forwards `warning` records as breadcrumbs.
- Fixed: a `TypedData` body (e.g. raw `Uint8List` bytes) is now summarized as `'<N-byte body>'` instead of being boxed element-by-element into an N-entry list — `Uint8List` implements `List<int>`, so it previously matched the list-recursion case in `_redactBody`.

# 0.2.0

- `redactKeys` (default `defaultRedactKeys`: passwords, `cvv`/`cvc`, `pin`, `otp`, tokens, secrets) masks matching values as `***` at any depth of a request, response or error body, and in query strings — both the `query` data entry and the URI on the message line (a URI with no matching key logs byte-identical). Matching is case-insensitive and ignores `_`/`-`, so one entry covers `newPassword`, `new_password` and `NEW-PASSWORD`. Unlike `maskSensitiveValues` this is always on — a bearer token is worth showing on a local console, a password is not. String bodies pass through unparsed — cover their endpoints with `redactBodyPaths`. `redactKeys: const {}` restores verbatim logging.
- `redactBodyPaths` (default empty) drops the body entirely — request, response and error — for requests whose resolved `uri.path` contains a listed entry. For endpoints that are sensitive as a whole, so the next field added to that payload stays covered.
- Docs: the class no longer claims `trace` is release-gated. `configureLogging` filters by level only when given an explicit `minLevel`, and chirp defaults to no floor, so these records reach the release console writer and land in logcat / os_log.

# 0.1.0

Initial release: Dio tap for stratalog.
