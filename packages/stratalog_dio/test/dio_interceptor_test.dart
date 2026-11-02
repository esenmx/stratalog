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

final class _StubAdapter(final int statusCode, final String body)
    implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => .fromString(
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

  test('sensitive headers masked by default, unlisted dropped, allowlisted '
      'kept', () {
    LoggerDioInterceptor().onRequest(request(), RequestInterceptorHandler());

    final headers =
        writer.records.single.data['headers']! as Map<String, Object?>;
    check(headers['authorization']).equals('***');
    check(headers['cookie']).equals('***');
    check(headers['content-type']).equals('application/json');
    check(headers).not((it) => it.containsKey('x-internal-envelope'));
    check('${writer.records.single.data}')
        .not((it) => it.contains('secret-token'));
  });

  test('custom sensitiveHeaders and headerAllowlist match regardless of '
      'caller casing', () {
    LoggerDioInterceptor(
      sensitiveHeaders: {'X-Firebase-AppCheck'},
      headerAllowlist: {'X-Trace-Id'},
    ).onRequest(
      RequestOptions(
        path: 'https://api.example.com/users',
        headers: {
          'x-firebase-appcheck': 'secret-appcheck',
          'x-trace-id': 'tr-99',
        },
      ),
      RequestInterceptorHandler(),
    );

    final headers =
        writer.records.single.data['headers']! as Map<String, Object?>;
    check(headers['x-firebase-appcheck']).equals('***');
    check(headers['x-trace-id']).equals('tr-99');
  });

  test('sensitive header values pass through verbatim when opted out', () {
    LoggerDioInterceptor(maskSensitiveValues: false)
        .onRequest(request(), RequestInterceptorHandler());

    final headers =
        writer.records.single.data['headers']! as Map<String, Object?>;
    check(headers['authorization']).equals('Bearer secret-token');
    check(headers['cookie']).equals('session=abc');
  });

  test('body is logged as full structured data when logBodies is true, not '
      'truncated here', () {
    // Elision is the sink's job (ElidingFormatter). The interceptor keeps the
    // JSON shape and the full payload so no downstream sink is forced to.
    LoggerDioInterceptor(logBodies: true).onResponse(
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

  // When opted in via logBodies: true, the producer passes bodies verbatim
  // into `record.data`. Elision, when any, is the sink's call
  // (ElidingFormatter); a clip here would silently cap every downstream sink.
  group('full-payload contract (when logBodies: true)', () {
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

      LoggerDioInterceptor(logBodies: true)
          .onRequest(options, RequestInterceptorHandler());

      final body = writer.records.single.data['body']! as Map<String, Object?>;
      check(body).deepEquals(largeBody());
    });

    test('large response body reaches record.data unclipped', () {
      LoggerDioInterceptor(logBodies: true).onResponse(
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

  group('body redaction', () {
    RequestOptions payment() => RequestOptions(
      path: 'https://api.example.com/api/v1/checkout/pay',
      method: 'POST',
      data: {
        'firstName': 'Ada',
        'card': {'number': '4242424242424242', 'cvv': '123', 'expMonth': '04'},
      },
    );

    test('redacted-path bodies never reach the record, in any direction', () {
      final interceptor = LoggerDioInterceptor(
        logBodies: true,
        redactBodyPaths: {'/checkout/pay'},
      );
      final options = payment();

      interceptor
        ..onRequest(options, RequestInterceptorHandler())
        ..onResponse(
          Response<Object?>(
            requestOptions: options,
            statusCode: 200,
            // A server that echoes the submitted card back is exactly the
            // case a request-only rule would miss.
            data: {'card': '4242424242424242'},
          ),
          ResponseInterceptorHandler(),
        );
      runZonedGuarded(
        () => interceptor.onError(
          DioException(
            requestOptions: options,
            response: Response<Object?>(
              requestOptions: options,
              statusCode: 402,
              data: {'card': '4242424242424242'},
            ),
            type: .badResponse,
          ),
          ErrorInterceptorHandler(),
        ),
        (_, _) {},
      );

      check(writer.records).length.equals(3);
      for (final record in writer.records) {
        check(
            because: 'record ${record.message} leaked the payload',
            '${record.data}',
          )
          ..not((it) => it.contains('4242'))
          ..not((it) => it.contains('123'));
      }
    });

    test('path matching is scoped — an unlisted endpoint still logs', () {
      LoggerDioInterceptor(
        logBodies: true,
        redactBodyPaths: {'/checkout/pay'},
      ).onRequest(
        request()
          ..method = 'POST'
          ..data = {'query': 'concerts'},
        RequestInterceptorHandler(),
      );

      final body = writer.records.single.data['body']! as Map<String, Object?>;
      check(body['query']).equals('concerts');
    });

    test('sensitive keys are masked at any depth, siblings kept', () {
      LoggerDioInterceptor(
        logBodies: true,
        redactKeys: {'cvv'},
      ).onRequest(payment(), RequestInterceptorHandler());

      final body = writer.records.single.data['body']! as Map<String, Object?>;
      final card = body['card']! as Map<String, Object?>;
      check(card['cvv']).equals('***');
      check(card['expMonth']).equals('04');
      check(body['firstName']).equals('Ada');
    });

    test('key matching ignores case and word separators', () {
      LoggerDioInterceptor(
        logBodies: true,
        redactKeys: {'new_password'},
      ).onRequest(
        request()
          ..method = 'POST'
          ..data = {
            'newPassword': 'hunter2',
            'NEW-PASSWORD': 'hunter2',
            'passwords': 'not-a-match',
          },
        RequestInterceptorHandler(),
      );

      final body = writer.records.single.data['body']! as Map<String, Object?>;
      check(body['newPassword']).equals('***');
      check(body['NEW-PASSWORD']).equals('***');
      check(body['passwords']).equals('not-a-match');
    });

    test('masking reaches inside lists and non-List Iterables', () {
      LoggerDioInterceptor(logBodies: true, redactKeys: {'cvv'}).onRequest(
        request()
          ..method = 'POST'
          ..data = {
            'cards': {
              {'cvv': '123'},
              {'cvv': '456'},
            },
          },
        RequestInterceptorHandler(),
      );

      check('${writer.records.single.data}').not((it) => it.contains('123'));
    });

    test('cyclic body renders <cycle> instead of overflowing the stack', () {
      final cyclic = <String, Object?>{'password': 'hunter2'};
      cyclic['self'] = cyclic;

      LoggerDioInterceptor(logBodies: true).onRequest(
        request()
          ..method = 'POST'
          ..data = cyclic,
        RequestInterceptorHandler(),
      );

      final body = writer.records.single.data['body']! as Map<String, Object?>;
      check(body['password']).equals('***');
      check(body['self']).equals('<cycle>');
    });

    test('defaults mask a password without any configuration when logBodies '
        'is opted in', () {
      LoggerDioInterceptor(logBodies: true).onRequest(
        request()
          ..method = 'POST'
          ..data = {'password': 'hunter2'},
        RequestInterceptorHandler(),
      );

      final body = writer.records.single.data['body']! as Map<String, Object?>;
      check(body['password']).equals('***');
    });

    test('sensitive query values masked in query data and message line', () {
      LoggerDioInterceptor().onRequest(
        RequestOptions(
          path: 'https://api.example.com/users',
          queryParameters: {'access_token': 'secret-token', 'page': '2'},
        ),
        RequestInterceptorHandler(),
      );

      final record = writer.records.single;
      check('${record.message}')
        ..not((it) => it.contains('secret-token'))
        ..contains('access_token=***')
        ..contains('page=2');
      final query = record.data['query']! as Map<String, Object?>;
      check(query['access_token']).equals('***');
      check(query['page']).equals('2');
    });

    test('a URI with no matching query keys logs byte-identical', () {
      final options = RequestOptions(
        path: 'https://api.example.com/search',
        queryParameters: {'q': 'a b+c', 'page': '2'},
      );

      LoggerDioInterceptor().onRequest(options, RequestInterceptorHandler());

      check('${writer.records.single.message}').endsWith('${options.uri}');
    });

    test('an empty key set passes a JSON map body through by identity', () {
      final data = {'password': 'hunter2'};

      LoggerDioInterceptor(logBodies: true, redactKeys: const {}).onRequest(
        request()
          ..method = 'POST'
          ..data = data,
        RequestInterceptorHandler(),
      );

      check(writer.records.single.data['body']).identicalTo(data);
    });

    test('a TypedData body is summarized even when redactKeys is empty, '
        'never boxed element-by-element', () {
      // Uint8List implements List<int>, so a naive List match would rebuild
      // it as an N-entry growable list of boxed ints. 8 MB is large enough
      // that element-wise boxing would be conspicuously slow.
      final bytes = Uint8List(8 * 1024 * 1024);

      LoggerDioInterceptor(logBodies: true, redactKeys: const {}).onResponse(
        Response<Object?>(
          requestOptions: request(),
          statusCode: 200,
          data: bytes,
        ),
        ResponseInterceptorHandler(),
      );

      check(writer.records.single.data['body'])
        ..isA<String>()
        ..equals('<${bytes.lengthInBytes}-byte body>');
    });
  });

  group('logBodies', () {
    test('defaults to false — bodies are stripped out of the box', () {
      check(LoggerDioInterceptor().logBodies).isFalse();
    });

    test('default strips the request and response body on success', () {
      final interceptor = LoggerDioInterceptor();
      final options = request()
        ..method = 'POST'
        ..data = {'q': 'concerts'};

      interceptor
        ..onRequest(options, RequestInterceptorHandler())
        ..onResponse(
          Response<Object?>(
            requestOptions: options,
            statusCode: 200,
            data: {'result': 'ok'},
          ),
          ResponseInterceptorHandler(),
        );

      for (final record in writer.records) {
        check(record.data).not((it) => it.containsKey('body'));
      }
    });

    test('default strips the response body on failure', () {
      final options = request();

      runZonedGuarded(
        () => LoggerDioInterceptor().onError(
          DioException(
            requestOptions: options,
            response: Response<Object?>(
              requestOptions: options,
              statusCode: 500,
              data: {'message': 'boom'},
            ),
            type: .badResponse,
          ),
          ErrorInterceptorHandler(),
        ),
        (_, _) {},
      );

      check(writer.records.single.data)
          .not((it) => it.containsKey('response_body'));
    });
  });

  test('failures log at warning with status and duration', () {
    final interceptor = LoggerDioInterceptor();
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
    check('${record.message}')
        .equals('✗ 404 GET https://api.example.com/users');
    check(record.data['duration_ms']).isA<int>();
    check(record.data['type']).equals('badResponse');
  });

  test('first position keeps the raw response visible when a later '
      'interceptor throws over it', () async {
    final dio = Dio(BaseOptions(baseUrl: 'https://api.example.com'))
      ..httpClientAdapter = _StubAdapter(200, '{"data":{"id":1}}');
    dio.interceptors
      ..add(LoggerDioInterceptor(logBodies: true))
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
    check('${warning.message}')
        .equals('✗ unknown GET https://api.example.com/users');
    check(warning.data['type']).equals('unknown');
  });

  test('network errors carry the dio type in the message', () async {
    final dio = Dio(BaseOptions(baseUrl: 'https://api.example.com'))
      ..httpClientAdapter = _RefusingAdapter();
    dio.interceptors.add(LoggerDioInterceptor());

    Object? caught;
    try {
      await dio.get<Object?>('/users');
    } on DioException catch (e) {
      caught = e;
    }
    check(caught).isNotNull();

    final warning = writer.records.singleWhere((r) => r.level == .warning);
    check('${warning.message}')
        .equals('✗ connectionError GET https://api.example.com/users');
    check(warning.data['type']).equals('connectionError');
    check(warning.data['duration_ms']).isA<int>();
  });

  test('first position logs the raw server error before a later onError '
      'swallows it', () async {
    final dio = Dio(BaseOptions(baseUrl: 'https://api.example.com'))
      ..httpClientAdapter = _StubAdapter(500, '{"data":{"message":"boom"}}');
    dio.interceptors
      ..add(LoggerDioInterceptor(logBodies: true))
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
    check('${warning.message}')
        .equals('✗ 500 GET https://api.example.com/users');
    check('${warning.data['response_body']}').contains('boom');
    check(warning.data['type']).equals('badResponse');
    check(warning.data['duration_ms']).isA<int>();
  });
}
