import 'package:checks/checks.dart';
import 'package:chirp/chirp.dart';
import 'package:connectrpc/connect.dart';
import 'package:protobuf/protobuf.dart';
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
/// enough to expose any producer-side clipping.
final class _BigMessage extends GeneratedMessage {
  new();

  static final BuilderInfo _info =
      BuilderInfo('test.Big', createEmptyInstance: _BigMessage.new)
        ..aOS(1, 'text')
        ..pPS(2, 'items')
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

  test('large message lands in record data verbatim — no clipping', () async {
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

    check(writer.records.first.data['request_body']! as Map<String, Object?>)
        .deepEquals(expectedBody());
    check(writer.records.last.data['response_body']! as Map<String, Object?>)
        .deepEquals(expectedBody());
  });

  test('sensitive headers masked by default, others verbatim', () async {
    final headers = Headers()
      ..add('authorization', 'Bearer secret-token')
      ..add('x-request-id', 'r1');
    final wrapped = loggerConnectInterceptor()<String, String>(ok);

    await wrapped(_request(headers: headers));

    final logged =
        writer.records.first.data['headers']! as Map<String, Object?>;
    check(logged['authorization']).equals('***');
    check(logged['x-request-id']).equals('r1');
    check('${writer.records.first.data}')
        .not((it) => it.contains('secret-token'));
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
    check(
      '${record.message}',
    ).equals('✗ - /acme.foo.v1.FooService/Bar');
    check(record.data['duration_ms']).isA<int>();
  });

  test('logBodies false pins the release shape — no body keys ever', () async {
    final message = _BigMessage()..text = 'user-payload';
    Future<Response<_BigMessage, _BigMessage>> okBig(
      Request<_BigMessage, _BigMessage> request,
    ) async => UnaryResponse(request.spec, Headers(), message, Headers());

    final wrapped = loggerConnectInterceptor(
      logBodies: false,
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
}
