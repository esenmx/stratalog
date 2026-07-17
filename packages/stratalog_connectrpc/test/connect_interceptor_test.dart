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
  const _NeverAborts();

  @override
  DateTime? get deadline => null;

  @override
  Future<ConnectException> get future => .any(const []);
}

/// Hand-rolled proto — no protoc: a string field plus a repeated field, big
/// enough to expose any producer-side clipping.
final class _BigMessage extends GeneratedMessage {
  _BigMessage();

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

Spec<String, String> _spec(StreamType type) => Spec(
  '/acme.foo.v1.FooService/Bar',
  type,
  () => '',
  () => '',
);

UnaryRequest<String, String> _request({Headers? headers}) => UnaryRequest(
  _spec(.unary),
  'https://api.example.com/acme.foo.v1.FooService/Bar',
  headers ?? Headers(),
  'ping',
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
    final interceptor = loggerConnectInterceptor(.network);
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

    final wrapped = loggerConnectInterceptor(
      .network,
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

    check(
      writer.records.first.data['request_body']! as Map<String, Object?>,
    ).deepEquals(expectedBody());
    check(
      writer.records.last.data['response_body']! as Map<String, Object?>,
    ).deepEquals(expectedBody());
  });

  test('sensitive headers verbatim by default', () async {
    final headers = Headers()..add('authorization', 'Bearer secret-token');
    final wrapped = loggerConnectInterceptor(.network)<String, String>(ok);

    await wrapped(_request(headers: headers));

    final logged =
        writer.records.first.data['headers']! as Map<String, Object?>;
    check(logged['authorization']).equals('Bearer secret-token');
  });

  test('sensitive headers masked, others verbatim', () async {
    final headers = Headers()
      ..add('authorization', 'Bearer secret-token')
      ..add('x-request-id', 'r1');
    final wrapped = loggerConnectInterceptor(
      .network,
      maskSensitiveValues: true,
    )<String, String>(ok);

    await wrapped(_request(headers: headers));

    final logged =
        writer.records.first.data['headers']! as Map<String, Object?>;
    check(logged['authorization']).equals('***');
    check(logged['x-request-id']).equals('r1');
    check(
      '${writer.records.first.data}',
    ).not((it) => it.contains('secret-token'));
  });

  test('ConnectException logs code at warning and rethrows', () async {
    Future<Response<String, String>> fails(Request<String, String> _) async {
      throw ConnectException(.notFound, 'missing');
    }

    final wrapped = loggerConnectInterceptor(.network)<String, String>(
      fails,
    );

    await check(wrapped(_request())).throws<ConnectException>();
    final record = writer.records.last;
    check(record.level).equals(.warning);
    check(
      '${record.message}',
    ).equals('✗ not_found /acme.foo.v1.FooService/Bar');
  });

  test('streaming spec logs with the stream arrow', () async {
    Future<Response<String, String>> okStream(
      Request<String, String> request,
    ) async => StreamResponse(
      request.spec,
      Headers(),
      const .empty(),
      Headers(),
    );

    final wrapped = loggerConnectInterceptor(.network)<String, String>(
      okStream,
    );
    await wrapped(
      StreamRequest(
        _spec(.bidi),
        'https://api.example.com/acme.foo.v1.FooService/Bar',
        Headers(),
        const .empty(),
        const _NeverAborts(),
      ),
    );

    check('${writer.records.first.message}').startsWith('⇄ ');
  });
}
