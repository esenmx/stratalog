import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:stratalog/stratalog.dart';

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
/// The failure line's error is a redacted copy; the caller still receives the
/// original [DioException]. URLs in its message are redacted like the message
/// line; an inner `SocketException`, `TlsException` or [TimeoutException]
/// keeps its text, an inner [FormatException] only its offset, and any other
/// inner error logs as its type name, since its text can quote a request body
/// or a header value. The dart:io types are recognised by name, so a build
/// compiled with `--obfuscate` logs those as their type name too.
final class LoggerDioInterceptor({
  /// Destination layer.
  final LogLayer logger = .network,

  /// Only these header values are ever logged verbatim — a full header dump
  /// drowns the log and leaks anything a downstream interceptor attaches.
  /// Matched case-insensitively.
  final Set<String> headerAllowlist = defaultHeaderAllowlist,

  /// Logged presence-only as '***': the value (a bearer token, cookie,
  /// app-check token) must never land in a sink — even the debug console.
  /// Matched case-insensitively.
  final Set<String> sensitiveHeaders = defaultSensitiveHeaders,

  /// Keys whose values are replaced with '***' wherever they appear: at any
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

  /// [redactKeys], normalized once so the hot path only normalizes the
  /// body's own keys.
  final Set<String> _redactKeys = {
    for (final key in redactKeys) _normalizeKey(key),
  };

  // Only a bracketed entry (`filter[ssn]`) can match across levels; without
  // one, each key is matched alone and no ancestor path is built.
  final bool _matchesKeyPaths = redactKeys.any((key) => key.contains('['));

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
  static const _withheld = 'message withheld';

  static final _keySeparators = RegExp('[_-]');

  // dio flattens nested query maps into `auth[password]`.
  static final _keyBrackets = RegExp(r'[\[\]]');

  // Ends at whitespace only: a query value may hold `,` `)` or quotes. The
  // scheme is bounded: unbounded, a long scheme-character run without `://`
  // backtracks quadratically.
  // FIXME(P3, stratalog_dio): a second URL glued to the first with no
  // whitespace (`[https://a/x,https://u:p@b/y]`) parses as one URI, so its
  // userinfo and query pass unredacted.
  static final _url = RegExp(r'[a-zA-Z][a-zA-Z\d+.-]{0,31}://\S+');

  // Bounds the walk down DioException.error chains.
  static const _maxErrorDepth = 4;

  // Namespaced so it can't collide with other interceptors' extra entries.
  static const _kStartTime = 'stratalog.start_time';

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    options.extra[_kStartTime] = DateTime.now();

    final logData = <String, Object?>{'headers': _safeHeaders(options.headers)};
    if (options.queryParameters.isNotEmpty) {
      logData['query'] = _redactKeys.isEmpty
          ? options.queryParameters
          : _redactBody(
              options.queryParameters,
              .identity(),
              encodeObjects: false,
            );
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

    // No status ⇒ the dio type names the cause instead: `✗ connectionError`,
    // `✗ receiveTimeout` — or `✗ unknown` for an exception another
    // interceptor threw over a response dio already dropped (with
    // [logBodies] on, its raw body is on the `←` trace line above).
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

  // A copy whose texts pass whitespace-delimited URLs through _redactUri.
  // Pinned to the default builder, nested DioExceptions included: the global
  // DioException.readableStringBuilder may print requestOptions verbatim.
  // A FormatException's message and source may quote a response body or a
  // header value, so only its offset is kept. Any other inner error not
  // known to echo no input logs as its type.
  DioException _redactError(DioException err, [int depth = 0]) {
    final (raw, safe) = switch (_uriOf(err.requestOptions)) {
      final uri? => ('$uri', '${_redactUri(uri)}'),
      null => ('', ''),
    };
    String redact(String text) =>
        (raw == safe ? text : text.replaceAll(raw, safe)).replaceAllMapped(
          _url,
          (match) => _redactUrl(match[0] ?? ''),
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
        _redactText(error, redact) ?? error,
      final Object error => '<${error.runtimeType}>',
    };
    return err.copyWith(
      message: message == null ? null : redact(message),
      error: inner,
    )..stringBuilder = defaultDioExceptionReadableStringBuilder;
  }

  // Their text holds an address, an OS or TLS code, or a duration. Any other
  // error may quote what was sent: dart:io HttpException prints a request
  // body chunk, a browser's setRequestHeader error the header value. dart:io
  // types are matched by name to keep this library off dart:io.
  static bool _echoesNoInput(Object error) =>
      error is TimeoutException ||
      const {
        'SocketException',
        'TlsException',
        'HandshakeException',
        'CertificateException',
      }.contains('${error.runtimeType}');

  // Null when the text needed no redaction.
  static String? _redactText(Object error, String Function(String) redact) {
    try {
      final text = '$error';
      final redacted = redact(text);
      return redacted == text ? null : redacted;
    } on Object catch (_) {
      return '<${error.runtimeType}>';
    }
  }

  static Uri? _uriOf(RequestOptions request) {
    try {
      return request.uri;
    } on Object catch (_) {
      return null;
    }
  }

  String _loggedUri(RequestOptions request) => switch (_uriOf(request)) {
    final uri? => '${_redactUri(uri)}',
    null => _mask,
  };

  // A URL with nothing to redact stays byte-identical; one that cannot be
  // parsed is masked whole.
  String _redactUrl(String url) {
    try {
      if (Uri.tryParse(url) case final uri?) {
        final safe = _redactUri(uri);
        return identical(safe, uri) ? url : '$safe';
      }
    } on Object catch (_) {
      return _mask;
    }
    return _mask;
  }

  Map<String, Object?> _safeHeaders(Map<String, dynamic> headers) {
    final safe = <String, Object?>{};
    headers.forEach((key, value) {
      final k = key.toLowerCase();
      if (_sensitiveHeaders.contains(k)) {
        safe[k] = maskSensitiveValues ? '***' : value;
      } else if (_headerAllowlist.contains(k)) {
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
  // shape. FormData and TypedData never carry a readable JSON body, so they
  // stay summaries regardless of _redactKeys.
  Object? _formatData(Object? data, RequestOptions request) {
    final path = _uriOf(request)?.path;
    if (path == null || redactBodyPaths.any(path.contains)) return _maskedBody;
    if (data is FormData) {
      return 'FormData(${data.fields.length} fields, '
          '${data.files.length} files)';
    }
    if (data case final TypedData bytes) {
      return '<${bytes.lengthInBytes}-byte body>';
    }
    if (_redactKeys.isEmpty) return data;
    return _redactBody(data, .identity());
  }

  // Rebuilds string-keyed so a `Map<String, Object?>` stays one for readers,
  // and so the record holds a snapshot the caller can no longer mutate.
  //
  // TypedData (Uint8List, ByteData, …) is guarded before the Iterable case: it
  // implements List<int>, so without this an N-byte binary body would be
  // boxed element-by-element into an N-entry growable list synchronously on
  // the request/response hook. Cycle-safe via path-based `seen` tracking.
  //
  // With a bracketed redactKeys entry, a key is matched with its ancestors
  // as dio flattens them, `a[b][c]`.
  //
  // Leaves dio's form encoder sends via toString() log as that text. Other
  // objects go through jsonEncode like dio's transformer, so a nested DTO's
  // toString() never reaches the record. Query leaves are exempt: dio sends
  // them via toString(), already on the message line.
  // FIXME(P2, stratalog_dio): recursion is unbounded — a body nested about
  // 100,000 levels overflows the stack here and the caller gets a
  // DioException in place of the response.
  Object? _redactBody(
    Object? data,
    Set<Object?> seen, {
    String parent = '',
    bool encodeObjects = true,
  }) {
    switch (data) {
      case final TypedData bytes:
        return '<${bytes.lengthInBytes}-byte body>';
      case final Map<Object?, Object?> map:
        if (!seen.add(map)) return '<cycle>';
        final out = <String, Object?>{
          for (final MapEntry(:key, :value) in map.entries)
            '$key': switch (_matchesKeyPaths && parent.isNotEmpty
                ? '$parent[$key]'
                : '$key') {
              final name when _isRedactedKey(name) => _mask,
              final name => _redactBody(
                value,
                seen,
                parent: name,
                encodeObjects: encodeObjects,
              ),
            },
        };
        seen.remove(map);
        return out;
      case final Iterable<Object?> iterable:
        if (!seen.add(iterable)) return '<cycle>';
        final out = [
          for (final element in iterable)
            _redactBody(
              element,
              seen,
              parent: parent,
              encodeObjects: encodeObjects,
            ),
        ];
        seen.remove(iterable);
        return out;
      case null || bool() || num() || String():
        return data;
      case DateTime() || Enum() || BigInt() || Duration():
        return '$data';
      // FIXME(P3, stratalog_dio): a Uri query value is redacted here but
      // printed whole on the message line, which masks by key only.
      case final Uri uri:
        return _redactUrl('$uri');
      case ListParam<Object?>(:final value) when encodeObjects:
        return _redactBody(value, seen, parent: parent);
      case final Object object when encodeObjects:
        final Object? json;
        try {
          json = jsonDecode(jsonEncode(object));
        } on Object catch (_) {
          return '<${object.runtimeType}>';
        }
        return _redactBody(json, seen, parent: parent);
      default:
        return data;
    }
  }

  // Only rebuilds when userinfo is present or a query key actually matches —
  // `Uri.replace` re-encodes and may reorder, so the common no-secret URI stays
  // byte-identical to what went over the wire. The rebuilt query is encoded
  // by hand: `replace(queryParameters:)` would percent-encode the mask into
  // `%2A%2A%2A`. A query that cannot be decoded is masked whole.
  Uri _redactUri(Uri uri) {
    final safe = uri.userInfo.isEmpty ? uri : uri.replace(userInfo: _mask);
    if (!safe.hasQuery || _redactKeys.isEmpty) return safe;
    final Map<String, List<String>> query;
    try {
      query = safe.queryParametersAll;
    } on Object catch (_) {
      return safe.replace(query: _mask);
    }
    if (!query.keys.any(_isRedactedKey)) return safe;
    final parts = <String>[];
    query.forEach((key, values) {
      final encodedKey = Uri.encodeQueryComponent(key);
      if (_isRedactedKey(key)) {
        parts.add('$encodedKey=$_mask');
      } else {
        parts.addAll(
          values.map(
            (value) => '$encodedKey=${Uri.encodeQueryComponent(value)}',
          ),
        );
      }
    });
    return safe.replace(query: parts.join('&'));
  }

  bool _isRedactedKey(String key) =>
      _redactKeys.contains(_normalizeKey(key)) ||
      key
          .split(_keyBrackets)
          .any((segment) => _redactKeys.contains(_normalizeKey(segment)));

  static String _normalizeKey(String key) =>
      key.toLowerCase().replaceAll(_keySeparators, '');
}
