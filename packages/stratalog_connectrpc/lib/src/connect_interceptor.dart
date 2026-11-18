import 'package:connectrpc/connect.dart';
import 'package:protobuf/protobuf.dart';
import 'package:stratalog/redact.dart';
import 'package:stratalog/stratalog.dart';

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
/// untouched. connectrpc 2.0.1 delivers a caller's subscription cancel to
/// the tap only at the next server event: a cancel followed by another
/// message, or by nothing, logs no terminal line, but a server close or error
/// after it still logs `⇄ done` or the failure line. Abort through
/// `CallOptions.signal`, not the subscription, to tear the HTTP stream down
/// promptly.
///
/// With [logBodies] at its default (`false`), records emit only the literal
/// procedure path (a stub string that survives protobuf name stripping), the
/// Connect code name (a plain Dart enum, unaffected by stripping), the
/// [errorCodeTrailer] value, duration, and allowlisted headers — never
/// message bodies. The failure line's error is always sanitised regardless of
/// [logBodies] so raw metadata, error details, decode body excerpts, and
/// rejected header values never bypass [redactKeys] or [headerAllowlist]: a
/// [ConnectException] keeps its type and code, drops metadata, details and
/// cause, and reduces any non-String cause (decode, I/O or transport error) to
/// that cause's type; a [FormatException] or [ArgumentError] becomes its type
/// alone; any other error becomes its type and scrubbed first line (URL
/// userinfo masked and URL queries removed, clipped at 256 characters). The
/// caller still receives the original error. Trace records still reach any
/// writer whose min level admits them; gate release sinks via
/// `configureLogging(minLevel:)` when trace volume is unwanted.
///
/// [logBodies] defaults to `false`: bodies are stripped out of the box so
/// large payloads never flood the console or reach release sinks (crash
/// breadcrumbs stay at method/status/code shape). Opting in (`true`) logs
/// the unary request and response bodies, masked per [redactKeys] and
/// [redactBodyPaths]; on a build compiled with the `protobuf.omit_*_names`
/// defines it emits the tag-keyed [protoLogShape] map instead of proto3 JSON.
/// Stream messages are never logged. A body that cannot be rendered — a
/// `google.protobuf.Any` holding any type (the tap passes no `TypeRegistry`),
/// or a message whose `toString()` throws — logs
/// `'<unloggable body: ArgumentError>'`, its error type, and never fails the
/// call.
///
/// [redactKeys] (default [defaultRedactKeys]) names the body keys whose
/// values are replaced with `'***'`, whatever their type, at any depth of the
/// logged shape: nested messages, elements of repeated fields, keys of map
/// fields and `google.protobuf.Struct` content. Matched case-insensitively,
/// ignoring `_` and `-`, so one entry covers `newPassword`, `new_password`
/// and `NEW-PASSWORD`. Masking is on by default once [logBodies] is on, and
/// independent of [maskSensitiveValues], which only governs headers. Pass an
/// empty set to log bodies verbatim. It cannot match anything on a build
/// compiled with the `protobuf.omit_*_names` defines, whose shape is keyed
/// by tag numbers, and a non-protobuf message is logged via `toString()`
/// unparsed: cover both with [redactBodyPaths].
///
/// [redactBodyPaths] (default empty) drops bodies for whole procedures: an
/// entry matched as a substring of the procedure path, so
/// `/auth.v1.AuthService/` covers every method of that service, replaces
/// every body logged for the call with `'*** redacted body ***'`. Reach for it
/// where the procedure is sensitive rather than a known field name: it keeps
/// covering the next field somebody adds to that message, which [redactKeys]
/// cannot.
///
/// [headerAllowlist] restricts which non-sensitive headers are logged
/// verbatim; [sensitiveHeaders] values are redacted per
/// [maskSensitiveValues], which defaults to `true` (masks tokens and cookies
/// as `'***'` out of the box). Both sets are matched case-insensitively.
Interceptor loggerConnectInterceptor({
  LogLayer logger = .network,
  Set<String> headerAllowlist = defaultHeaderAllowlist,
  Set<String> sensitiveHeaders = defaultSensitiveHeaders,
  bool maskSensitiveValues = true,
  bool logBodies = false,
  Set<String> redactKeys = defaultRedactKeys,
  Set<String> redactBodyPaths = const {},
  String errorCodeTrailer = 'error-code',
}) {
  final normalizedAllowlist = {
    for (final key in headerAllowlist) key.toLowerCase(),
  };
  final normalizedSensitive = {
    for (final key in sensitiveHeaders) key.toLowerCase(),
  };
  final normalizedRedactKeys = {
    for (final key in redactKeys) normalizeRedactKey(key),
  };
  return <I extends Object, O extends Object>(AnyFn<I, O> next) {
    return (Request<I, O> request) async {
      final watch = Stopwatch()..start();
      final procedure = request.spec.procedure;
      final arrow = request.spec.streamType == .unary ? '→' : '⇄';
      final bodyRedacted = redactBodyPaths.any(procedure.contains);
      Object? body(Object message) => bodyRedacted
          ? redactedBodyPlaceholder
          : _formatMessage(message, normalizedRedactKeys);
      final logBody = logBodies ? body : null;
      logger.trace(
        '$arrow $procedure',
        data: _requestData(
          request,
          headerAllowlist: normalizedAllowlist,
          sensitiveHeaders: normalizedSensitive,
          maskSensitiveValues: maskSensitiveValues,
          logBody: logBody,
        ),
      );

      try {
        final response = await next(request);
        switch (response) {
          case UnaryResponse<I, O>():
            logger.trace(
              '← OK $procedure',
              data: _responseData(response, watch, logBody: logBody),
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
  required Set<String> headerAllowlist,
  required Set<String> sensitiveHeaders,
  required bool maskSensitiveValues,
  required Object? Function(Object message)? logBody,
}) => {
  'headers': redactHeaderEntries(
    request.headers.entries.map((e) => (e.name, e.value)),
    allowlist: headerAllowlist,
    sensitive: sensitiveHeaders,
    maskSensitiveValues: maskSensitiveValues,
  ),
  if (request case UnaryRequest<I, O>(:final message) when logBody != null)
    'request_body': logBody(message),
};

Map<String, Object?> _responseData<I extends Object, O extends Object>(
  UnaryResponse<I, O> response,
  Stopwatch watch, {
  required Object? Function(Object message)? logBody,
}) => {
  'duration_ms': watch.elapsedMilliseconds,
  if (logBody case final log?) 'response_body': log(response.message),
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
    error: _withheld(error),
    stackTrace: stackTrace,
  );
}

// ConnectException.from copies a foreign error's toString() — a decode path
// can carry map keys or body excerpts — into message, and keeps it as cause.
Object _withheld(Object error) => switch (error) {
  ConnectException(:final code, :final Object cause) when cause is! String =>
    ConnectException(code, '${cause.runtimeType}'),
  ConnectException(:final code, :final message) => ConnectException(
    code,
    scrubErrorLine(message, stripAllUrlQueries: true),
  ),
  // dart:io and http2 echo a rejected header value, masked or not.
  FormatException() || ArgumentError() => '${error.runtimeType}',
  _ => describeErrorFirstLine(error, stripAllUrlQueries: true),
};

// A best-effort mapping to structure so ElidingFormatter can clip the leaves.
// Must never throw: the request body is logged before `next` runs, so a
// throw would cancel the call. The caught error's text can echo the body.
Object? _formatMessage(Object message, Set<String> normalizedRedactKeys) {
  try {
    return switch (message) {
      final GeneratedMessage msg when normalizedRedactKeys.isEmpty =>
        protoLogShape(msg),
      final GeneratedMessage msg => redactData(
        protoLogShape(msg),
        normalizedRedactKeys,
      ),
      final other => other.toString(),
    };
  } on Object catch (error) {
    return '<unloggable body: ${error.runtimeType}>';
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
