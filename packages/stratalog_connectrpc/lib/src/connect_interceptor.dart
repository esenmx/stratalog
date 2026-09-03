import 'package:connectrpc/connect.dart';
import 'package:protobuf/protobuf.dart';
import 'package:stratalog/stratalog.dart';

// Mirrors Flutter's kReleaseMode without a Flutter dependency: dart2js/VM
// AOT release builds define dart.vm.product.
const bool _kProduct = .fromEnvironment('dart.vm.product');

// The app's release dart-defines that tree-shake protobuf name metadata.
// Any of them degrades name-based output: proto3 JSON needs field/enum/
// message names, so body capture must fall back to tag-keyed classic JSON.
const bool _namesStripped =
    .fromEnvironment('protobuf.omit_field_names') ||
    .fromEnvironment('protobuf.omit_enum_names') ||
    .fromEnvironment('protobuf.omit_message_names');

/// Observability-only ConnectRPC [Interceptor] — add it to your transport
/// (works with the Connect, gRPC, and gRPC-Web protocols alike):
///
/// ```dart
/// Transport(
///   baseUrl: 'https://api.example.com',
///   codec: const ProtoCodec(),
///   httpClient: createHttpClient(),
///   interceptors: [loggerConnectInterceptor()],
/// );
/// ```
///
/// Calls trace at `trace`; failures log at `warning`, never `error`: a
/// non-OK code is expected control flow that the repository boundary maps to
/// a typed failure, not a crash.
///
/// Stream calls return a wrapped [StreamResponse] (same headers/trailers)
/// whose terminal line logs when the message stream ends: `⇄ done` on clean
/// completion, the failure line on any error — Connect or not — rethrown
/// untouched. A subscription the caller cancels logs no terminal line.
///
/// Release discipline: with [logBodies] at its default, product builds emit
/// only the literal procedure path (a stub string that survives protobuf
/// name stripping), the Connect code name (a plain Dart enum, unaffected by
/// stripping), the [errorCodeTrailer] value, duration, and headers — never
/// message bodies. Trace records still reach any writer whose min level
/// admits them; gate release sinks via `configureLogging(minLevel:)` when
/// trace volume is unwanted.
///
/// [logBodies] defaults to on in debug/profile and OFF in product builds:
/// bodies push user payloads into release sinks (crash breadcrumbs stay at
/// method/status/code shape). Opting in on a build compiled with the
/// `protobuf.omit_*_names` defines emits the tag-keyed [protoLogShape] map
/// instead of proto3 JSON.
///
/// [sensitiveHeaders] values are redacted per [maskSensitiveValues], which
/// defaults to `true` (masks tokens and cookies as '***' out of the box).
/// Pass `false` to show them for local debugging.
Interceptor loggerConnectInterceptor({
  LogLayer logger = .network,
  Set<String> sensitiveHeaders = defaultSensitiveHeaders,
  bool maskSensitiveValues = true,
  bool logBodies = !_kProduct,
  String errorCodeTrailer = 'error-code',
}) {
  return <I extends Object, O extends Object>(AnyFn<I, O> next) {
    return (Request<I, O> request) async {
      final watch = Stopwatch()..start();
      final procedure = request.spec.procedure;
      final arrow = request.spec.streamType == .unary ? '→' : '⇄';
      logger.trace(
        '$arrow $procedure',
        data: _requestData(
          request,
          sensitiveHeaders: sensitiveHeaders,
          maskSensitiveValues: maskSensitiveValues,
          logBodies: logBodies,
        ),
      );

      try {
        final response = await next(request);
        switch (response) {
          case UnaryResponse<I, O>():
            logger.trace(
              '← OK $procedure',
              data: _responseData(response, watch, logBodies: logBodies),
            );
            return response;
          // Protocol.stream completes this future right after headers —
          // stream failures surface only on `message`, so the terminal line
          // is deferred to a wrapping stream. Trailers pass by reference:
          // the protocol populates that same Headers at end of stream.
          case StreamResponse<I, O>(:final message):
            return StreamResponse(
              response.spec,
              response.headers,
              _terminalTapped(
                message,
                logger,
                procedure,
                watch,
                errorCodeTrailer: errorCodeTrailer,
              ),
              response.trailers,
            );
        }
      } on Object catch (error, stackTrace) {
        _logFailure(
          logger,
          procedure,
          error,
          stackTrace,
          watch,
          errorCodeTrailer: errorCodeTrailer,
        );
        rethrow;
      }
    };
  };
}

Map<String, Object?> _requestData<I extends Object, O extends Object>(
  Request<I, O> request, {
  required Set<String> sensitiveHeaders,
  required bool maskSensitiveValues,
  required bool logBodies,
}) {
  return {
    'headers': _safeHeaders(
      request.headers,
      sensitiveHeaders,
      maskSensitiveValues,
    ),
    if (request case UnaryRequest<I, O>(:final message) when logBodies)
      'request_body': _formatMessage(message),
  };
}

Map<String, Object?> _responseData<I extends Object, O extends Object>(
  UnaryResponse<I, O> response,
  Stopwatch watch, {
  required bool logBodies,
}) => {
  'duration_ms': watch.elapsedMilliseconds,
  if (logBodies) 'response_body': _formatMessage(response.message),
};

Stream<O> _terminalTapped<O>(
  Stream<O> messages,
  LogLayer logger,
  String procedure,
  Stopwatch watch, {
  required String errorCodeTrailer,
}) async* {
  try {
    await for (final message in messages) {
      yield message;
    }
  } on Object catch (error, stackTrace) {
    _logFailure(
      logger,
      procedure,
      error,
      stackTrace,
      watch,
      errorCodeTrailer: errorCodeTrailer,
    );
    rethrow;
  }
  logger.trace(
    '⇄ done $procedure',
    data: {'duration_ms': watch.elapsedMilliseconds},
  );
}

void _logFailure(
  LogLayer logger,
  String procedure,
  Object error,
  StackTrace stackTrace,
  Stopwatch watch, {
  required String errorCodeTrailer,
}) {
  var code = '-';
  final data = <String, Object?>{'duration_ms': watch.elapsedMilliseconds};
  if (error case ConnectException(code: final connectCode, :final metadata)) {
    code = connectCode.name;
    if (metadata[errorCodeTrailer] case final value?) {
      data['error_code'] = value;
    }
  }
  logger.warning(
    '✗ $code $procedure',
    data: data,
    error: error,
    stackTrace: stackTrace,
  );
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
Object? _formatMessage(Object? message) => switch (message) {
  null => null,
  final GeneratedMessage msg => protoLogShape(msg),
  final other => other.toString(),
};

/// Loggable shape of [message]: proto3 JSON normally; on a build compiled
/// with any `protobuf.omit_*_names` define (name metadata tree-shaken) the
/// classic tag-keyed JSON map from [GeneratedMessage.writeToJsonMap] — numeric
/// keys, enums as numbers. Tag numbers are contract-stable, so a dump plus
/// the `.proto` at the release tag decodes fully. Never log
/// [GeneratedMessage.toString] instead: under stripping it degrades to
/// unstructured numeric prose.
Object? protoLogShape(
  GeneratedMessage message, {
  bool namesStripped = _namesStripped,
}) => namesStripped ? message.writeToJsonMap() : message.toProto3Json();
