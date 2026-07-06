import 'dart:async';

import 'package:checks/checks.dart';
import 'package:chirp/chirp.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stratalog/dio.dart';
import 'package:stratalog/stratalog.dart';

final class _CapturingWriter extends ChirpWriter {
  final records = <LogRecord>[];

  @override
  void write(LogRecord record) => records.add(record);
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
      LogLayer.network,
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

  test('oversized bodies are ellipsized, small ones kept structured', () {
    final interceptor =
        LoggerDioInterceptor(LogLayer.network, maxBodyChars: 32);
    final response = Response<Object?>(
      requestOptions: request(),
      statusCode: 200,
      data: {'blob': 'x' * 200},
    );
    interceptor.onResponse(response, ResponseInterceptorHandler());

    final body = writer.records.single.data['body']! as String;
    // '{blob: ' + 200 x's + '}' = 208 chars, minus the 32 kept.
    check(body).endsWith('…(+176 chars)');
    check(body.length).equals(32 + '…(+176 chars)'.length);

    writer.records.clear();
    interceptor.onResponse(
      Response<Object?>(
        requestOptions: request(),
        statusCode: 200,
        data: {'ok': true},
      ),
      ResponseInterceptorHandler(),
    );
    check(writer.records.single.data['body']).isA<Map<String, Object?>>();
  });

  test('failures log at warning with status and duration', () {
    final interceptor = LoggerDioInterceptor(LogLayer.network);
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
        ),
        ErrorInterceptorHandler(),
      ),
      (_, _) {},
    );

    final record = writer.records.single;
    check(record.level).equals(ChirpLogLevel.warning);
    check(
      '${record.message}',
    ).equals('✗ 404 GET https://api.example.com/users');
    check(record.data['duration_ms']).isA<int>();
  });
}
