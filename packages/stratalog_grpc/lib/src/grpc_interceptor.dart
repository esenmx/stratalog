import 'dart:async';

import 'package:grpc/grpc.dart';
import 'package:stratalog/stratalog.dart';

/// Observability-only gRPC [ClientInterceptor] — pass it in your channel's
/// client constructor:
///
/// ```dart
/// FooServiceClient(
///   channel,
///   interceptors: [LoggerGrpcInterceptor(LogLayer.network)],
/// );
/// ```
///
/// Calls trace at `trace` (release-gated); failures log at `warning`, never
/// `error`: a non-OK status is expected control flow that the repository
/// boundary maps to a typed failure, not a crash.
final class LoggerGrpcInterceptor extends ClientInterceptor {
  /// Logs calls to [logger], typically `LogLayer.network`.
  LoggerGrpcInterceptor(
    this.logger, {
    this.sensitiveMetadata = defaultSensitiveMetadata,
  });

  /// Destination layer.
  final LogLayer logger;

  /// Metadata keys logged presence-only as '***': tokens must never land in
  /// a sink — even the debug console.
  final Set<String> sensitiveMetadata;

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
    logger.trace(
      '→ ${method.path}',
      data: {'metadata': _safeMetadata(options.metadata)},
    );

    final call = invoker(method, request, options);
    // Side listener only — the caller's own await still receives the result
    // or error untouched.
    unawaited(
      call.then(
        (_) {
          logger.trace(
            '← OK ${method.path}',
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
    final status = error is GrpcError ? error.codeName : '-';
    logger.warning(
      '✗ $status $path',
      data: {'duration_ms': watch.elapsedMilliseconds},
      error: error,
      stackTrace: stackTrace,
    );
  }

  Map<String, Object?> _safeMetadata(Map<String, String>? metadata) {
    if (metadata == null || metadata.isEmpty) return const {};
    return {
      for (final MapEntry(:key, :value) in metadata.entries)
        key.toLowerCase(): sensitiveMetadata.contains(key.toLowerCase())
            ? '***'
            : value,
    };
  }
}
