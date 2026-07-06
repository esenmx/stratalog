/// Opinionated structured logging on chirp — colored layer loggers readable
/// on light & dark themes, with pluggable crash reporting.
///
/// Integrations live in their own entrypoints so unused ones stay out of
/// your import graph:
/// - `package:stratalog/dio.dart` — `LoggerDioInterceptor`
/// - `package:stratalog/riverpod.dart` — `RiverpodLogger`
/// - `package:stratalog/auto_route.dart` — `AppRouterObserver`
library;

export 'src/bootstrap.dart';
export 'src/crash_reporter.dart';
export 'src/formatter.dart';
export 'src/ide_writer.dart';
export 'src/layers.dart';
export 'src/palette.dart';
