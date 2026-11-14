import 'dart:async';
import 'dart:io';
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

final class _HeaderlessCloseAdapter({final Uri? redirectedTo})
    implements HttpClientAdapter {
  DioException? thrown;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) => throw thrown = DioException.connectionError(
    requestOptions: options,
    reason: 'closed',
    error: HttpException(
      'Connection closed before full header was received',
      uri: redirectedTo ?? options.uri,
    ),
  );

  @override
  void close({bool force = false}) {}
}

final class _FailingAdapter(final Object? error) implements HttpClientAdapter {
  DioException? thrown;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) => throw thrown = DioException(requestOptions: options, error: error);

  @override
  void close({bool force = false}) {}
}

enum _Tier { gold }

final class _Throwing {
  @override
  String toString() => throw StateError('access_token=secret-token');
}

final class _Card(final String number, final String cvv) {
  Map<String, Object?> toJson() => {'number': number, 'cvv': cvv};

  @override
  String toString() => '_Card(number: $number, cvv: $cvv)';
}

final class _Unencodable {
  Object? toJson() => throw StateError('not encodable');

  @override
  String toString() => '_Unencodable(cvv: 123)';
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

    test('a DTO nested in a body is masked through its toJson', () {
      LoggerDioInterceptor(logBodies: true).onRequest(
        request()
          ..method = 'POST'
          ..data = {
            'card': _Card('4242424242424242', '123'),
            'cards': [_Card('4000056655665556', '456')],
          },
        RequestInterceptorHandler(),
      );

      final body = writer.records.single.data['body']! as Map<String, Object?>;
      check(body['card']).isA<Map<String, Object?>>()
        ..has((it) => it['cvv'], 'cvv').equals('***')
        ..has((it) => it['number'], 'number').equals('4242424242424242');
      check('${body['cards']}')
        ..not((it) => it.contains('456'))
        ..contains('4000056655665556');
    });

    test('an object toJson cannot encode logs as a type placeholder', () {
      LoggerDioInterceptor(logBodies: true).onRequest(
        request()
          ..method = 'POST'
          ..data = {'item': _Unencodable()},
        RequestInterceptorHandler(),
      );

      final body = writer.records.single.data['body']! as Map<String, Object?>;
      check(body['item']).equals('<_Unencodable>');
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

    test('bracketed query keys are masked on the message line too', () {
      LoggerDioInterceptor().onRequest(
        RequestOptions(
          path: 'https://api.example.com/login',
          queryParameters: {
            'auth': {'password': 'leak-one'},
            'secret': {'id': 'leak-two'},
            'page': '1',
          },
        ),
        RequestInterceptorHandler(),
      );

      final record = writer.records.single;
      check('${record.message} ${record.data}')
        ..not((it) => it.contains('leak-one'))
        ..not((it) => it.contains('leak-two'));
      check('${record.message}').contains('page=1');
    });

    test('a flat bracketed query key is masked in the query data too', () {
      LoggerDioInterceptor().onRequest(
        RequestOptions(
          path: 'https://api.example.com/login',
          queryParameters: {'user[password]': 'flat-secret', 'page': '1'},
        ),
        RequestInterceptorHandler(),
      );

      final record = writer.records.single;
      check('${record.message} ${record.data}')
          .not((it) => it.contains('flat-secret'));
      check(record.data['query']).isA<Map<String, Object?>>()
        ..has((it) => it['user[password]'], 'user[password]').equals('***')
        ..has((it) => it['page'], 'page').equals('1');
    });

    for (final query in [
      <String, Object?>{},
      {'password': 'x'},
    ]) {
      test('URI userinfo is masked on the message line, query $query', () {
        LoggerDioInterceptor().onRequest(
          RequestOptions(
            path: 'https://admin:s3cret@api.example.com/users',
            queryParameters: query,
          ),
          RequestInterceptorHandler(),
        );

        check('${writer.records.single.message}')
          ..not((it) => it.contains('s3cret'))
          ..contains('https://***@api.example.com/users');
      });
    }

    for (final query in [
      <String, Object?>{'filter[ssn]': 'ssn-secret', 'page': '1'},
      {
        'filter': {'ssn': 'ssn-secret'},
        'page': '1',
      },
    ]) {
      test('a bracketed redactKeys entry masks query $query', () {
        LoggerDioInterceptor(redactKeys: {'filter[ssn]'}).onRequest(
          RequestOptions(
            path: 'https://api.example.com/people',
            queryParameters: query,
          ),
          RequestInterceptorHandler(),
        );

        final record = writer.records.single;
        check('${record.message} ${record.data}')
            .not((it) => it.contains('ssn-secret'));
        check('${record.message}').contains('page=1');
      });
    }

    test('form leaves dio sends via toString log as their text', () {
      LoggerDioInterceptor(logBodies: true).onRequest(
        request()
          ..method = 'POST'
          ..contentType = Headers.formUrlEncodedContentType
          ..data = {
            'at': DateTime.utc(2026, 11, 14),
            'tier': _Tier.gold,
            'link': Uri.parse('https://example.com/a?b=c&pin=1234'),
            'big': BigInt.parse('123456789012345678901234567890'),
            'wait': const Duration(seconds: 90),
          },
        RequestInterceptorHandler(),
      );

      check(writer.records.single.data['body'])
          .isA<Map<String, Object?>>()
          .deepEquals({
            'at': '2026-11-14 00:00:00.000Z',
            'tier': '_Tier.gold',
            'link': 'https://example.com/a?b=c&pin=***',
            'big': '123456789012345678901234567890',
            'wait': '0:01:30.000000',
          });
    });

    test('a ListParam in a form body logs the values dio sends', () {
      LoggerDioInterceptor(logBodies: true).onRequest(
        request()
          ..method = 'POST'
          ..contentType = Headers.formUrlEncodedContentType
          ..data = {
            'tags': const ListParam(['a', 'b'], ListFormat.csv),
            'pins': const ListParam(['1234'], ListFormat.multi),
            'people': const ListParam([
              {'name': 'jo', 'password': 'hunter2'},
            ], ListFormat.multi),
          },
        RequestInterceptorHandler(),
      );

      check(writer.records.single.data['body'])
          .isA<Map<String, Object?>>()
          .deepEquals({
            'tags': ['a', 'b'],
            'pins': ['1234'],
            'people': [
              {'name': 'jo', 'password': '***'},
            ],
          });
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

    // Dio dropped the response from the wrapped exception; with logBodies on,
    // the raw body sits on the `←` trace line above, the warning names the
    // pipeline failure.
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

  test('logged error masks the URI, the caller gets the original', () async {
    final adapter = _HeaderlessCloseAdapter();
    final dio = Dio()..httpClientAdapter = adapter;
    dio.interceptors.add(LoggerDioInterceptor());

    Object? caught;
    try {
      await dio.get<Object?>(
        'https://api.example.com/users',
        queryParameters: {'access_token': 'secret-token', 'page': '2'},
      );
    } on DioException catch (e) {
      caught = e;
    }
    check(caught).isNotNull();
    check(identical(caught, adapter.thrown)).isTrue();
    check('$caught').contains('secret-token');

    final warning = writer.records.singleWhere((r) => r.level == .warning);
    check(warning.error).isA<DioException>();
    check(identical(warning.stackTrace, adapter.thrown?.stackTrace)).isTrue();
    check('${warning.message} ${warning.data} ${warning.error}')
        .not((it) => it.contains('secret-token'));
    check('${warning.error}')
      ..contains('connection error')
      ..contains('Error: <HttpException>');
  });

  test('a global readableStringBuilder cannot surface the raw URI', () {
    DioException.readableStringBuilder = (e) => 'raw ${e.requestOptions.uri}';
    addTearDown(
      () => DioException.readableStringBuilder =
          defaultDioExceptionReadableStringBuilder,
    );
    final options = RequestOptions(
      path: 'https://api.example.com/users',
      queryParameters: {'access_token': 'secret-token'},
    );
    final err = DioException(
      requestOptions: options,
      message: 'cannot reach ${options.uri}',
    );

    runZonedGuarded(
      () => LoggerDioInterceptor().onError(err, ErrorInterceptorHandler()),
      (_, _) {},
    );

    final error = writer.records.single.error;
    check(error).isA<DioException>();
    check('$error')
      ..not((it) => it.contains('secret-token'))
      ..contains('cannot reach https://api.example.com/users?access_token=***');
  });

  test('a redirect target in the inner error is withheld', () async {
    final adapter = _HeaderlessCloseAdapter(
      redirectedTo: Uri.parse(
        'https://api.example.com/next?access_token=redirect-secret&page=3',
      ),
    );
    final dio = Dio()..httpClientAdapter = adapter;
    dio.interceptors.add(LoggerDioInterceptor());

    Object? caught;
    try {
      await dio.get<Object?>(
        'https://api.example.com/start',
        queryParameters: {'access_token': 'secret-token'},
      );
    } on DioException catch (e) {
      caught = e;
    }
    check(identical(caught, adapter.thrown)).isTrue();
    check('$caught').contains('redirect-secret');

    final warning = writer.records.singleWhere((r) => r.level == .warning);
    check(warning.error).isA<DioException>();
    check('${warning.message} ${warning.data} ${warning.error}')
      ..not((it) => it.contains('redirect-secret'))
      ..not((it) => it.contains('secret-token'));
    check('${warning.error}').contains('Error: <HttpException>');
  });

  test('a malformed URL in the inner error is masked whole', () {
    final err = DioException(
      requestOptions: RequestOptions(path: 'https://api.example.com/users'),
      error: const SocketException(
        'see http://[::1/x?access_token=secret-token for details',
      ),
    );

    runZonedGuarded(
      () => LoggerDioInterceptor().onError(err, ErrorInterceptorHandler()),
      (_, _) {},
    );

    check('${writer.records.single.error}')
      ..not((it) => it.contains('secret-token'))
      ..contains('see *** for details');
  });

  test('a FormatException body excerpt never reaches the record', () async {
    Object? seen;
    final dio = Dio(BaseOptions(baseUrl: 'https://api.example.com'))
      ..transformer = SyncTransformer()
      ..httpClientAdapter = _StubAdapter(
        200,
        '{"access_token":"body-secret-token","password":"hunter2",oops}',
      );
    dio.interceptors
      ..add(LoggerDioInterceptor())
      ..add(
        InterceptorsWrapper(
          onError: (err, handler) {
            seen = err;
            handler.next(err);
          },
        ),
      );

    Object? caught;
    try {
      await dio.get<Object?>('/users');
    } on DioException catch (e) {
      caught = e;
    }
    check(identical(caught, seen)).isTrue();
    check('$caught').contains('body-secret-token');

    final warning = writer.records.singleWhere((r) => r.level == .warning);
    check(warning.error).isA<DioException>()
      ..has((it) => it.type, 'type').equals(.unknown)
      ..has((it) => it.error, 'error').isA<FormatException>();
    check('${warning.message} ${warning.data} ${warning.error}')
      ..not((it) => it.contains('body-secret-token'))
      ..not((it) => it.contains('hunter2'));
    check('${warning.error}').contains('FormatException: message withheld');
  });

  test('a FormatException message never reaches the record', () {
    final err = DioException(
      requestOptions: RequestOptions(path: 'https://api.example.com/users'),
      error: const FormatException(
        'Unexpected token h, ..."password":hunter2-ra"... is not valid JSON',
      ),
    );

    runZonedGuarded(
      () => LoggerDioInterceptor().onError(err, ErrorInterceptorHandler()),
      (_, _) {},
    );

    final error = writer.records.single.error;
    check(error)
        .isA<DioException>()
        .has((it) => it.error, 'error')
        .isA<FormatException>();
    check('$error')
      ..not((it) => it.contains('hunter2'))
      ..contains('FormatException: message withheld');
  });

  for (final inner in [
    const HttpException(
      'Content size exceeds specified contentLength. 37 bytes written while '
      'expected 36. [{"user":"jo","password":"hunter2"}]',
    ),
    "'Bearer hunter2' is not a valid HTTP header field value.",
  ]) {
    test('an echoing inner ${inner.runtimeType} logs as its type', () {
      final err = DioException(
        requestOptions: RequestOptions(path: 'https://api.example.com/users'),
        error: inner,
      );

      runZonedGuarded(
        () => LoggerDioInterceptor().onError(err, ErrorInterceptorHandler()),
        (_, _) {},
      );

      check('${writer.records.single.error}')
        ..not((it) => it.contains('hunter2'))
        ..endsWith('Error: <${inner.runtimeType}>');
      check(err.error).identicalTo(inner);
    });
  }

  for (final inner in [
    const SocketException('Connection refused', port: 443),
    const HandshakeException('CERTIFICATE_VERIFY_FAILED'),
    TimeoutException('no answer', const Duration(seconds: 5)),
  ]) {
    test('an inner ${inner.runtimeType} keeps its text', () {
      final err = DioException(
        requestOptions: RequestOptions(path: 'https://api.example.com/users'),
        error: inner,
      );

      runZonedGuarded(
        () => LoggerDioInterceptor().onError(err, ErrorInterceptorHandler()),
        (_, _) {},
      );

      check('${writer.records.single.error}').endsWith('Error: $inner');
    });
  }

  test('an inner ArgumentError logs as its type', () {
    final err = DioException(
      requestOptions: RequestOptions(path: 'https://api.example.com/users'),
      error: ArgumentError.value('secret-token', 'token'),
    );

    runZonedGuarded(
      () => LoggerDioInterceptor().onError(err, ErrorInterceptorHandler()),
      (_, _) {},
    );

    check('${writer.records.single.error}')
      ..not((it) => it.contains('secret-token'))
      ..contains('Error: <ArgumentError>');
  });

  test('an invalid masked header value never reaches the record', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) => request.response.close());
    final dio = Dio(BaseOptions(baseUrl: 'http://127.0.0.1:${server.port}'));
    addTearDown(() => dio.close(force: true));
    dio.interceptors.add(LoggerDioInterceptor());

    Object? caught;
    try {
      await dio.get<Object?>(
        '/users',
        options: Options(headers: {'authorization': 'Bearer secret-token\n'}),
      );
    } on DioException catch (e) {
      caught = e;
    }
    check('$caught').contains('secret-token');

    check(writer.records).length.equals(2);
    for (final record in writer.records) {
      check('${record.message} ${record.data} ${record.error}')
          .not((it) => it.contains('secret-token'));
    }
  });

  test('a long scheme-like run in an inner error redacts quickly', () {
    final err = DioException(
      requestOptions: RequestOptions(path: 'https://api.example.com/x'),
      error: SocketException('bad payload: ${'a' * 50000}'),
    );
    final stopwatch = Stopwatch()..start();

    runZonedGuarded(
      () => LoggerDioInterceptor().onError(err, ErrorInterceptorHandler()),
      (_, _) {},
    );

    check(stopwatch.elapsed).isLessThan(const Duration(seconds: 1));
    check(writer.records).length.equals(1);
  });

  test('an undecodable query is sent and logged masked whole', () async {
    final dio = Dio()..httpClientAdapter = _StubAdapter(200, '{}');
    dio.interceptors.add(LoggerDioInterceptor());

    final response = await dio.get<Object?>(
      'https://api.example.com/search?name=Jos%E9',
    );

    check(response.statusCode).equals(200);
    check([for (final record in writer.records) '${record.message}'])
        .deepEquals([
          '→ GET https://api.example.com/search?***',
          '← 200 GET https://api.example.com/search?***',
        ]);
  });

  test('an undecodable query logs verbatim with no redactKeys', () {
    LoggerDioInterceptor(redactKeys: const {}).onRequest(
      RequestOptions(path: 'https://api.example.com/search?name=Jos%E9'),
      RequestInterceptorHandler(),
    );

    check('${writer.records.single.message}')
        .equals('→ GET https://api.example.com/search?name=Jos%E9');
  });

  test('an unparseable request URI logs a placeholder', () {
    LoggerDioInterceptor(logBodies: true).onRequest(
      RequestOptions(path: 'http://[::1/x', data: {'q': 'concerts'}),
      RequestInterceptorHandler(),
    );

    final record = writer.records.single;
    check('${record.message}').equals('→ GET ***');
    check(record.data['body']).equals('*** redacted body ***');
  });

  for (final path in [
    'http://[::1/x?access_token=secret-token',
    'https://api.example.com/search?name=Jos%E9&access_token=secret-token',
  ]) {
    test('a nested exception for $path still logs', () async {
      final adapter = _FailingAdapter(
        DioException(requestOptions: RequestOptions(path: path)),
      );
      final dio = Dio()..httpClientAdapter = adapter;
      dio.interceptors.add(LoggerDioInterceptor());

      Object? caught;
      try {
        await dio.get<Object?>('https://api.example.com/users');
      } on DioException catch (e) {
        caught = e;
      }
      check(identical(caught, adapter.thrown)).isTrue();

      final warning = writer.records.singleWhere((r) => r.level == .warning);
      check(warning.error)
          .isA<DioException>()
          .has((it) => it.error, 'error')
          .isA<DioException>();
      check('${warning.error}').not((it) => it.contains('secret-token'));
    });
  }

  test('a relative request URI in the inner error is masked', () async {
    final adapter = _FailingAdapter(
      const SocketException('cannot GET /users?access_token=secret-token'),
    );
    final dio = Dio()..httpClientAdapter = adapter;
    dio.interceptors.add(LoggerDioInterceptor());

    Object? caught;
    try {
      await dio.get<Object?>('/users?access_token=secret-token');
    } on DioException catch (e) {
      caught = e;
    }
    check(identical(caught, adapter.thrown)).isTrue();

    final warning = writer.records.singleWhere((r) => r.level == .warning);
    check('${warning.error}')
      ..not((it) => it.contains('secret-token'))
      ..contains('cannot GET /users?access_token=***');
  });

  test('a chain deeper than the walk bound ends in a placeholder', () {
    var err = DioException(
      requestOptions: RequestOptions(
        path: 'https://api.example.com/x?access_token=secret-token',
      ),
      message: 'innermost',
    );
    for (var level = 0; level < 6; level++) {
      err = DioException(
        requestOptions: RequestOptions(path: 'https://api.example.com/x'),
        message: 'level $level',
        error: err,
      );
    }

    runZonedGuarded(
      () => LoggerDioInterceptor().onError(err, ErrorInterceptorHandler()),
      (_, _) {},
    );

    check('${writer.records.single.error}')
      ..contains('Error: <DioException>')
      ..not((it) => it.contains('innermost'))
      ..not((it) => it.contains('secret-token'));
  });

  test('a URL in a kept inner error is masked', () {
    final err = DioException(
      requestOptions: RequestOptions(path: 'https://api.example.com/users'),
      error: const SocketException(
        'lookup failed at https://api.example.com/x?access_token=secret-token',
      ),
    );

    runZonedGuarded(
      () => LoggerDioInterceptor().onError(err, ErrorInterceptorHandler()),
      (_, _) {},
    );

    check('${writer.records.single.error}')
      ..not((it) => it.contains('secret-token'))
      ..contains(
        'Error: SocketException: lookup failed at '
        'https://api.example.com/x?access_token=***',
      );
  });

  test('a nested DioException is rendered redacted too', () {
    DioException.readableStringBuilder = (e) =>
        'custom q=${e.requestOptions.queryParameters} '
        'h=${e.requestOptions.headers}';
    addTearDown(
      () => DioException.readableStringBuilder =
          defaultDioExceptionReadableStringBuilder,
    );
    final inner = DioException(
      requestOptions: RequestOptions(
        path: 'https://api.example.com/users',
        queryParameters: {'access_token': 'secret-token'},
        headers: {'Authorization': 'Bearer hdr-secret'},
      ),
      message: 'inner',
    );
    final err = DioException(
      requestOptions: RequestOptions(path: 'https://api.example.com/users'),
      message: 'outer',
      error: inner,
    );

    runZonedGuarded(
      () => LoggerDioInterceptor().onError(err, ErrorInterceptorHandler()),
      (_, _) {},
    );

    final error = writer.records.single.error;
    check(error)
        .isA<DioException>()
        .has((it) => it.error, 'error')
        .isA<DioException>();
    check('$error')
      ..not((it) => it.contains('secret-token'))
      ..not((it) => it.contains('hdr-secret'))
      ..contains('outer')
      ..contains('inner');
  });

  test('an inner error whose toString throws logs as its type', () {
    final err = DioException(
      requestOptions: RequestOptions(path: 'https://api.example.com/users'),
      error: _Throwing(),
    );

    runZonedGuarded(
      () => LoggerDioInterceptor().onError(err, ErrorInterceptorHandler()),
      (_, _) {},
    );

    check('${writer.records.single.error}')
      ..contains('Error: <_Throwing>')
      ..not((it) => it.contains('secret-token'));
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
