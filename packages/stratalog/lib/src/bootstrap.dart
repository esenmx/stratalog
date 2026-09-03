import 'package:chirp/chirp.dart';

import 'package:stratalog/src/console_output_stub.dart'
    if (dart.library.io) 'package:stratalog/src/console_output_io.dart';
import 'package:stratalog/src/crash_reporter.dart';
import 'package:stratalog/src/elide.dart';
import 'package:stratalog/src/formatter.dart';
import 'package:stratalog/src/ide_writer.dart';

// Mirrors Flutter's kReleaseMode without a Flutter dependency: dart2js/VM
// AOT release builds define dart.vm.product.
const bool _kReleaseMode = .fromEnvironment('dart.vm.product');

/// Configures the global chirp root. Call ONCE from main(), before
/// `runApp`. To reconfigure, call again — `LogLayer` re-resolves against the
/// new root automatically; never mutate `Chirp.root` in place.
///
/// - Debug/profile: [StructuredLogFormatter] through [IdeDebugConsoleWriter]
///   (bypasses the Flutter daemon's `print()` chunker so long ANSI-colored
///   lines never get garbled). Override the format via [debugFormatter];
///   [domainColors] then has no effect — pass yours to your formatter.
/// - Release: single-line JSON via `stdout.writeln` for log pipelines —
///   line-atomic with no length cap, where `print()` tears one record into
///   several logcat entries past Android's 1024-char liblog buffer. Caveat:
///   Android's logcat mirrors `print()`, not raw process stdout (app stdout
///   goes to `/dev/null` unless the `log.redirect-stdio` system property is
///   set), and release iOS likewise routes `print()` through os_log while
///   raw stdout reaches neither Console.app nor the unified log — a
///   device-log-scraping pipeline needs its own [console] writer.
///   Override the format via [releaseFormatter].
/// - [console] REPLACES the default console writer (the IDE writer in debug,
///   the JSON stdout writer in release) instead of being appended — a second
///   console writer next to the default double-emits every record in an IDE
///   session. Like [writers], it is not wrapped: apply [ElidingFormatter]
///   yourself if wanted.
/// - [crashReporter] attaches a [CrashReporterWriter] in every mode (debug
///   builds usually construct a no-op adapter). For custom report/breadcrumb
///   thresholds or a [CrashReporterWriter.new] `shouldReport` filter, build
///   the writer yourself and pass it via [writers] instead.
/// - [elision] wraps the console/release formatter in an [ElidingFormatter]
///   so oversized `data` leaves (big JSON bodies, base64 blobs, long arrays)
///   are structure-elided at the sink — producers log full payloads. Pass
///   `null` to disable, or a tuned [ElisionConfig]. Extra [writers] you pass
///   are left untouched; wrap them in [ElidingFormatter] yourself if wanted
///   (an in-app viewer typically keeps the full body — two-tier logging).
/// - [layerElision] overrides the budget per `loggerName` on the *debug*
///   console only — by default Network/Storage payloads print verbatim
///   (their JSON is a copy-out artifact) while State clips to vital fields.
///   Release output keeps the single [elision] budget everywhere: full
///   network bodies in prod log pipelines would be a volume regression.
///   `elision: null` removes the wrapper entirely, so it also drops
///   [layerElision]; to keep per-layer budgets with no global one, pass
///   `elision: ElisionConfig.none` instead.
void configureLogging({
  List<ChirpWriter> writers = const [],
  ChirpWriter? console,
  Map<String, ConsoleColor> domainColors = const {},
  CrashReporter? crashReporter,
  ChirpLogLevel? minLevel,
  ChirpFormatter? debugFormatter,
  ChirpFormatter? releaseFormatter,
  ElisionConfig? elision = const ElisionConfig(),
  Map<String, ElisionConfig> layerElision = defaultLayerElision,
}) {
  final logger = ChirpLogger();
  if (minLevel != null) logger.setMinLogLevel(minLevel);

  ChirpFormatter wrap(
    ChirpFormatter formatter, {
    Map<String, ElisionConfig> layerElision = const {},
  }) => elision == null
      ? formatter
      : ElidingFormatter.of(formatter, elision, layerElision: layerElision);

  if (console != null) {
    logger.addWriter(console);
  } else if (_kReleaseMode) {
    logger.addWriter(
      PrintConsoleWriter(
        formatter: wrap(releaseFormatter ?? const JsonLogFormatter()),
        output: writeConsoleLine,
        // chirp reads a null maxChunkLength as "platform default" (924 on
        // Android), which would still split one record across writeln calls
        // — stdout has no liblog cap, so chunking is forced off with an
        // unreachable budget.
        maxChunkLength: 1 << 30,
      ),
    );
  } else {
    logger.addWriter(
      IdeDebugConsoleWriter(
        formatter: wrap(
          debugFormatter ?? StructuredLogFormatter(domainColors: domainColors),
          layerElision: layerElision,
        ),
      ),
    );
  }

  if (crashReporter != null) {
    logger.addWriter(CrashReporterWriter(crashReporter));
  }
  writers.forEach(logger.addWriter);

  Chirp.root = logger;
}
