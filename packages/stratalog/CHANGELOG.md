# 0.2.0

- Per-layer elision: `ElidingFormatter.layerElision` keys `ElisionConfig` budgets by `loggerName`; `ElisionConfig.none` passes payloads verbatim, `ElisionConfig.vital` clips hard to vital fields. `configureLogging(layerElision:)` defaults to `defaultLayerElision` — Network/Storage print untruncated on the debug console (their JSON is a copy-out artifact), State clips to vital fields; release output keeps the single global budget. `ElidingFormatter.of` honors `ElisionConfig.enabled`, so `elision: ElisionConfig.none` disables the global budget while keeping per-layer overrides.
- `StructuredLogFormatter.rawDataLayers` (default `{'Network', 'Storage'}`): listed layers render the entire body flush-left with no gutter — copy-pastable multi-line SQL messages and valid JSON payloads; `const {}` restores the gutter everywhere.

# 0.1.0

Initial release: layer loggers with contrast-verified colors (solarized + soft-gray, light + dark), `StructuredLogFormatter`, `CrashReporter` adapter boundary, Dio/Riverpod/auto_route taps, JSON release output.
