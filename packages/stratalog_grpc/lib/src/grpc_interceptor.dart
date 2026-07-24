import 'dart:async';
import 'dart:convert';

import 'package:grpc/grpc.dart';
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

/// Observability-only gRPC [ClientInterceptor] — pass it in your channel's
/// client constructor:
///
/// ```dart
/// FooServiceClient(
///   channel,
///   interceptors: [LoggerGrpcInterceptor()],
/// );
/// ```
///
/// Calls trace at `trace`; failures log at `warning`, never `error`: a
/// non-OK status is expected control flow that the repository boundary maps
/// to a typed failure, not a crash.
///
/// Release discipline: with [logBodies] at its default, product builds emit
/// only the literal method path (a stub string that survives protobuf name
/// stripping), the status code name, the [errorCodeTrailer] value, duration,
/// and metadata — never message bodies. Trace records still reach any writer
/// whose min level admits them; gate release sinks via
/// `configureLogging(minLevel:)` when trace volume is unwanted.
final class LoggerGrpcInterceptor extends ClientInterceptor {
  /// Logs calls to [logger], typically `LogLayer.network`.
  LoggerGrpcInterceptor({
    this.logger = .network,
    this.sensitiveMetadata = defaultSensitiveMetadata,
    this.maskSensitiveValues = _kProduct,
    this.logBodies = !_kProduct,
    this.errorCodeTrailer = 'error-code',
  });

  /// Destination layer.
  final LogLayer logger;

  /// Whether to redact [sensitiveMetadata] values. Defaults to verbatim in
  /// debug/profile (shows bearer tokens for local debugging) and '***' in
  /// product builds — tokens must never land in a release sink.
  final bool maskSensitiveValues;

  /// Metadata keys affected by [maskSensitiveValues]; when masked they are
  /// logged presence-only as '***'.
  final Set<String> sensitiveMetadata;

  /// Whether request/response bodies land in trace records. Defaults to on
  /// in debug/profile and OFF in product builds: bodies push user payloads
  /// into release sinks (crash breadcrumbs stay at method/status/code
  /// shape). Opting in on a build compiled with the `protobuf.omit_*_names`
  /// defines emits the tag-keyed [protoLogShape] map instead of proto3 JSON.
  final bool logBodies;

  /// Trailer key whose value is logged as `error_code` on failures — an
  /// app-level error code that survives protobuf name stripping.
  final String errorCodeTrailer;

  /// Default for [sensitiveMetadata].
  static const Set<String> defaultSensitiveMetadata = {
    'authorization',
    'cookie',
    'x-api-key',
  };

  @override
  ResponseFuture<R> interceptUnary<Q, R>(
    ClientMethod<Q, R> method,
    Q request,
    CallOptions options,
    ClientUnaryInvoker<Q, R> invoker,
  ) {
    final watch = Stopwatch()..start();
    final logData = <String, Object?>{
      'metadata': _safeMetadata(options.metadata),
    };
    if (logBodies && request != null) {
      logData['request_body'] = _formatMessage(request);
    }
    logger.trace('→ ${method.path}', data: logData);

    final call = invoker(method, request, options);
    // Side listener only — the caller's own await still receives the result
    // or error untouched.
    unawaited(
      call.then(
        (response) {
          final resData = <String, Object?>{
            'duration_ms': watch.elapsedMilliseconds,
          };
          if (logBodies && response != null) {
            resData['response_body'] = _formatMessage(response);
          }
          logger.trace('← OK ${method.path}', data: resData);
        },
        onError: (Object error, StackTrace stackTrace) {
          _logFailure(method.path, error, stackTrace, watch);
        },
      ),
    );
    return call;
  }

  @override
  ResponseStream<R> interceptStreaming<Q, R>(
    ClientMethod<Q, R> method,
    Stream<Q> requests,
    CallOptions options,
    ClientStreamingInvoker<Q, R> invoker,
  ) {
    final watch = Stopwatch()..start();
    logger.trace(
      '⇄ ${method.path}',
      data: {'metadata': _safeMetadata(options.metadata)},
    );

    final call = invoker(method, requests, options);
    // The response stream is single-subscription and belongs to the caller;
    // completion/errors are observed through the trailers future instead.
    unawaited(
      call.trailers.then(
        (_) {
          logger.trace(
            '⇄ done ${method.path}',
            data: {'duration_ms': watch.elapsedMilliseconds},
          );
        },
        onError: (Object error, StackTrace stackTrace) {
          _logFailure(method.path, error, stackTrace, watch);
        },
      ),
    );
    return call;
  }

  void _logFailure(
    String path,
    Object error,
    StackTrace stackTrace,
    Stopwatch watch,
  ) {
    var status = '-';
    final data = <String, Object?>{'duration_ms': watch.elapsedMilliseconds};
    // codeName comes from grpc's own StatusCode table, not protobuf-generated
    // metadata — it survives the omit_*_names defines.
    if (error case GrpcError(:final codeName, :final trailers)) {
      status = codeName;
      if (trailers?[errorCodeTrailer] case final code?) {
        data['error_code'] = code;
      }
    }
    logger.warning(
      '✗ $status $path',
      data: data,
      error: error,
      stackTrace: stackTrace,
    );
  }

  Map<String, Object?> _safeMetadata(Map<String, String>? metadata) {
    if (metadata == null || metadata.isEmpty) return const {};
    return {
      for (final MapEntry(:key, :value) in metadata.entries)
        key.toLowerCase(): sensitiveMetadata.contains(key.toLowerCase())
            ? (maskSensitiveValues ? '***' : value)
            : value,
    };
  }

  // A best-effort mapping to structure so ElidingFormatter can clip the
  // leaves.
  Object? _formatMessage(Object? message) {
    if (message == null) return null;
    if (message is GeneratedMessage) return protoLogShape(message);
    // Non-protobuf codecs (raw bytes, custom marshallers) carry no schema to
    // map — their toString is the only shape available.
    return message.toString();
  }
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
