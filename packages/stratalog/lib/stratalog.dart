/// Opinionated structured logging on chirp — colored layer loggers readable
/// on light & dark themes, with pluggable crash reporting. Pure Dart.
///
/// Integrations live in sibling packages so their dependencies stay out of
/// your graph: `stratalog_dio`, `stratalog_grpc`, `stratalog_connectrpc`,
/// `stratalog_riverpod`, `stratalog_auto_route`, `stratalog_firebase_auth`.
library;

export 'src/bootstrap.dart';
export 'src/crash_reporter.dart';
export 'src/elide.dart';
export 'src/formatter.dart';
export 'src/ide_writer.dart';
export 'src/layers.dart';
export 'src/palette.dart';
