import 'package:connectrpc/connect.dart';
import 'package:protobuf/protobuf.dart';
import 'package:stratalog/stratalog.dart';

/// Observability-only ConnectRPC [Interceptor] — add it to your transport
/// (works with the Connect, gRPC, and gRPC-Web protocols alike):
///
/// ```dart
/// Transport(
///   baseUrl: 'https://api.example.com',
///   codec: const ProtoCodec(),
///   httpClient: createHttpClient(),
///   interceptors: [loggerConnectInterceptor(LogLayer.network)],
/// );
/// ```
///
/// Calls trace at `trace` (release-gated); failures log at `warning`, never
/// `error`: a non-OK code is expected control flow that the repository
/// boundary maps to a typed failure, not a crash.
///
/// [sensitiveHeaders] are logged presence-only as '***' (defaults to
/// authorization/cookie/x-api-key): tokens must never land in a sink — even
/// the debug console.
Interceptor loggerConnectInterceptor(
  LogLayer logger, {
  Set<String> sensitiveHeaders = defaultSensitiveHeaders,
  bool maskSensitiveValues = false,
}) {
  return <I extends Object, O extends Object>(AnyFn<I, O> next) {
    return (Request<I, O> request) async {
      final watch = Stopwatch()..start();
      final procedure = request.spec.procedure;
      final arrow = request.spec.streamType == StreamType.unary ? '→' : '⇄';

      final logData = <String, Object?>{
        'headers': _safeHeaders(
          request.headers,
          sensitiveHeaders,
          maskSensitiveValues,
        ),
      };
      if (request is UnaryRequest<I, O>) {
        logData['request_body'] = _formatMessage(request.message);
      }
      logger.trace('$arrow $procedure', data: logData);

      try {
        final response = await next(request);
        // For streams this marks headers received, not stream end — the
        // message stream belongs to the caller and is not observed here.
        final resData = <String, Object?>{
          'duration_ms': watch.elapsedMilliseconds,
        };
        if (response is UnaryResponse<I, O>) {
          resData['response_body'] = _formatMessage(response.message);
        }
        logger.trace('← OK $procedure', data: resData);
        return response;
      } on ConnectException catch (error, stackTrace) {
        logger.warning(
          '✗ ${error.code.name} $procedure',
          data: {'duration_ms': watch.elapsedMilliseconds},
          error: error,
          stackTrace: stackTrace,
        );
        rethrow;
      }
    };
  };
}

/// Default for `loggerConnectInterceptor(sensitiveHeaders:)`.
const Set<String> defaultSensitiveHeaders = {
  'authorization',
  'cookie',
  'x-api-key',
};

Map<String, Object?> _safeHeaders(
  Headers headers,
  Set<String> sensitive,
  bool maskSensitiveValues,
) {
  return {
    // Connect lowercases header names already.
    for (final (:name, :value) in headers.entries)
      name: sensitive.contains(name)
          ? (maskSensitiveValues ? '***' : value)
          : value,
  };
}

// A best-effort mapping to structure so ElidingFormatter can clip the leaves.
Object? _formatMessage(Object? message) {
  if (message == null) return null;
  if (message is GeneratedMessage) {
    return message.toProto3Json();
  }
  return message.toString();
}
