/// Opinionated structured logging on chirp — colored layer loggers readable
/// on light & dark themes, with pluggable crash reporting. Pure Dart.
///
/// Integrations live in sibling packages so their dependencies stay out of
/// your graph: `stratalog_dio`, `stratalog_drift`, `stratalog_grpc`,
/// `stratalog_connectrpc`, `stratalog_riverpod`, `stratalog_bloc`,
/// `stratalog_auto_route`, `stratalog_firebase_auth`,
/// `stratalog_firebase_analytics`, `stratalog_crashlytics`,
/// `stratalog_sentry`, and `stratalog_viewer`.
library;

export 'src/bootstrap.dart';
export 'src/crash_reporter.dart';
export 'src/elide.dart';
export 'src/formatter.dart';
export 'src/ide_writer.dart';
export 'src/layers.dart';
export 'src/palette.dart';
export 'src/snapshot.dart';
