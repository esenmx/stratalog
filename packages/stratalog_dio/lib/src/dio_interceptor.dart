import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:stratalog/redact.dart' as redact;
import 'package:stratalog/stratalog.dart';
import 'package:stratalog_dio/src/io_error_stub.dart'
    if (dart.library.io) 'package:stratalog_dio/src/io_error_io.dart';

/// Pure HTTP-wire logger — add it FIRST in the chain. Dio runs all hooks in
/// list order AND attaches every onError hook after every onResponse hook,
/// so first position sees the raw server response before any other
/// interceptor can mutate, throw over, or swallow it, and still catches
/// errors those interceptors raise. Deserialized results and their failures
/// are the provider layer's story, not this interceptor's.
///
/// Request/response trace at `trace`; failures log at `warning`, never
/// `error`: a non-2xx is expected control flow that the repository boundary
/// maps to a typed failure, not a crash.
///
/// **`trace` is not release-gated.** `configureLogging` filters by level only
/// when handed an explicit `minLevel`, and chirp's default is no floor at all,
/// so in a release build these lines reach the console writer and any extra
/// writer without its own level floor; the `warning` failure line is what
/// reaches crash breadcrumbs by default. Query strings and opted-in bodies
/// are redacted at this seam rather than left to the sink — see [redactKeys]
/// and [redactBodyPaths]. Not a chirp record interceptor either: only the tap
/// sees [RequestOptions], which the path rules and the FormData case need.
/// Pass `configureLogging(minLevel: …)` if a level floor is wanted as well.
///
/// [logBodies] defaults to `false`: request, response and failure bodies are
/// stripped by default so large JSON payloads never flood the console or
/// reach release sinks (crash breadcrumbs stay at method/status/duration
/// shape). Pass `logBodies: true` to include redacted bodies.
///
/// The failure line's error is a redacted copy stripped of raw
/// `requestOptions` headers/data and `response`; the caller still receives the
/// original [DioException]. URLs in its message are redacted like the message
/// line; an inner `SocketException`, `TlsException` or [TimeoutException]
/// keeps its text (including under `--obfuscate`), an inner [FormatException]
/// only its offset, and any other inner error logs as its type name, since its
/// text can quote a request body or a header value.
final class LoggerDioInterceptor({
  /// Destination layer.
  final LogLayer logger = .network,

  /// Only these header values are ever logged verbatim — a full header dump
  /// drowns the log and leaks anything a downstream interceptor attaches.
  /// Matched case-insensitively.
  final Set<String> headerAllowlist = defaultHeaderAllowlist,

  /// Logged presence-only as `'***'`: the value (a bearer token, cookie,
  /// app-check token) must never land in a sink — even the debug console.
  /// Matched case-insensitively.
  final Set<String> sensitiveHeaders = defaultSensitiveHeaders,

  /// Keys whose values are replaced with `'***'` wherever they appear: at any
  /// depth of a JSON request, response or error body, and in query
  /// parameters — the `query` data entry and the URI on the message line
  /// alike. Matched case-insensitively, ignoring `_` and `-`, so one entry
  /// covers `newPassword`, `new_password` and `NEW-PASSWORD`.
  ///
  /// On by default, like header masking, but independent of it:
  /// `maskSensitiveValues: false` reveals headers for local debugging and
  /// leaves these keys masked. Query strings are covered regardless of
  /// [logBodies]. Pass an empty set to log verbatim. String bodies pass
  /// through unparsed — cover their endpoints with [redactBodyPaths].
  final Set<String> redactKeys = defaultRedactKeys,

  /// Request paths whose bodies are dropped from the log entirely — request,
  /// response and error alike. Matched as a substring of the resolved
  /// `uri.path`, so `/checkout/pay` also covers `/api/v1/checkout/pay`.
  ///
  /// Reach for this where the *endpoint* is sensitive rather than a known
  /// field name: it keeps covering the next key somebody adds to that
  /// payload, which [redactKeys] cannot.
  final Set<String> redactBodyPaths = const {},

  /// Whether to redact [sensitiveHeaders] values. Defaults to `true` — a
  /// bearer token or cookie must never land verbatim in a sink, even the
  /// debug console. Pass `false` to show them for local debugging.
  final bool maskSensitiveValues = true,

  /// Whether request/response/failure bodies land in trace and warning
  /// records. Defaults to `false`: bodies are stripped out of the box so
  /// large JSON payloads never flood the console or reach release sinks
  /// (crash breadcrumbs stay at method/status/duration shape). Pass `true`
  /// to include redacted bodies.
  final bool logBodies = false,
}) extends Interceptor {
  /// Logs traffic to [logger], typically `LogLayer.network`.
  this;

  final Set<String> _headerAllowlist = {
    for (final key in headerAllowlist) key.toLowerCase(),
  };

  final Set<String> _sensitiveHeaders = {
    for (final key in sensitiveHeaders) key.toLowerCase(),
  };

  final Set<String> _redactKeys = {
    for (final key in redactKeys) redact.normalizeRedactKey(key),
  };

  /// Default for [headerAllowlist].
  static const Set<String> defaultHeaderAllowlist =
      redact.defaultHeaderAllowlist;

  /// Default for [sensitiveHeaders].
  static const Set<String> defaultSensitiveHeaders =
      redact.defaultSensitiveHeaders;

  /// Default for [redactKeys] — credential-bearing names, already normalized.
  static const Set<String> defaultRedactKeys = redact.defaultRedactKeys;

  static const _withheld = 'message withheld';
  static const _maxErrorDepth = 4;
  static const _kStartTime = 'stratalog.start_time';

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    options.extra[_kStartTime] = DateTime.now();

    final logData = <String, Object?>{
      'headers': redact.redactHeaderMap(
        options.headers,
        allowlist: _headerAllowlist,
        sensitive: _sensitiveHeaders,
        maskSensitiveValues: maskSensitiveValues,
      ),
    };
    if (options.queryParameters.isNotEmpty) {
      logData['query'] = _formatQuery(options.queryParameters);
    }
    if (logBodies && options.data != null) {
      logData['body'] = _formatData(options.data, options);
    }

    logger.trace('→ ${options.method} ${_loggedUri(options)}', data: logData);
    handler.next(options);
  }

  @override
  void onResponse(
    Response<dynamic> response,
    ResponseInterceptorHandler handler,
  ) {
    final request = response.requestOptions;

    final logData = <String, Object?>{};
    if (_elapsed(request) case final ms?) logData['duration_ms'] = ms;
    if (logBodies && response.data != null) {
      logData['body'] = _formatData(response.data, request);
    }

    logger.trace(
      '← ${response.statusCode} ${request.method} ${_loggedUri(request)}',
      data: logData,
    );
    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    final request = err.requestOptions;

    final logData = <String, Object?>{'type': err.type.name};
    if (_elapsed(request) case final ms?) logData['duration_ms'] = ms;
    if (logBodies && err.response?.data != null) {
      logData['response_body'] = _formatData(err.response?.data, request);
    }

    logger.warning(
      '✗ ${err.response?.statusCode ?? err.type.name} '
      '${request.method} ${_loggedUri(request)}',
      data: logData,
      error: _redactError(err),
      stackTrace: err.stackTrace,
    );
    handler.next(err);
  }

  // Fresh DioException stripped of raw requestOptions headers/data and
  // response, pinned to the default builder so a global readableStringBuilder
  // override cannot print requestOptions verbatim.
  DioException _redactError(DioException err, [int depth = 0]) {
    final (raw, safe) = switch (_uriOf(err.requestOptions)) {
      final uri? => ('$uri', '${redact.redactUri(uri, _redactKeys)}'),
      null => ('', ''),
    };
    String redactText(String text) => redact.redactUrlsInText(
      raw == safe ? text : text.replaceAll(raw, safe),
      _redactKeys,
    );

    final message = err.message;
    final inner = switch (err.error) {
      null => null,
      final DioException nested when depth < _maxErrorDepth => _redactError(
        nested,
        depth + 1,
      ),
      final DioException nested => '<${nested.runtimeType}>',
      FormatException(:final offset) => FormatException(
        _withheld,
        null,
        offset,
      ),
      final Object error when _echoesNoInput(error) =>
        _redactText(error, redactText) ?? error,
      final Object error => '<${error.runtimeType}>',
    };
    return DioException(
      requestOptions: RequestOptions(
        path: safe.isEmpty ? redact.redactedMask : safe,
        method: err.requestOptions.method,
      ),
      type: err.type,
      error: inner,
      message: message == null ? null : redactText(message),
      stackTrace: err.stackTrace,
    )..stringBuilder = defaultDioExceptionReadableStringBuilder;
  }

  static bool _echoesNoInput(Object error) =>
      error is TimeoutException || isSafeIoError(error);

  static String? _redactText(Object error, String Function(String) redact) {
    try {
      final text = '$error';
      final redacted = redact(text);
      return redacted == text ? null : redacted;
    } on Object {
      return '<${error.runtimeType}>';
    }
  }

  static Uri? _uriOf(RequestOptions request) {
    try {
      return request.uri;
    } on Object {
      return null;
    }
  }

  // FIXME(P3, stratalog_dio): a Uri-valued query parameter is redacted in
  // `data['query']` but printed whole on the message line, which masks by key
  // only.
  String _loggedUri(RequestOptions request) => switch (_uriOf(request)) {
    final uri? => '${redact.redactUri(uri, _redactKeys)}',
    null => redact.redactedMask,
  };

  int? _elapsed(RequestOptions request) {
    final start = request.extra[_kStartTime];
    if (start is! DateTime) return null;
    return DateTime.now().difference(start).inMilliseconds;
  }

  Object? _formatQuery(Map<String, dynamic> query) {
    if (_redactKeys.isEmpty) return query;
    try {
      return redact.redactData(
        query,
        _redactKeys,
        stringifyPlatformLeaves: true,
        encodeCustomObject: (object, redactNested) => switch (object) {
          ListParam<Object?>(:final value) => redactNested(value),
          _ => object,
        },
      );
    } on Object catch (error) {
      return '<unloggable query: ${error.runtimeType}>';
    }
  }

  Object? _formatData(Object? data, RequestOptions request) {
    final path = _uriOf(request)?.path;
    if (path == null || redactBodyPaths.any(path.contains)) {
      return redact.redactedBodyPlaceholder;
    }
    if (data is FormData) {
      return 'FormData(${data.fields.length} fields, '
          '${data.files.length} files)';
    }
    if (data case final TypedData bytes) {
      return '<${bytes.lengthInBytes}-byte body>';
    }
    if (_redactKeys.isEmpty) return data;
    try {
      return redact.redactData(
        data,
        _redactKeys,
        stringifyPlatformLeaves: true,
        encodeCustomObject: (object, redactNested) {
          if (object case ListParam<Object?>(:final value)) {
            return redactNested(value);
          }
          final Object? json;
          try {
            json = jsonDecode(jsonEncode(object));
          } on Object {
            return '<${object.runtimeType}>';
          }
          return redactNested(json);
        },
      );
    } on Object catch (error) {
      return '<unloggable body: ${error.runtimeType}>';
    }
  }
}
