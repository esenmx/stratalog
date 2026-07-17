import 'dart:async';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:chirp/chirp.dart';
import 'package:dio/dio.dart';
import 'package:stratalog_dio/stratalog_dio.dart';
import 'package:test/test.dart';

final class _CapturingWriter extends ChirpWriter {
  final records = <LogRecord>[];

  @override
  void write(LogRecord record) => records.add(record);
}

final class _StubAdapter implements HttpClientAdapter {
  _StubAdapter(this.statusCode, this.body);

  final int statusCode;
  final String body;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => ResponseBody.fromString(
    body,
    statusCode,
    headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    },
  );

  @override
  void close({bool force = false}) {}
}

final class _RefusingAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) => throw DioException.connectionError(
    requestOptions: options,
    reason: 'connection refused',
  );

  @override
  void close({bool force = false}) {}
}

void main() {
  late _CapturingWriter writer;

  setUp(() {
    writer = _CapturingWriter();
    Chirp.root = ChirpLogger().addWriter(writer);
  });

  tearDown(() => Chirp.root = null);

  RequestOptions request() => RequestOptions(
    path: 'https://api.example.com/users',
    method: 'GET',
    headers: {
      'Authorization': 'Bearer secret-token',
      'Cookie': 'session=abc',
      'Content-Type': 'application/json',
      'X-Internal-Envelope': 'noise',
    },
  );

  test('sensitive headers masked, unlisted dropped, allowlisted kept', () {
    LoggerDioInterceptor(
      .network,
      maskSensitiveValues: true,
    ).onRequest(request(), RequestInterceptorHandler());

    final headers =
        writer.records.single.data['headers']! as Map<String, Object?>;
    check(headers['authorization']).equals('***');
    check(headers['cookie']).equals('***');
    check(headers['content-type']).equals('application/json');
    check(headers).not((it) => it.containsKey('x-internal-envelope'));
    check(
      '${writer.records.single.data}',
    ).not((it) => it.contains('secret-token'));
  });

  test('sensitive header values pass through verbatim by default', () {
    // maskSensitiveValues defaults to false on purpose: local debugging wants
    // the bearer token copyable from the console.
    LoggerDioInterceptor(
      .network,
    ).onRequest(request(), RequestInterceptorHandler());

    final headers =
        writer.records.single.data['headers']! as Map<String, Object?>;
    check(headers['authorization']).equals('Bearer secret-token');
    check(headers['cookie']).equals('session=abc');
  });

  test('body is logged as full structured data, not truncated here', () {
    // Elision is the sink's job (ElidingFormatter). The interceptor keeps the
    // JSON shape and the full payload so no downstream sink is forced to.
    LoggerDioInterceptor(.network).onResponse(
      Response<Object?>(
        requestOptions: request(),
        statusCode: 200,
        data: {'blob': 'x' * 200},
      ),
      ResponseInterceptorHandler(),
    );

    final body = writer.records.single.data['body']! as Map<String, Object?>;
    check(body['blob']).equals('x' * 200);
  });

  // The console guarantee — full copyable JSON payloads — rests on the
  // producer passing bodies verbatim into `record.data`. Elision, when any,
  // is the sink's call (ElidingFormatter); a clip here would silently cap
  // every downstream sink.
  group('full-payload contract', () {
    Map<String, Object?> largeBody() => {
      'blob': 'x' * 5000,
      'items': [for (var i = 0; i < 150; i++) 'item-$i'],
      'nested': {
        'inner': ['y' * 4200],
      },
    };

    // The producer hands the same map through by reference, so comparing
    // against the instance it was given would be vacuous (object vs itself).
    // A fresh largeBody() is the independent oracle: it fails on in-place
    // clipping, clipped copies, and deep-leaf truncation alike.
    test('large request body reaches record.data unclipped', () {
      final options = request()
        ..method = 'POST'
        ..data = largeBody();

      LoggerDioInterceptor(
        .network,
      ).onRequest(options, RequestInterceptorHandler());

      final body = writer.records.single.data['body']! as Map<String, Object?>;
      check(body).deepEquals(largeBody());
    });

    test('large response body reaches record.data unclipped', () {
      LoggerDioInterceptor(.network).onResponse(
        Response<Object?>(
          requestOptions: request(),
          statusCode: 200,
          data: largeBody(),
        ),
        ResponseInterceptorHandler(),
      );

      final body = writer.records.single.data['body']! as Map<String, Object?>;
      check(body).deepEquals(largeBody());
    });
  });

  test('failures log at warning with status and duration', () {
    final interceptor = LoggerDioInterceptor(.network);
    final options = request();
    interceptor.onRequest(options, RequestInterceptorHandler());
    writer.records.clear();

    // next(err) rejects the handler's future; nobody awaits it here, so
    // swallow the unhandled async error in a guarded zone.
    runZonedGuarded(
      () => interceptor.onError(
        DioException(
          requestOptions: options,
          response: Response<Object?>(requestOptions: options, statusCode: 404),
          type: .badResponse,
        ),
        ErrorInterceptorHandler(),
      ),
      (_, _) {},
    );

    final record = writer.records.single;
    check(record.level).equals(.warning);
    check(
      '${record.message}',
    ).equals('✗ 404 GET https://api.example.com/users');
    check(record.data['duration_ms']).isA<int>();
    check(record.data['type']).equals('badResponse');
  });

  test('first position keeps the raw response visible when a later '
      'interceptor throws over it', () async {
    final dio = Dio(BaseOptions(baseUrl: 'https://api.example.com'))
      ..httpClientAdapter = _StubAdapter(200, '{"data":{"id":1}}');
    dio.interceptors
      ..add(LoggerDioInterceptor(.network))
      ..add(
        InterceptorsWrapper(
          onResponse: (response, handler) =>
              throw StateError('unexpected envelope'),
        ),
      );

    Object? caught;
    try {
      await dio.get<Object?>('/users');
    } on DioException catch (e) {
      caught = e;
    }
    check(caught).isNotNull();

    final trace = writer.records.singleWhere(
      (r) => '${r.message}'.startsWith('←'),
    );
    check('${trace.message}').equals('← 200 GET https://api.example.com/users');
    check(trace.data['body']).isA<Map<String, Object?>>();

    // Dio dropped the response from the wrapped exception; the raw body sits
    // on the `←` trace line above, the warning names the pipeline failure.
    final warning = writer.records.singleWhere((r) => r.level == .warning);
    check(
      '${warning.message}',
    ).equals('✗ unknown GET https://api.example.com/users');
    check(warning.data['type']).equals('unknown');
  });

  test('network errors carry the dio type in the message', () async {
    final dio = Dio(BaseOptions(baseUrl: 'https://api.example.com'))
      ..httpClientAdapter = _RefusingAdapter();
    dio.interceptors.add(LoggerDioInterceptor(.network));

    Object? caught;
    try {
      await dio.get<Object?>('/users');
    } on DioException catch (e) {
      caught = e;
    }
    check(caught).isNotNull();

    final warning = writer.records.singleWhere((r) => r.level == .warning);
    check(
      '${warning.message}',
    ).equals('✗ connectionError GET https://api.example.com/users');
    check(warning.data['type']).equals('connectionError');
    check(warning.data['duration_ms']).isA<int>();
  });

  test('first position logs the raw server error before a later onError '
      'swallows it', () async {
    final dio = Dio(BaseOptions(baseUrl: 'https://api.example.com'))
      ..httpClientAdapter = _StubAdapter(500, '{"data":{"message":"boom"}}');
    dio.interceptors
      ..add(LoggerDioInterceptor(.network))
      ..add(
        InterceptorsWrapper(
          onError: (err, handler) => handler.resolve(
            Response<Object?>(
              requestOptions: err.requestOptions,
              statusCode: 200,
              data: 'recovered',
            ),
          ),
        ),
      );

    final response = await dio.get<Object?>('/users');
    check(response.data).equals('recovered');

    final warning = writer.records.singleWhere((r) => r.level == .warning);
    check(
      '${warning.message}',
    ).equals('✗ 500 GET https://api.example.com/users');
    check('${warning.data['response_body']}').contains('boom');
    check(warning.data['type']).equals('badResponse');
    check(warning.data['duration_ms']).isA<int>();
  });
}
