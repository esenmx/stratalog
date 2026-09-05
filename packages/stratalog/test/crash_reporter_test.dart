import 'package:checks/checks.dart';
import 'package:chirp/chirp.dart';
import 'package:stratalog/stratalog.dart';
import 'package:test/test.dart';

final class _FakeReporter implements CrashReporter {
  final errors = <(Object, String?, bool)>[];
  final breadcrumbs = <(String, Map<String, Object?>?)>[];

  @override
  void recordError(
    Object error,
    StackTrace? stackTrace, {
    String? reason,
    bool fatal = false,
  }) {
    errors.add((error, reason, fatal));
  }

  @override
  void addBreadcrumb(String message, {Map<String, Object?>? data}) =>
      breadcrumbs.add((message, data));
}

final class _ThrowingReporter implements CrashReporter {
  @override
  void recordError(
    Object error,
    StackTrace? stackTrace, {
    String? reason,
    bool fatal = false,
  }) {
    throw StateError('backend not initialized'); // an Error, not Exception
  }

  @override
  void addBreadcrumb(String message, {Map<String, Object?>? data}) =>
      throw StateError('nope');
}

void main() {
  tearDown(() => Chirp.root = null);

  ChirpLogger loggerWith(CrashReporterWriter writer) {
    Chirp.root = ChirpLogger().addWriter(writer);
    return Chirp.root.child(name: 'Auth');
  }

  test('errors report, lower levels breadcrumb, trace is dropped', () {
    final reporter = _FakeReporter();
    loggerWith(CrashReporterWriter(reporter))
      ..trace('ignored')
      ..info('breadcrumb me')
      ..error('boom', error: Exception('x'))
      ..wtf('fatal boom', error: Exception('y'));

    check(reporter.breadcrumbs.map((b) => b.$1))
        .deepEquals(['[Auth/info] breadcrumb me']);
    check(reporter.errors).length.equals(2);
    check(reporter.errors[0].$2).equals('[Auth] boom');
    check(reporter.errors[0].$3).isFalse();
    check(reporter.errors[1].$3).isTrue(); // above error -> fatal
  });

  test('breadcrumbs carry record data; empty data maps to null', () {
    final reporter = _FakeReporter();
    loggerWith(CrashReporterWriter(reporter))
      ..info(
        '✗ NOT_FOUND /geo.v1.GeoService/GetCity',
        data: {'duration_ms': 12, 'error_code': 'geo.404'},
      )
      ..info('bare');

    check(reporter.breadcrumbs[0].$2)
        .isNotNull()
        .deepEquals({'duration_ms': 12, 'error_code': 'geo.404'});
    check(reporter.breadcrumbs[1].$2).isNull();
  });

  test('message stands in when no error object is attached', () {
    final reporter = _FakeReporter();
    loggerWith(CrashReporterWriter(reporter)).error('plain message');
    check(reporter.errors.single.$1).equals('plain message');
  });

  test('shouldReport vetoes reports but not breadcrumbs', () {
    final reporter = _FakeReporter();
    loggerWith(
        CrashReporterWriter(
          reporter,
          shouldReport: (r) => r.error is! FormatException,
        ),
      )
      ..error('expected', error: const FormatException())
      ..error('unexpected', error: Exception('x'));

    check(reporter.errors).length.equals(1);
    check(reporter.errors.single.$2).equals('[Auth] unexpected');
  });

  test('breadcrumbLevel null disables breadcrumbs entirely', () {
    final reporter = _FakeReporter();
    loggerWith(CrashReporterWriter(reporter, breadcrumbLevel: null))
      ..info('nope')
      ..error('yes');

    check(reporter.breadcrumbs).isEmpty();
    check(reporter.errors).length.equals(1);
  });

  test('a throwing backend (even an Error) never propagates to the caller', () {
    final logger = loggerWith(CrashReporterWriter(_ThrowingReporter()));
    check(() => logger.error('boom')).returnsNormally();
    check(() => logger.info('crumb')).returnsNormally();
  });
}
