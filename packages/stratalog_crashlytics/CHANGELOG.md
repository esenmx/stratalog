# Unreleased

- Fixed: `recordError`/`addBreadcrumb` wrapped the Crashlytics future in `unawaited` — a no-op that leaves the future's error unhandled, so an SDK failure erupted as an unhandled zone error instead of being swallowed by `CrashReporterWriter`'s contract. Now `.ignore()`.

# 0.2.0

- Breadcrumbs inline the record's `data:` map into the Crashlytics log string (tracks stratalog 0.3.0 `addBreadcrumb` signature).

# 0.1.0

Initial release: Firebase Crashlytics CrashReporter adapter for stratalog.
