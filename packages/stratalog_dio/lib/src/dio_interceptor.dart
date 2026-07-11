import 'package:dio/dio.dart';
import 'package:stratalog/stratalog.dart';

/// Pure HTTP-wire logger — add it FIRST in the chain. Dio runs all hooks in
/// list order AND attaches every onError hook after every onResponse hook,
/// so first position sees the raw server response before any other
/// interceptor can mutate, throw over, or swallow it, and still catches
/// errors those interceptors raise. Deserialized results and their failures
/// are the provider layer's story, not this interceptor's.
///
/// Request/response trace at `trace` (release-gated); failures log at
/// `warning`, never `error`: a non-2xx is expected control flow that the
/// repository boundary maps to a typed failure, not a crash.
final class LoggerDioInterceptor extends Interceptor {
  /// Logs traffic to [logger], typically `LogLayer.network`.
  LoggerDioInterceptor(
    this.logger, {
    this.headerAllowlist = defaultHeaderAllowlist,
    this.sensitiveHeaders = defaultSensitiveHeaders,
    this.maskSensitiveValues = false,
  });

  /// Destination layer.
  final LogLayer logger;

  /// Whether to redact [sensitiveHeaders] values. Defaults to `false` (shows
  /// bearer tokens for local debugging).
  final bool maskSensitiveValues;

  /// Only these header values are ever logged verbatim — a full header dump
  /// drowns the log and leaks anything a downstream interceptor attaches.
  final Set<String> headerAllowlist;

  /// Logged presence-only as '***': the value (a bearer token, cookie,
  /// app-check token) must never land in a sink — even the debug console.
  final Set<String> sensitiveHeaders;

  /// Default for [headerAllowlist].
  static const Set<String> defaultHeaderAllowlist = {
    'content-type',
    'accept',
    'accept-language',
    'content-language',
    'x-request-id',
  };

  /// Default for [sensitiveHeaders].
  static const Set<String> defaultSensitiveHeaders = {
    'authorization',
    'cookie',
    'x-api-key',
  };

  // Namespaced so it can't collide with other interceptors' extra entries.
  static const _kStartTime = 'stratalog.start_time';

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    options.extra[_kStartTime] = DateTime.now();

    final logData = <String, Object?>{'headers': _safeHeaders(options.headers)};
    if (options.queryParameters.isNotEmpty) {
      logData['query'] = options.queryParameters;
    }
    if (options.data != null) {
      logData['body'] = _formatData(options.data);
    }

    logger.trace('→ ${options.method} ${options.uri}', data: logData);
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
    if (response.data != null) logData['body'] = _formatData(response.data);

    logger.trace(
      '← ${response.statusCode} ${request.method} ${request.uri}',
      data: logData,
    );
    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    final request = err.requestOptions;

    // No status ⇒ the dio type names the cause instead: `✗ connectionError`,
    // `✗ receiveTimeout` — or `✗ unknown` for an exception another
    // interceptor threw over a response dio already dropped (its raw body is
    // on the `←` trace line above).
    final logData = <String, Object?>{'type': err.type.name};
    if (_elapsed(request) case final ms?) logData['duration_ms'] = ms;
    if (err.response?.data != null) {
      logData['response_body'] = _formatData(err.response?.data);
    }

    logger.warning(
      '✗ ${err.response?.statusCode ?? err.type.name} '
      '${request.method} ${request.uri}',
      data: logData,
      error: err,
      stackTrace: err.stackTrace,
    );
    handler.next(err);
  }

  Map<String, Object?> _safeHeaders(Map<String, dynamic> headers) {
    final safe = <String, Object?>{};
    headers.forEach((key, value) {
      final k = key.toLowerCase();
      if (sensitiveHeaders.contains(k)) {
        safe[k] = maskSensitiveValues ? '***' : value;
      } else if (headerAllowlist.contains(k)) {
        safe[k] = value;
      }
    });
    return safe;
  }

  int? _elapsed(RequestOptions request) {
    final start = request.extra[_kStartTime];
    if (start is! DateTime) return null;
    return DateTime.now().difference(start).inMilliseconds;
  }

  // Passes the body through verbatim as structured data; the sink's
  // ElidingFormatter clips oversized leaves without collapsing the JSON
  // shape. FormData never carries a readable body, so it stays a summary.
  Object? _formatData(Object? data) {
    if (data is FormData) {
      return 'FormData(${data.fields.length} fields, '
          '${data.files.length} files)';
    }
    return data;
  }
}
