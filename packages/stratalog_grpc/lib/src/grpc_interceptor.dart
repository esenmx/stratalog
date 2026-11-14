import 'dart:async';

import 'package:grpc/grpc.dart';
import 'package:protobuf/protobuf.dart';
import 'package:stratalog/stratalog.dart';

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
/// With [logBodies] at its default (`false`), records emit only the literal
/// method path (a stub string that survives protobuf name stripping), the
/// status code name, the [errorCodeTrailer] value, duration, allowlisted
/// metadata, and on failure a [GrpcError] reduced to its code and status
/// message — never message bodies, other trailers, or error details. Any
/// other error is attached as its type alone when it is a [FormatException]
/// or [ArgumentError] (they echo rejected header values), otherwise as the
/// first line of its text. In either text the call's masked
/// [sensitiveMetadata] values are masked as '***': grpc folds a call-setup
/// failure's text into the status message, which can echo a header value. A
/// value of any other header, or one a metadata provider adds, is not masked
/// there. The caller still receives the original error. Trace records still
/// reach any writer whose min level admits them; gate release sinks via
/// `configureLogging(minLevel:)` when trace volume is unwanted.
///
/// With [logBodies] on, the unary request and response bodies are redacted at
/// this seam rather than left to the sink — on by default: [redactKeys]
/// masks credential-like fields, [redactBodyPaths] drops whole bodies of
/// sensitive methods. Streaming calls never log message content.
final class LoggerGrpcInterceptor({
  /// Destination layer.
  final LogLayer logger = .network,

  /// Only these metadata keys are logged verbatim — a full metadata dump
  /// drowns the log and leaks unlisted credentials attached by interceptors.
  /// Matched case-insensitively.
  final Set<String> metadataAllowlist = defaultMetadataAllowlist,

  /// Metadata keys affected by [maskSensitiveValues]; when masked they are
  /// logged presence-only as '***'. Matched case-insensitively.
  final Set<String> sensitiveMetadata = defaultSensitiveMetadata,

  /// Whether to redact [sensitiveMetadata] values. Defaults to `true` — a
  /// bearer token or cookie must never land verbatim in a sink, even the
  /// debug console. Pass `false` to show them for local debugging.
  final bool maskSensitiveValues = true,

  /// Whether unary request/response bodies land in trace records. Defaults
  /// to `false`: bodies are stripped out of the box so large payloads never
  /// flood the console or reach release sinks (crash breadcrumbs stay at
  /// method/status/code shape). Pass `true` to include redacted bodies — see
  /// [redactKeys] and [redactBodyPaths]. Opting in on a build compiled with
  /// the `protobuf.omit_*_names` defines emits the tag-keyed [protoLogShape]
  /// map instead of proto3 JSON. A body proto3 JSON cannot serialize (a
  /// packed `google.protobuf.Any`, a `google.protobuf.Value` with no kind)
  /// logs as `'<unloggable body: ArgumentError>'`, its error type, and the
  /// call proceeds untouched.
  final bool logBodies = false,

  /// Keys whose values are replaced with '***' wherever they appear in a
  /// logged body: at any depth — nested messages, elements of repeated
  /// fields, keys of map fields, `google.protobuf.Struct` content — whatever
  /// the value's type. Matched case-insensitively, ignoring `_` and `-`, so
  /// one entry covers `newPassword`, `new_password` and `NEW-PASSWORD`.
  ///
  /// On by default once [logBodies] is on, like metadata masking, but
  /// independent of it: `maskSensitiveValues: false` reveals metadata for
  /// local debugging and leaves these keys masked. Pass an empty set to log
  /// bodies verbatim.
  ///
  /// Matches nothing on a build compiled with the `protobuf.omit_*_names`
  /// defines, whose logged shape is keyed by tag numbers, and nothing in a
  /// non-protobuf message, which logs as its unparsed `toString()`: cover
  /// those with [redactBodyPaths].
  final Set<String> redactKeys = defaultRedactKeys,

  /// Method paths whose bodies are dropped from the log entirely — request
  /// and response alike, logged as '*** redacted body ***'. Matched as a
  /// substring of the method path, so `/auth.v1.AuthService/` covers a whole
  /// service.
  ///
  /// Reach for this where the *method* is sensitive rather than a known
  /// field name: it keeps covering the next field somebody adds to that
  /// message, which [redactKeys] cannot, and it still holds on a build
  /// compiled with the `protobuf.omit_*_names` defines.
  final Set<String> redactBodyPaths = const {},

  /// Trailer key whose value is logged as `error_code` on failures — an
  /// app-level error code that survives protobuf name stripping.
  final String errorCodeTrailer = 'error-code',
}) extends ClientInterceptor {
  /// Logs calls to [logger], typically `LogLayer.network`.
  this;

  final Set<String> _metadataAllowlist = {
    for (final key in metadataAllowlist) key.toLowerCase(),
  };

  final Set<String> _sensitiveMetadata = {
    for (final key in sensitiveMetadata) key.toLowerCase(),
  };

  final Set<String> _redactKeys = {
    for (final key in redactKeys) _normalizeKey(key),
  };

  /// Default for [metadataAllowlist].
  static const Set<String> defaultMetadataAllowlist = {
    'content-type',
    'accept',
    'accept-language',
    'content-language',
    'x-request-id',
  };

  /// Default for [sensitiveMetadata].
  static const Set<String> defaultSensitiveMetadata = {
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
      logData['request_body'] = _formatMessage(request, method.path);
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
              resData['response_body'] = _formatMessage(response, method.path);
            }
            logger.trace('← OK ${method.path}', data: resData);
          },
          onError: (Object error, StackTrace stackTrace) {
            if (error case GrpcError(code: StatusCode.cancelled)) {
              logger.trace(
                '→ cancelled ${method.path}',
                data: {'duration_ms': watch.elapsedMilliseconds},
              );
            } else {
              _logFailure(
                method.path,
                error,
                stackTrace,
                watch,
                options.metadata,
              );
            }
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
      _logFailure(method.path, error, stackTrace, watch, options.metadata);
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
    Map<String, String> metadata,
  ) {
    var status = '-';
    final Object logged;
    final data = <String, Object?>{'duration_ms': watch.elapsedMilliseconds};
    // codeName comes from grpc's own StatusCode table, not protobuf-generated
    // metadata — it survives the omit_*_names defines.
    if (error case GrpcError(
      :final code,
      :final codeName,
      :final message,
      :final trailers,
    )) {
      status = codeName;
      if (trailers?[errorCodeTrailer] case final errorCode?) {
        data['error_code'] = errorCode;
      }
      // Sinks render the error via toString(), which dumps every trailer,
      // details and rawResponse past the metadata allowlist. grpc folds a
      // call-setup failure's text into the message ('Error making call: …'),
      // which can echo a header value.
      logged = GrpcError.custom(
        code,
        message == null ? null : _masked(message, metadata),
      );
    } else {
      logged = switch (error) {
        // dart:io and ascii.encode echo a rejected header value, which an
        // interceptor after this one may have added out of sight.
        FormatException() || ArgumentError() => '${error.runtimeType}',
        _ => _described(error, metadata),
      };
    }
    logger.warning(
      '✗ $status $path',
      data: data,
      error: logged,
      stackTrace: stackTrace,
    );
  }

  // Error texts can dump their source on the lines below the first.
  String _described(Object error, Map<String, String> metadata) {
    final type = '${error.runtimeType}';
    try {
      final line = _masked('$error', metadata).split('\n').first;
      return line.startsWith(type) ? line : '$type: $line';
    } on Object catch (_) {
      return type;
    }
  }

  // Sensitive values only: masking every unlisted value would cut short
  // ones ('en', '1') out of ordinary status messages. grpc trims values
  // before encoding, so an echo carries the trimmed form. Longest first:
  // masking a shorter value inside a longer one first would leave the longer
  // one's remainder in clear.
  String _masked(String text, Map<String, String> metadata) {
    if (!maskSensitiveValues) return text;
    final sensitive = [
      for (final MapEntry(:key, :value) in metadata.entries)
        if (_sensitiveMetadata.contains(key.toLowerCase()) &&
            value.trim().isNotEmpty)
          value.trim(),
    ]..sort((a, b) => b.length.compareTo(a.length));
    return sensitive.fold(
      text,
      (masked, value) => masked.replaceAll(value, '***'),
    );
  }

  Map<String, Object?> _safeMetadata(Map<String, String>? metadata) {
    if (metadata == null || metadata.isEmpty) return const {};
    final safe = <String, Object?>{};
    metadata.forEach((key, value) {
      final k = key.toLowerCase();
      if (_sensitiveMetadata.contains(k)) {
        safe[k] = maskSensitiveValues ? '***' : value;
      } else if (_metadataAllowlist.contains(k)) {
        safe[k] = value;
      }
    });
    return safe;
  }

  // A best-effort mapping to structure so ElidingFormatter can clip the
  // leaves.
  Object? _formatMessage(Object message, String path) {
    if (redactBodyPaths.any(path.contains)) return _maskedBody;
    // Non-protobuf codecs (raw bytes, custom marshallers) carry no schema to
    // map — their toString is the only shape available.
    if (message is! GeneratedMessage) return message.toString();
    final Object? shape;
    try {
      shape = protoLogShape(message);
    } on Object catch (error) {
      // proto3 JSON rejects a packed Any (the type registry is empty) and a
      // kindless Value. Never fall back to toString(): it bypasses
      // redactKeys.
      return '<unloggable body: ${error.runtimeType}>';
    }
    return _redactKeys.isEmpty ? shape : _redactBody(shape);
  }

  // protoLogShape yields JSON-shaped data only: maps, lists and leaves, no
  // cycles. Rebuilt string-keyed so readers keep a Map<String, Object?>.
  Object? _redactBody(Object? data) => switch (data) {
    final Map<Object?, Object?> map => <String, Object?>{
      for (final MapEntry(:key, :value) in map.entries)
        '$key': _redactKeys.contains(_normalizeKey('$key'))
            ? _mask
            : _redactBody(value),
    },
    final List<Object?> list => [
      for (final element in list) _redactBody(element),
    ],
    _ => data,
  };

  static String _normalizeKey(String key) =>
      key.toLowerCase().replaceAll(_keySeparators, '');
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
    response
        .then<void>(
          (_) => _onDone(),
          onError: (Object error, StackTrace stackTrace) {
            if (error case GrpcError(code: StatusCode.cancelled)) {
              _onCancel();
            } else {
              _onFailure(error, stackTrace);
            }
          },
        )
        .ignore();
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
