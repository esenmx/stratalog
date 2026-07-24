import 'dart:convert';

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
    bool.fromEnvironment('protobuf.omit_field_names') ||
    bool.fromEnvironment('protobuf.omit_enum_names') ||
    bool.fromEnvironment('protobuf.omit_message_names');

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
/// defaults to verbatim in debug/profile (shows bearer tokens for local
/// debugging) and '***' in product builds — tokens must never land in a
/// release sink.
Interceptor loggerConnectInterceptor({
  LogLayer logger = .network,
  Set<String> sensitiveHeaders = defaultSensitiveHeaders,
  bool maskSensitiveValues = _kProduct,
  bool logBodies = !_kProduct,
  String errorCodeTrailer = 'error-code',
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
      if (logBodies && request is UnaryRequest<I, O>) {
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
        if (logBodies && response is UnaryResponse<I, O>) {
          resData['response_body'] = _formatMessage(response.message);
        }
        logger.trace('← OK $procedure', data: resData);
        return response;
      } on ConnectException catch (error, stackTrace) {
        final data = <String, Object?>{
          'duration_ms': watch.elapsedMilliseconds,
        };
        if (error.metadata[errorCodeTrailer] case final code?) {
          data['error_code'] = code;
        }
        logger.warning(
          '✗ ${error.code.name} $procedure',
          data: data,
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
  if (message is GeneratedMessage) return protoLogShape(message);
  // Non-protobuf codecs (e.g. JsonCodec payloads) carry no schema to map —
  // their toString is the only shape available.
  return message.toString();
}

/// Loggable shape of [message]: proto3 JSON normally; on a build compiled
/// with any `protobuf.omit_*_names` define (name metadata tree-shaken) the
/// classic tag-keyed JSON map from [GeneratedMessage.writeToJson] — numeric
/// keys, enums as numbers. Tag numbers are contract-stable, so a dump plus
/// the `.proto` at the release tag decodes fully. Never log
/// [GeneratedMessage.toString] instead: under stripping it degrades to
/// unstructured numeric prose.
Object? protoLogShape(
  GeneratedMessage message, {
  bool namesStripped = _namesStripped,
}) =>
    namesStripped ? jsonDecode(message.writeToJson()) : message.toProto3Json();
