import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:stratalog/stratalog.dart';

// Mirrors Flutter's kReleaseMode without a Flutter dependency: dart2js/VM
// AOT release builds define dart.vm.product.
const bool _kProduct = .fromEnvironment('dart.vm.product');

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
/// so in a release build these lines reach the console writer and land in
/// logcat / os_log. Bodies and query strings are therefore redacted at this
/// seam rather than left to the sink — see [redactKeys] and
/// [redactBodyPaths]. Not a chirp record interceptor either: only the tap
/// sees [RequestOptions], which the path rules and the FormData case need.
/// Pass `configureLogging(minLevel: …)` if a level floor is wanted as well.
///
/// [logBodies] defaults to on in debug/profile and OFF in product builds:
/// request, response and failure bodies push user payloads into release
/// sinks (crash breadcrumbs stay at method/status/duration shape).
final class LoggerDioInterceptor({
  /// Destination layer.
  final LogLayer logger = .network,

  /// Only these header values are ever logged verbatim — a full header dump
  /// drowns the log and leaks anything a downstream interceptor attaches.
  final Set<String> headerAllowlist = defaultHeaderAllowlist,

  /// Logged presence-only as '***': the value (a bearer token, cookie,
  /// app-check token) must never land in a sink — even the debug console.
  final Set<String> sensitiveHeaders = defaultSensitiveHeaders,

  /// Keys whose values are replaced with '***' wherever they appear: at any
  /// depth of a JSON request, response or error body, and in query
  /// parameters — the `query` data entry and the URI on the message line
  /// alike. Matched case-insensitively, ignoring `_` and `-`, so one entry
  /// covers `newPassword`, `new_password` and `NEW-PASSWORD`.
  ///
  /// Deliberately **not** gated by [maskSensitiveValues]: a bearer token is
  /// worth showing on a local console, a password or CVV never is. Pass an
  /// empty set to log verbatim. String bodies pass through unparsed — cover
  /// their endpoints with [redactBodyPaths].
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
  /// records. Defaults to on in debug/profile and OFF in product builds:
  /// bodies push user payloads into release sinks (crash breadcrumbs stay at
  /// method/status/duration shape).
  final bool logBodies = !_kProduct,
}) extends Interceptor {
  /// Logs traffic to [logger], typically `LogLayer.network`.
  this;

  /// [redactKeys], normalized once so the hot path only normalizes the
  /// body's own keys.
  final Set<String> _redactKeys = {
    for (final key in redactKeys) _normalizeKey(key),
  };

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

  /// Default for [redactKeys] — credential-bearing names, already
  /// normalized. Names too generic to claim globally (`number`, `code`,
  /// `token`) are left out on purpose: scope those with [redactBodyPaths],
  /// or a blanket entry would gut every unrelated log line.
  static const Set<String> defaultRedactKeys = {
    'password',
    'newpassword',
    'oldpassword',
    'currentpassword',
    'passwordconfirmation',
    'cvv',
    'cvc',
    'pin',
    'otp',
    'secret',
    'clientsecret',
    'apikey',
    'accesstoken',
    'refreshtoken',
    'idtoken',
    'authorization',
    'cardnumber',
    'pan',
  };

  static const _mask = '***';
  static const _maskedBody = '*** redacted body ***';

  static final _keySeparators = RegExp('[_-]');

  // Namespaced so it can't collide with other interceptors' extra entries.
  static const _kStartTime = 'stratalog.start_time';

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    options.extra[_kStartTime] = DateTime.now();

    final logData = <String, Object?>{'headers': _safeHeaders(options.headers)};
    if (options.queryParameters.isNotEmpty) {
      logData['query'] = _redactKeys.isEmpty
          ? options.queryParameters
          : _redactBody(options.queryParameters);
    }
    if (logBodies && options.data != null) {
      logData['body'] = _formatData(options.data, options);
    }

    logger.trace(
      '→ ${options.method} ${_redactUri(options.uri)}',
      data: logData,
    );
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
      '← ${response.statusCode} ${request.method} ${_redactUri(request.uri)}',
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
    if (logBodies && err.response?.data != null) {
      logData['response_body'] = _formatData(err.response?.data, request);
    }

    logger.warning(
      '✗ ${err.response?.statusCode ?? err.type.name} '
      '${request.method} ${_redactUri(request.uri)}',
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

  // Passes the body through as structured data with no clipping; the sink's
  // ElidingFormatter clips oversized leaves without collapsing the JSON
  // shape. FormData never carries a readable body, so it stays a summary.
  Object? _formatData(Object? data, RequestOptions request) {
    if (redactBodyPaths.any(request.uri.path.contains)) return _maskedBody;
    if (data is FormData) {
      return 'FormData(${data.fields.length} fields, '
          '${data.files.length} files)';
    }
    if (_redactKeys.isEmpty) return data;
    return _redactBody(data);
  }

  // Rebuilds string-keyed so a `Map<String, Object?>` stays one for readers,
  // and so the record holds a snapshot the caller can no longer mutate.
  //
  // TypedData (Uint8List, ByteData, …) is guarded before the List case: it
  // implements List<int>, so without this an N-byte binary body would be
  // boxed element-by-element into an N-entry growable list synchronously on
  // the request/response hook.
  Object? _redactBody(Object? data) {
    if (data case final TypedData bytes) {
      return '<${bytes.lengthInBytes}-byte body>';
    }
    if (data case final Map<Object?, Object?> map) {
      return <String, Object?>{
        for (final MapEntry(:key, :value) in map.entries)
          '$key': _redactKeys.contains(_normalizeKey('$key'))
              ? _mask
              : _redactBody(value),
      };
    }
    if (data case final List<Object?> list) {
      return [for (final element in list) _redactBody(element)];
    }
    return data;
  }

  // Only rebuilds when a query key actually matches — `Uri.replace`
  // re-encodes and may reorder, so the common no-secret URI stays
  // byte-identical to what went over the wire. The rebuilt query is encoded
  // by hand: `replace(queryParameters:)` would percent-encode the mask into
  // `%2A%2A%2A`.
  Uri _redactUri(Uri uri) {
    if (!uri.hasQuery) return uri;
    final query = uri.queryParametersAll;
    bool match(String key) => _redactKeys.contains(_normalizeKey(key));
    if (!query.keys.any(match)) return uri;
    final parts = <String>[];
    query.forEach((key, values) {
      final encodedKey = Uri.encodeQueryComponent(key);
      if (match(key)) {
        parts.add('$encodedKey=$_mask');
      } else {
        parts.addAll(
          values.map(
            (value) => '$encodedKey=${Uri.encodeQueryComponent(value)}',
          ),
        );
      }
    });
    return uri.replace(query: parts.join('&'));
  }

  static String _normalizeKey(String key) =>
      key.toLowerCase().replaceAll(_keySeparators, '');
}
