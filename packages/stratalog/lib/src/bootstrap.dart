import 'package:chirp/chirp.dart';

import 'package:stratalog/src/crash_reporter.dart';
import 'package:stratalog/src/formatter.dart';
import 'package:stratalog/src/ide_writer.dart';

// Mirrors Flutter's kReleaseMode without a Flutter dependency: dart2js/VM
// AOT release builds define dart.vm.product.
const bool _kReleaseMode = .fromEnvironment('dart.vm.product');

/// Configures the global chirp root. Call ONCE from bootstrap, before
/// `runApp`. To reconfigure, call again — `LogLayer` re-resolves against the
/// new root automatically; never mutate `Chirp.root` in place.
///
/// - Debug/profile: [StructuredLogFormatter] through [IdeDebugConsoleWriter]
///   (bypasses the Flutter daemon's `print()` chunker so long ANSI-colored
///   lines never get garbled). Override the format via [debugFormatter];
///   [domainColors] then has no effect — pass yours to your formatter.
/// - Release: single-line JSON to stdout for log pipelines; override via
///   [releaseFormatter].
/// - [crashReporter] attaches a [CrashReporterWriter] in every mode (debug
///   builds usually construct a no-op adapter). For custom report/breadcrumb
///   thresholds or a [CrashReporterWriter.new] `shouldReport` filter, build
///   the writer yourself and pass it via [writers] instead.
void configureLogging({
  List<ChirpWriter> writers = const [],
  Map<String, ConsoleColor> domainColors = const {},
  CrashReporter? crashReporter,
  ChirpLogLevel? minLevel,
  ChirpFormatter? debugFormatter,
  ChirpFormatter? releaseFormatter,
}) {
  final logger = ChirpLogger();
  if (minLevel != null) logger.setMinLogLevel(minLevel);

  if (_kReleaseMode) {
    logger.addConsoleWriter(
      formatter: releaseFormatter ?? const JsonLogFormatter(),
    );
  } else {
    logger.addWriter(
      IdeDebugConsoleWriter(
        formatter:
            debugFormatter ??
            StructuredLogFormatter(domainColors: domainColors),
      ),
    );
  }

  if (crashReporter != null) {
    logger.addWriter(CrashReporterWriter(crashReporter));
  }
  writers.forEach(logger.addWriter);

  Chirp.root = logger;
}
