# Unreleased

- `IdeDebugConsoleWriter` coalesces records written in one event-loop turn into a single `dart:developer log()` call (rendered records joined with newlines, level = the batch's max): the IDE's DAP handler resolves each event's string asynchronously and drops the future, so separate events could reach the debug console out of order. Injectable `emit` seam for tests; lines buffered when the process hard-crashes before the microtask flush are lost (debug console only).
- Release console writer emits via `stdout.writeln` instead of `print()` — line-atomic with no length cap, so a single-line JSON record no longer tears at Android's 1024-char liblog buffer; web falls back to `print`. Caveat: neither Android logcat (`log.redirect-stdio` off by default) nor release-iOS os_log mirrors raw process stdout — pass `console:` if you scrape device logs.
- `configureLogging(console:)` replaces the default console writer (IDE writer in debug, JSON stdout writer in release) instead of appending — an added console writer double-emitted every record in IDE sessions; the packaged example now uses it. Not wrapped in `ElidingFormatter`; wrap yours.
- `snapshotData` exported; `CrashReporterWriter` snapshots breadcrumb `data` before handing it to the backend — chirp passes writers the caller's live map by reference.
- `snapshotData`/`elideJson`/`elideData` are cycle-safe: a Map/Iterable re-entered on the current traversal path renders as `'<cycle>'` instead of recursing until the stack blows inside the log call. Detection is path-based — aliased (DAG) substructure, the same map or list referenced twice without a cycle, copies/elides normally at every occurrence.
- `StructuredLogFormatter` renders unencodable/cyclic `data` as `<unencodable: …>` instead of throwing inside chirp's writer loop (which would skip every writer queued after it).
- README: uncaught-error wiring logs `PlatformDispatcher.onError` at `.critical` so `CrashReporterWriter` reports it `fatal: true` — at the previously documented `.error` it reported `fatal: false`, silently losing the `recordFlutterFatalError` semantics; the level→fatal mapping is now stated explicitly.

# 0.3.0

- **Breaking**: `CrashReporter.addBreadcrumb` gains `{Map<String, Object?>? data}`; `CrashReporterWriter` forwards the record's `data:` map on breadcrumbs (null when empty). Breadcrumb discipline documented: method path/status/codes/durations/ids, never message bodies.

# 0.2.0

- Per-layer elision: `ElidingFormatter.layerElision` keys `ElisionConfig` budgets by `loggerName`; `ElisionConfig.none` passes payloads verbatim, `ElisionConfig.vital` clips hard to vital fields. `configureLogging(layerElision:)` defaults to `defaultLayerElision` — Network/Storage print untruncated on the debug console (their JSON is a copy-out artifact), State clips to vital fields; release output keeps the single global budget. `ElidingFormatter.of` honors `ElisionConfig.enabled`, so `elision: ElisionConfig.none` disables the global budget while keeping per-layer overrides.
- `StructuredLogFormatter.rawDataLayers` (default `{'Network', 'Storage'}`): listed layers render the entire body flush-left with no gutter — copy-pastable multi-line SQL messages and valid JSON payloads; `const {}` restores the gutter everywhere.

# 0.1.0

Initial release: layer loggers with contrast-verified colors (solarized + soft-gray, light + dark), `StructuredLogFormatter`, `CrashReporter` adapter boundary, Dio/Riverpod/auto_route taps, JSON release output.
