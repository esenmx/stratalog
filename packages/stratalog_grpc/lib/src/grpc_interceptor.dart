import 'dart:async';

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
    .fromEnvironment('protobuf.omit_field_names') ||
    .fromEnvironment('protobuf.omit_enum_names') ||
    .fromEnvironment('protobuf.omit_message_names');

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
final class LoggerGrpcInterceptor({
  /// Destination layer.
  final LogLayer logger = .network,

  /// Metadata keys affected by [maskSensitiveValues]; when masked they are
  /// logged presence-only as '***'.
  final Set<String> sensitiveMetadata = defaultSensitiveMetadata,

  /// Whether to redact [sensitiveMetadata] values. Defaults to `true` — a
  /// bearer token or cookie must never land verbatim in a sink, even the
  /// debug console. Pass `false` to show them for local debugging.
  final bool maskSensitiveValues = true,

  /// Whether request/response bodies land in trace records. Defaults to on
  /// in debug/profile and OFF in product builds: bodies push user payloads
  /// into release sinks (crash breadcrumbs stay at method/status/code
  /// shape). Opting in on a build compiled with the `protobuf.omit_*_names`
  /// defines emits the tag-keyed [protoLogShape] map instead of proto3 JSON.
  final bool logBodies = !_kProduct,

  /// Trailer key whose value is logged as `error_code` on failures — an
  /// app-level error code that survives protobuf name stripping.
  final String errorCodeTrailer = 'error-code',
}) extends ClientInterceptor {
  /// Logs calls to [logger], typically `LogLayer.network`.
  this;

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
    call
        .then(
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
        )
        .ignore();
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

    // grpc's `call.trailers` never errors: it completes with the raw metadata
    // BEFORE the library derives an error status from it, and with `{}` on
    // cancel/transport teardown — so neither trailers nor their 'grpc-status'
    // can observe failure. Terminal outcomes surface only as events on the
    // single-subscription response stream, which belongs to the caller; the
    // proxy rides the caller's own subscription. First terminal event wins:
    // grpc emits done after an error, and cancel surfaces a CANCELLED error,
    // so later events stay silent here while still reaching the caller.
    var terminal = false;
    void done() {
      if (terminal) return;
      terminal = true;
      logger.trace(
        '⇄ done ${method.path}',
        data: {'duration_ms': watch.elapsedMilliseconds},
      );
    }

    void failure(Object error, StackTrace stackTrace) {
      if (terminal) return;
      terminal = true;
      _logFailure(method.path, error, stackTrace, watch);
    }

    void cancelled() {
      if (terminal) return;
      terminal = true;
      logger.trace(
        '⇄ cancelled ${method.path}',
        data: {'duration_ms': watch.elapsedMilliseconds},
      );
    }

    return _TerminalObservingStream(
      invoker(method, requests, options),
      onDone: done,
      onFailure: failure,
      onCancel: cancelled,
    );
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
/// classic tag-keyed JSON map from [GeneratedMessage.writeToJsonMap] — numeric
/// keys, enums as numbers. Tag numbers are contract-stable, so a dump plus
/// the `.proto` at the release tag decodes fully. Never log
/// [GeneratedMessage.toString] instead: under stripping it degrades to
/// unstructured numeric prose.
Object? protoLogShape(
  GeneratedMessage message, {
  bool namesStripped = _namesStripped,
}) => namesStripped ? message.writeToJsonMap() : message.toProto3Json();

// Pass-through [ResponseStream] proxy that reports each call's terminal event
// from the caller's own subscription — the stream is single-subscription, so
// a side listener is impossible. `fromHandlers` keeps pause/resume/cancel and
// event delivery semantics of the inner stream; [single] (the seam generated
// client-streaming stubs consume) bypasses the transformer, so it side-listens
// on the future instead.
final class _TerminalObservingStream<R>(
  final ResponseStream<R> _inner, {
  required final void Function() _onDone,
  required final void Function(Object error, StackTrace stackTrace) _onFailure,
  required final void Function() _onCancel,
}) extends StreamView<R> implements ResponseStream<R> {
  this
    : super(
        _inner.transform(
          StreamTransformer<R, R>.fromHandlers(
            handleError: (error, stackTrace, sink) {
              _onFailure(error, stackTrace);
              sink.addError(error, stackTrace);
            },
            handleDone: (sink) {
              _onDone();
              sink.close();
            },
          ),
        ),
      );

  @override
  StreamSubscription<R> listen(
    void Function(R value)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => _CancelObservingSubscription(
    super.listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    ),
    _onCancel,
  );

  @override
  ResponseFuture<R> get single {
    final response = _inner.single;
    response.then<void>((_) => _onDone(), onError: _onFailure).ignore();
    return response;
  }

  @override
  Future<Map<String, String>> get headers => _inner.headers;

  @override
  Future<Map<String, String>> get trailers => _inner.trailers;

  @override
  Future<void> cancel() {
    _onCancel();
    return _inner.cancel();
  }
}

final class _CancelObservingSubscription<R>(
  final StreamSubscription<R> _inner,
  final void Function() _onCancel,
) implements StreamSubscription<R> {
  @override
  Future<void> cancel() {
    _onCancel();
    return _inner.cancel();
  }

  @override
  void onData(void Function(R data)? handleData) => _inner.onData(handleData);

  @override
  void onError(Function? handleError) => _inner.onError(handleError);

  @override
  void onDone(void Function()? handleDone) => _inner.onDone(handleDone);

  @override
  void pause([Future<void>? resumeSignal]) => _inner.pause(resumeSignal);

  @override
  void resume() => _inner.resume();

  @override
  bool get isPaused => _inner.isPaused;

  @override
  Future<E> asFuture<E>([E? futureValue]) => _inner.asFuture<E>(futureValue);
}
