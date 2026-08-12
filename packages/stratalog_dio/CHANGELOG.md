# 0.2.0

- `redactBodyKeys` (default `defaultRedactBodyKeys`: passwords, `cvv`/`cvc`, `pin`, `otp`, tokens, secrets) masks matching values as `***` at any depth of a request, response or error body. Matching is case-insensitive and ignores `_`/`-`, so one entry covers `newPassword`, `new_password` and `NEW-PASSWORD`. Unlike `maskSensitiveValues` this is always on — a bearer token is worth showing on a local console, a password is not. `redactBodyKeys: const {}` restores verbatim bodies.
- `redactBodyPaths` (default empty) drops the body entirely — request, response and error — for requests whose resolved `uri.path` contains a listed entry. For endpoints that are sensitive as a whole, so the next field added to that payload stays covered.
- Docs: the class no longer claims `trace` is release-gated. `configureLogging` filters by level only when given an explicit `minLevel`, and chirp defaults to no floor, so these records reach the release console writer and land in logcat / os_log.

# 0.1.0

Initial release: Dio tap for stratalog.
