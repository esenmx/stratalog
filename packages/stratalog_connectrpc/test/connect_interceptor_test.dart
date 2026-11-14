import 'dart:convert';
import 'dart:io';
import 'dart:io' as io show HttpClient;
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:chirp/chirp.dart';
import 'package:connectrpc/connect.dart';
import 'package:connectrpc/io.dart';
import 'package:connectrpc/protobuf.dart';
import 'package:connectrpc/protocol/connect.dart' as connect_protocol;
import 'package:protobuf/protobuf.dart';
import 'package:protobuf/well_known_types/google/protobuf/any.pb.dart';
import 'package:protobuf/well_known_types/google/protobuf/struct.pb.dart';
import 'package:stratalog_connectrpc/stratalog_connectrpc.dart';
import 'package:test/test.dart';

final class _CapturingWriter extends ChirpWriter {
  final records = <LogRecord>[];

  @override
  void write(LogRecord record) => records.add(record);
}

final class _NeverAborts implements AbortSignal {
  const new();

  @override
  DateTime? get deadline => null;

  @override
  Future<ConnectException> get future => .any(const []);
}

/// Hand-rolled proto — no protoc: a string field plus a repeated field, big
/// enough to expose any producer-side clipping, and a string map.
final class _BigMessage extends GeneratedMessage {
  new();

  static final BuilderInfo _info =
      BuilderInfo('test.Big', createEmptyInstance: _BigMessage.new)
        ..aOS(1, 'text')
        ..pPS(2, 'items')
        ..m<String, String>(
          3,
          'tags',
          keyFieldType: PbFieldType.OS,
          valueFieldType: PbFieldType.OS,
        )
        ..hasRequiredFields = false;

  @override
  BuilderInfo get info_ => _info;

  @override
  _BigMessage createEmptyInstance() => _BigMessage();

  @override
  _BigMessage clone() => _BigMessage()..mergeFromMessage(this);

  String get text => $_getSZ(0);
  set text(String value) => $_setString(0, value);

  List<String> get items => $_getList(1);
}

final class _Card extends GeneratedMessage {
  new();

  static final BuilderInfo _info =
      BuilderInfo('test.Card', createEmptyInstance: _Card.new)
        ..aOS(1, 'holder')
        ..aOS(2, 'pin')
        ..hasRequiredFields = false;

  @override
  BuilderInfo get info_ => _info;

  @override
  _Card createEmptyInstance() => _Card();

  @override
  _Card clone() => _Card()..mergeFromMessage(this);

  String get holder => $_getSZ(0);
  set holder(String value) => $_setString(0, value);

  String get pin => $_getSZ(1);
  set pin(String value) => $_setString(1, value);
}

final class _Login extends GeneratedMessage {
  new();

  static final BuilderInfo _info =
      BuilderInfo('test.Login', createEmptyInstance: _Login.new)
        ..aOS(1, 'user')
        ..aOS(2, 'newPassword', protoName: 'new_password')
        ..aOM<_Card>(3, 'card', subBuilder: _Card.new)
        ..pPM<_Card>(4, 'cards', subBuilder: _Card.new)
        ..m<String, String>(
          5,
          'labels',
          keyFieldType: PbFieldType.OS,
          valueFieldType: PbFieldType.OS,
        )
        ..aOM<Struct>(6, 'extra', subBuilder: Struct.new)
        ..hasRequiredFields = false;

  @override
  BuilderInfo get info_ => _info;

  @override
  _Login createEmptyInstance() => _Login();

  @override
  _Login clone() => _Login()..mergeFromMessage(this);

  String get user => $_getSZ(0);
  set user(String value) => $_setString(0, value);

  String get newPassword => $_getSZ(1);
  set newPassword(String value) => $_setString(1, value);

  _Card get card => $_getN(2);
  set card(_Card value) => $_setField(3, value);

  List<_Card> get cards => $_getList(3);

  Map<String, String> get labels => $_getMap(4);

  Struct get extra => $_getN(5);
  set extra(Struct value) => $_setField(6, value);
}

final class _UnprintableError {
  @override
  String toString() => throw StateError('unprintable');
}

Spec<String, String> _spec(StreamType type) =>
    Spec('/acme.foo.v1.FooService/Bar', type, () => '', () => '');

UnaryRequest<String, String> _request({Headers? headers}) => UnaryRequest(
  _spec(.unary),
  'https://api.example.com/acme.foo.v1.FooService/Bar',
  headers ?? Headers(),
  'ping',
  const _NeverAborts(),
);

StreamRequest<String, String> _streamRequest() => StreamRequest(
  _spec(.bidi),
  'https://api.example.com/acme.foo.v1.FooService/Bar',
  Headers(),
  const .empty(),
  const _NeverAborts(),
);

void main() {
  late _CapturingWriter writer;

  setUp(() {
    writer = _CapturingWriter();
    Chirp.root = ChirpLogger().addWriter(writer);
  });

  tearDown(() => Chirp.root = null);

  Future<Response<String, String>> ok(Request<String, String> request) async =>
      UnaryResponse(request.spec, Headers(), 'pong', Headers());

  test('success logs procedure with duration at trace', () async {
    final interceptor = loggerConnectInterceptor();
    final wrapped = interceptor<String, String>(ok);

    final response = await wrapped(_request());

    check(response).isA<UnaryResponse<String, String>>();
    check(writer.records.map((r) => '${r.message}')).deepEquals([
      '→ /acme.foo.v1.FooService/Bar',
      '← OK /acme.foo.v1.FooService/Bar',
    ]);
    check(writer.records.last.data['duration_ms']).isA<int>();
  });

  test('large message lands in record data verbatim when logBodies is true — '
      'no clipping', () async {
    final message = _BigMessage()
      ..text = 'a' * 5000
      ..items.addAll(List.generate(150, (i) => 'item_$i'));
    // Fresh expected copy per assertion — comparing the logged body against
    // the instance handed to the interceptor would pass even if the producer
    // clipped it in place.
    Map<String, Object?> expectedBody() => {
      'text': 'a' * 5000,
      'items': List.generate(150, (i) => 'item_$i'),
    };

    Future<Response<_BigMessage, _BigMessage>> okBig(
      Request<_BigMessage, _BigMessage> request,
    ) async => UnaryResponse(request.spec, Headers(), message, Headers());

    final wrapped = loggerConnectInterceptor(
      logBodies: true,
    )<_BigMessage, _BigMessage>(okBig);
    await wrapped(
      UnaryRequest(
        const Spec(
          '/acme.foo.v1.FooService/Big',
          .unary,
          _BigMessage.new,
          _BigMessage.new,
        ),
        'https://api.example.com/acme.foo.v1.FooService/Big',
        Headers(),
        message,
        const _NeverAborts(),
      ),
    );

    check(writer.records.first.data['request_body']! as Map<String, Object?>)
        .deepEquals(expectedBody());
    check(writer.records.last.data['response_body']! as Map<String, Object?>)
        .deepEquals(expectedBody());
  });

  test('sensitive headers masked by default, unlisted dropped, allowlisted '
      'kept', () async {
    final headers = Headers()
      ..add('authorization', 'Bearer secret-token')
      ..add('x-request-id', 'r1')
      ..add('x-internal-envelope', 'noise');
    final wrapped = loggerConnectInterceptor()<String, String>(ok);

    await wrapped(_request(headers: headers));

    final logged =
        writer.records.first.data['headers']! as Map<String, Object?>;
    check(logged['authorization']).equals('***');
    check(logged['x-request-id']).equals('r1');
    check(logged).not((it) => it.containsKey('x-internal-envelope'));
    check('${writer.records.first.data}')
        .not((it) => it.contains('secret-token'));
  });

  test('custom sensitiveHeaders and headerAllowlist match regardless of '
      'caller casing and combine multi-value headers', () async {
    final headers = Headers()
      ..add('x-firebase-appcheck', 'secret-appcheck')
      ..add('x-trace-id', 't1')
      ..add('x-trace-id', 't2');
    final wrapped = loggerConnectInterceptor(
      sensitiveHeaders: {'X-Firebase-AppCheck'},
      headerAllowlist: {'X-Trace-Id'},
    )<String, String>(ok);

    await wrapped(_request(headers: headers));

    final logged =
        writer.records.first.data['headers']! as Map<String, Object?>;
    check(logged['x-firebase-appcheck']).equals('***');
    check(logged['x-trace-id']).equals('t1, t2');
  });

  test('sensitive headers verbatim when opted out', () async {
    final headers = Headers()..add('authorization', 'Bearer secret-token');
    final wrapped = loggerConnectInterceptor(
      maskSensitiveValues: false,
    )<String, String>(ok);

    await wrapped(_request(headers: headers));

    final logged =
        writer.records.first.data['headers']! as Map<String, Object?>;
    check(logged['authorization']).equals('Bearer secret-token');
  });

  test('ConnectException logs code, error-code trailer, rethrows', () async {
    Future<Response<String, String>> fails(Request<String, String> _) async {
      throw ConnectException(
        .notFound,
        'missing',
        metadata: Headers()..add('error-code', 'geo.404'),
      );
    }

    final wrapped = loggerConnectInterceptor()<String, String>(fails);

    await check(wrapped(_request())).throws<ConnectException>();
    final record = writer.records.last;
    check(record.level).equals(.warning);
    check('${record.message}')
        .equals('✗ not_found /acme.foo.v1.FooService/Bar');
    check(record.data['error_code']).equals('geo.404');
    check(record.data['duration_ms']).isA<int>();
  });

  test('non-Connect unary error logs a failure line and propagates', () async {
    Future<Response<String, String>> fails(Request<String, String> _) async {
      throw StateError('boom');
    }

    final wrapped = loggerConnectInterceptor()<String, String>(fails);

    await check(wrapped(_request())).throws<StateError>();
    final record = writer.records.last;
    check(record.level).equals(.warning);
    check('${record.message}').equals('✗ - /acme.foo.v1.FooService/Bar');
    check(record.data['duration_ms']).isA<int>();
  });

  test('logBodies defaults to false and pins the release shape — no body keys '
      'ever', () async {
    final message = _BigMessage()..text = 'user-payload';
    Future<Response<_BigMessage, _BigMessage>> okBig(
      Request<_BigMessage, _BigMessage> request,
    ) async => UnaryResponse(request.spec, Headers(), message, Headers());

    final wrapped = loggerConnectInterceptor()<_BigMessage, _BigMessage>(okBig);
    await wrapped(
      UnaryRequest(
        const Spec(
          '/acme.foo.v1.FooService/Big',
          .unary,
          _BigMessage.new,
          _BigMessage.new,
        ),
        'https://api.example.com/acme.foo.v1.FooService/Big',
        Headers(),
        message,
        const _NeverAborts(),
      ),
    );

    check(writer.records.map((r) => '${r.message}')).deepEquals([
      '→ /acme.foo.v1.FooService/Big',
      '← OK /acme.foo.v1.FooService/Big',
    ]);
    // The release contract: only procedure, code, error-code trailer,
    // duration, and headers — a future tap change reintroducing body dumps
    // must fail here.
    final keys = writer.records.expand((r) => r.data.keys).toSet();
    check(keys.difference({'headers', 'duration_ms', 'error_code'})).isEmpty();
    check(writer.records.map((r) => '${r.message} ${r.data}').join('\n'))
        .not((it) => it.contains('user-payload'));
  });

  test('protoLogShape under name stripping is the tag-keyed map', () {
    final message = _BigMessage()
      ..text = 'hi'
      ..items.addAll(['a', 'b']);

    check(protoLogShape(message, namesStripped: true))
        .isA<Map<String, Object?>>()
        .deepEquals({
          '1': 'hi',
          '2': ['a', 'b'],
        });
  });

  test('stream call logs only the request arrow at headers', () async {
    Future<Response<String, String>> okStream(
      Request<String, String> request,
    ) async =>
        StreamResponse(request.spec, Headers(), const .empty(), Headers());

    final wrapped = loggerConnectInterceptor()<String, String>(okStream);
    await wrapped(_streamRequest());

    // Protocol.stream completes the future at headers-received — the
    // terminal line belongs to the message stream, never here.
    check(writer.records.map((r) => '${r.message}'))
        .deepEquals(['⇄ /acme.foo.v1.FooService/Bar']);
  });

  test('clean stream logs done exactly once, headers and trailers '
      'pass by reference', () async {
    final headers = Headers()..add('x-init', 'h1');
    final trailers = Headers()..add('x-trailer', 't1');
    Future<Response<String, String>> okStream(
      Request<String, String> request,
    ) async => StreamResponse(
      request.spec,
      headers,
      .fromIterable(['a', 'b']),
      trailers,
    );

    final wrapped = loggerConnectInterceptor()<String, String>(okStream);
    final response =
        await wrapped(_streamRequest()) as StreamResponse<String, String>;

    check(identical(response.headers, headers)).isTrue();
    check(identical(response.trailers, trailers)).isTrue();
    check(await response.message.toList()).deepEquals(['a', 'b']);
    check(writer.records.map((r) => '${r.message}')).deepEquals([
      '⇄ /acme.foo.v1.FooService/Bar',
      '⇄ done /acme.foo.v1.FooService/Bar',
    ]);
    check(writer.records.last.data['duration_ms']).isA<int>();
  });

  test('stream ConnectException logs failure exactly once with code and '
      'error-code trailer, rethrows', () async {
    Stream<String> failing() async* {
      yield 'a';
      throw ConnectException(
        .unavailable,
        'dropped',
        metadata: Headers()..add('error-code', 'net.503'),
      );
    }

    Future<Response<String, String>> okStream(
      Request<String, String> request,
    ) async => StreamResponse(request.spec, Headers(), failing(), Headers());

    final wrapped = loggerConnectInterceptor()<String, String>(okStream);
    final response =
        await wrapped(_streamRequest()) as StreamResponse<String, String>;

    await check(response.message.toList()).throws<ConnectException>();
    check(writer.records.map((r) => '${r.message}')).deepEquals([
      '⇄ /acme.foo.v1.FooService/Bar',
      '✗ unavailable /acme.foo.v1.FooService/Bar',
    ]);
    final record = writer.records.last;
    check(record.level).equals(.warning);
    check(record.data['error_code']).equals('net.503');
    check(record.data['duration_ms']).isA<int>();
  });

  test('non-Connect stream error logs a terminal failure line and '
      'propagates', () async {
    Stream<String> failing() async* {
      yield 'a';
      throw StateError('boom');
    }

    Future<Response<String, String>> okStream(
      Request<String, String> request,
    ) async => StreamResponse(request.spec, Headers(), failing(), Headers());

    final wrapped = loggerConnectInterceptor()<String, String>(okStream);
    final response =
        await wrapped(_streamRequest()) as StreamResponse<String, String>;

    await check(response.message.toList()).throws<StateError>();
    check(writer.records.map((r) => '${r.message}')).deepEquals([
      '⇄ /acme.foo.v1.FooService/Bar',
      '✗ - /acme.foo.v1.FooService/Bar',
    ]);
    check(writer.records.last.level).equals(.warning);
  });

  group('failure record error withholds what the record withholds', () {
    String recordText(LogRecord record) =>
        '${record.message} ${record.data} ${record.error}';

    for (final (name, thrown, want) in <(String, Object, String)>[
      (
        'ConnectException wrapping a body',
        ConnectException.from(
          const FormatException('Bad JSON', '{"token": "secret-body"}', 1),
          .internal,
        ),
        '[internal] FormatException',
      ),
      (
        'ConnectException metadata, details and cause',
        ConnectException(
          .permissionDenied,
          'denied',
          cause: 'secret-cause',
          metadata: Headers()..add('set-cookie', 'secret-cookie'),
          details: [ErrorDetail('t', Uint8List(0), 'secret-detail')],
        ),
        '[permission_denied] denied',
      ),
      (
        'non-Connect error carrying a GET URL',
        HttpException(
          'Connection closed',
          uri: .parse('https://api.example.com/a.B/C?message=secret-body'),
        ),
        'HttpException: Connection closed, uri = https://api.example.com/a.B/C',
      ),
      (
        'multi-line ConnectException message',
        ConnectException(.unknown, 'first\nsecret-second-line'),
        '[unknown] first',
      ),
      (
        'multi-line non-Connect error',
        const HttpException('Connection closed\nsecret-second-line'),
        'HttpException: Connection closed',
      ),
      (
        'raw FormatException carrying a body',
        const FormatException('Bad JSON', '{"token": "secret-body"}', 1),
        'FormatException',
      ),
      (
        'ArgumentError echoing a header value',
        ArgumentError.value(
          'Bearer sécret-token',
          'value',
          'Contains invalid characters.',
        ),
        'ArgumentError',
      ),
    ]) {
      test('unary: $name', () async {
        Future<Response<String, String>> fails(Request<String, String> _) =>
            Future.error(thrown);

        final wrapped = loggerConnectInterceptor()<String, String>(fails);

        await check(wrapped(_request()))
            .throws<Object>((it) => it.identicalTo(thrown));
        final record = writer.records.last;
        check(recordText(record)).not((it) => it.contains('secret'));
        check('${record.error}').equals(want);
        check(record.error).not((it) => it.identicalTo(thrown));
        if (thrown is ConnectException) {
          check(record.error).isA<ConnectException>()
            ..has((e) => e.code, 'code').equals(thrown.code)
            ..has((e) => e.metadata.entries, 'metadata').isEmpty()
            ..has((e) => e.details, 'details').isEmpty()
            ..has((e) => e.cause, 'cause').isNull();
        }
      });
    }

    test('stream: ConnectException wrapping a body', () async {
      final thrown = ConnectException.from(
        const FormatException('Bad JSON', '{"token": "secret-body"}'),
        .internal,
      );
      Future<Response<String, String>> okStream(
        Request<String, String> request,
      ) async =>
          StreamResponse(request.spec, Headers(), .error(thrown), Headers());

      final wrapped = loggerConnectInterceptor()<String, String>(okStream);
      final response =
          await wrapped(_streamRequest()) as StreamResponse<String, String>;

      await check(response.message.toList())
          .throws<Object>((it) => it.identicalTo(thrown));
      final record = writer.records.last;
      check(recordText(record)).not((it) => it.contains('secret'));
      check('${record.error}').equals('[internal] FormatException');
    });

    for (final (name, body) in [
      ('malformed JSON', '{"text": secret-body}'),
      ('map key in a decode path', '{"tags": {"secret-key": 5}}'),
    ]) {
      test('real transport: $name', () async {
        Future<HttpResponse> client(HttpRequest _) async => HttpResponse(
          200,
          Headers()..add('content-type', 'application/json'),
          .value(utf8.encode(body)),
          Headers(),
        );
        final transport = connect_protocol.Transport(
          baseUrl: 'https://api.example.com',
          codec: const JsonCodec(),
          httpClient: client,
          interceptors: [loggerConnectInterceptor()],
        );

        await check(
          transport.unary(
            const Spec(
              '/acme.foo.v1.FooService/Big',
              .unary,
              _BigMessage.new,
              _BigMessage.new,
            ),
            _BigMessage(),
          ),
        ).throws<ConnectException>();
        final record = writer.records.last;
        check(recordText(record)).not((it) => it.contains('secret'));
        check('${record.error}').equals('[internal] FormatException');
      });
    }

    test('real io client: a rejected header value', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) => request.response.close());
      final client = io.HttpClient();
      addTearDown(() => client.close(force: true));
      final transport = connect_protocol.Transport(
        baseUrl: 'http://${server.address.host}:${server.port}',
        codec: const JsonCodec(),
        httpClient: createHttpClient(client),
        interceptors: [loggerConnectInterceptor()],
      );
      Object? thrown;

      try {
        await transport.unary(
          const Spec(
            '/acme.foo.v1.FooService/Big',
            .unary,
            _BigMessage.new,
            _BigMessage.new,
          ),
          _BigMessage(),
          CallOptions(
            headers: Headers()..add('authorization', 'Bearer secret-token\n'),
          ),
        );
      } on Object catch (error) {
        thrown = error;
      }

      check(thrown).isA<FormatException>();
      check('$thrown').contains('secret-token');
      final record = writer.records.last;
      check(record.error).not((it) => it.identicalTo(thrown));
      check(recordText(record)).not((it) => it.contains('secret-token'));
      check('${record.error}').equals('FormatException');
    });

    for (final (name, message) in [
      ('dotted', 'a.' * 16000),
      ('scheme separators', '://' * 10000),
    ]) {
      test('scrubs a long $name message in bounded time', () async {
        final thrown = ConnectException(.unknown, message);
        Future<Response<String, String>> fails(Request<String, String> _) =>
            Future.error(thrown);
        final wrapped = loggerConnectInterceptor()<String, String>(fails);
        final watch = Stopwatch()..start();

        await check(wrapped(_request()))
            .throws<Object>((it) => it.identicalTo(thrown));
        check(watch.elapsedMilliseconds).isLessThan(1000);
        check('${writer.records.last.error}'.length).isLessThan(300);
      });
    }

    test('an error whose toString throws logs its type', () async {
      final thrown = _UnprintableError();
      Future<Response<String, String>> fails(Request<String, String> _) =>
          Future.error(thrown);
      final wrapped = loggerConnectInterceptor()<String, String>(fails);

      await check(wrapped(_request()))
          .throws<Object>((it) => it.identicalTo(thrown));
      check(writer.records.last.error).equals('_UnprintableError');
    });

    test('logBodies keeps the original error', () async {
      final thrown = ConnectException.from(
        const FormatException('Bad JSON', '{"token": "secret-body"}'),
        .internal,
      );
      Future<Response<String, String>> fails(Request<String, String> _) =>
          Future.error(thrown);

      final wrapped = loggerConnectInterceptor(logBodies: true)<String, String>(
        fails,
      );

      await check(wrapped(_request()))
          .throws<Object>((it) => it.identicalTo(thrown));
      check(writer.records.last.error).identicalTo(thrown);
    });
  });

  group('logBodies masks body keys and redacted procedures', () {
    const procedure = '/acme.auth.v1.AuthService/Login';
    const redactedBody = '*** redacted body ***';

    _Login login() => _Login()
      ..user = 'ada'
      ..newPassword = 'secret-pw'
      ..card = (_Card()
        ..holder = 'Ada'
        ..pin = 'secret-pin')
      ..cards.add(
        _Card()
          ..holder = 'Bob'
          ..pin = 'secret-pin-2',
      )
      ..labels.addAll({'apiKey': 'secret-key', 'region': 'eu'})
      ..extra = (Struct()
        ..fields['client_secret'] = (Value()..stringValue = 'secret-cs')
        ..fields['plan'] = (Value()..stringValue = 'pro'));

    Map<String, Object?> verbatim() => {
      'user': 'ada',
      'newPassword': 'secret-pw',
      'card': {'holder': 'Ada', 'pin': 'secret-pin'},
      'cards': [
        {'holder': 'Bob', 'pin': 'secret-pin-2'},
      ],
      'labels': {'apiKey': 'secret-key', 'region': 'eu'},
      'extra': {'client_secret': 'secret-cs', 'plan': 'pro'},
    };

    Map<String, Object?> masked() => {
      'user': 'ada',
      'newPassword': '***',
      'card': {'holder': 'Ada', 'pin': '***'},
      'cards': [
        {'holder': 'Bob', 'pin': '***'},
      ],
      'labels': {'apiKey': '***', 'region': 'eu'},
      'extra': {'client_secret': '***', 'plan': 'pro'},
    };

    Future<List<LogRecord>> exchange(
      Interceptor interceptor, {
      String path = procedure,
      _Login Function()? message,
    }) async {
      final build = message ?? login;
      final spec = Spec<_Login, _Login>(path, .unary, _Login.new, _Login.new);
      Future<Response<_Login, _Login>> echo(
        Request<_Login, _Login> request,
      ) async => UnaryResponse(spec, Headers(), build(), Headers());

      await interceptor<_Login, _Login>(echo)(
        UnaryRequest(
          spec,
          'https://api.example.com$path',
          Headers(),
          build(),
          const _NeverAborts(),
        ),
      );
      return writer.records;
    }

    Condition<Object?> isBody(Map<String, Object?> body) =>
        (it) => it.isA<Map<String, Object?>>().deepEquals(body);
    final authService = loggerConnectInterceptor(
      logBodies: true,
      redactBodyPaths: {'AuthService/'},
    );

    for (final (name, interceptor, path, want)
        in <(String, Interceptor, String, Condition<Object?>)>[
          (
            'default keys at depth, in lists, as map keys and in a Struct',
            loggerConnectInterceptor(logBodies: true),
            procedure,
            isBody(masked()),
          ),
          (
            'header unmasking leaves body keys masked',
            loggerConnectInterceptor(
              logBodies: true,
              maskSensitiveValues: false,
            ),
            procedure,
            isBody(masked()),
          ),
          (
            'an empty redactKeys logs verbatim',
            loggerConnectInterceptor(logBodies: true, redactKeys: const {}),
            procedure,
            isBody(verbatim()),
          ),
          (
            'a redactBodyPaths service prefix replaces both bodies',
            authService,
            procedure,
            (it) => it.equals(redactedBody),
          ),
          (
            'a matched key masks message, list and map values whole',
            loggerConnectInterceptor(
              logBodies: true,
              redactKeys: {'card', 'cards', 'labels', 'extra'},
            ),
            procedure,
            isBody({
              'user': 'ada',
              'newPassword': 'secret-pw',
              'card': '***',
              'cards': '***',
              'labels': '***',
              'extra': '***',
            }),
          ),
          (
            'redactBodyPaths leaves an unmatched method key-masked',
            authService,
            '/acme.foo.v1.FooService/Login',
            isBody(masked()),
          ),
        ]) {
      test(name, () async {
        final records = await exchange(interceptor, path: path);

        check(records.first.data['request_body']).which(want);
        check(records.last.data['response_body']).which(want);
      });
    }

    for (final entry in [
      'newpassword',
      'NewPassword',
      'new_password',
      'NEW-PASSWORD',
    ]) {
      test('redactKeys entry $entry matches normalized body keys', () async {
        _Login message() => _Login()
          ..newPassword = 'secret-field'
          ..labels.addAll({
            'newPassword': 'secret-a',
            'new_password': 'secret-b',
            'NEW-PASSWORD': 'secret-c',
            'new.password': 'kept',
          });

        final records = await exchange(
          loggerConnectInterceptor(logBodies: true, redactKeys: {entry}),
          message: message,
        );

        for (final key in ['request_body', 'response_body']) {
          check(records.map((r) => r.data[key]).nonNulls.single).which(
            isBody({
              'newPassword': '***',
              'labels': {
                'newPassword': '***',
                'new_password': '***',
                'NEW-PASSWORD': '***',
                'new.password': 'kept',
              },
            }),
          );
        }
      });
    }

    final card = _Card()..holder = 'Ada';
    final unregisteredAny = Any.pack(_Card()..pin = 'secret-any');
    final readable = isBody({'holder': 'Ada'});
    Condition<Object?> isPlaceholder(String type) =>
        (it) => it.equals('<unloggable body: $type>');

    for (final (name, sent, received, wantRequest, wantResponse)
        in <(String, Object, Object, Condition<Object?>, Condition<Object?>)>[
          (
            'request is an unregistered Any',
            unregisteredAny,
            card,
            isPlaceholder('ArgumentError'),
            readable,
          ),
          (
            'response is an unregistered Any',
            card,
            unregisteredAny,
            readable,
            isPlaceholder('ArgumentError'),
          ),
          (
            'request toString throws',
            _UnprintableError(),
            card,
            isPlaceholder('StateError'),
            readable,
          ),
        ]) {
      test('unloggable body logs a placeholder: $name', () async {
        final spec = Spec<Object, Object>(
          procedure,
          .unary,
          () => sent,
          () => received,
        );
        var calls = 0;
        final response = UnaryResponse(spec, Headers(), received, Headers());
        Future<Response<Object, Object>> reply(Request<Object, Object> _) {
          calls++;
          return Future.value(response);
        }

        final got =
            await loggerConnectInterceptor(logBodies: true)<Object, Object>(
              reply,
            )(
              UnaryRequest(
                spec,
                procedure,
                Headers(),
                sent,
                const _NeverAborts(),
              ),
            );

        check(got).identicalTo(response);
        check(calls).equals(1);
        check(writer.records.map((r) => '${r.message}'))
            .deepEquals(['→ $procedure', '← OK $procedure']);
        check(writer.records.first.data['request_body']).which(wantRequest);
        check(writer.records.last.data['response_body']).which(wantResponse);
      });
    }

    test('logBodies off ignores redactBodyPaths and logs no body', () async {
      final records = await exchange(
        loggerConnectInterceptor(redactBodyPaths: {procedure}),
      );

      final keys = records.expand((r) => r.data.keys).toSet();
      check(keys.difference({'headers', 'duration_ms'})).isEmpty();
    });

    final thrown = ConnectException.from(
      const FormatException('Bad JSON', '{"password": "secret-body"}'),
      .internal,
    );
    Condition<Object?> isCopy() =>
        (it) =>
            it.has((e) => '$e', 'text').equals('[internal] FormatException');
    Condition<Object?> isOriginal() =>
        (it) => it.identicalTo(thrown);

    for (final (name, interceptor, path, want)
        in <(String, Interceptor, String, Condition<Object?>)>[
          (
            'matched procedure attaches the copy',
            loggerConnectInterceptor(
              logBodies: true,
              redactBodyPaths: {procedure},
            ),
            procedure,
            isCopy(),
          ),
          (
            'unmatched procedure attaches the original',
            loggerConnectInterceptor(
              logBodies: true,
              redactBodyPaths: {procedure},
            ),
            '/acme.foo.v1.FooService/Bar',
            isOriginal(),
          ),
          (
            'matched procedure with logBodies off attaches the copy',
            loggerConnectInterceptor(redactBodyPaths: {procedure}),
            procedure,
            isCopy(),
          ),
        ]) {
      test('unary failure: $name', () async {
        Future<Response<String, String>> fails(Request<String, String> _) =>
            Future.error(thrown);
        final spec = Spec<String, String>(path, .unary, () => '', () => '');

        await check(
          interceptor<String, String>(fails)(
            UnaryRequest(spec, path, Headers(), 'ping', const _NeverAborts()),
          ),
        ).throws<Object>((it) => it.identicalTo(thrown));

        check(writer.records.last.error).which(want);
      });

      test('stream failure: $name', () async {
        Future<Response<String, String>> okStream(
          Request<String, String> request,
        ) async =>
            StreamResponse(request.spec, Headers(), .error(thrown), Headers());
        final spec = Spec<String, String>(path, .bidi, () => '', () => '');

        final response = await interceptor<String, String>(okStream)(
          StreamRequest(
            spec,
            path,
            Headers(),
            const .empty(),
            const _NeverAborts(),
          ),
        ) as StreamResponse<String, String>;

        await check(response.message.toList())
            .throws<Object>((it) => it.identicalTo(thrown));
        check(writer.records.last.error).which(want);
      });
    }
  });
}
