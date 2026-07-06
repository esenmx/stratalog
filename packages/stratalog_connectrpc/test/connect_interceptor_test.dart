import 'package:checks/checks.dart';
import 'package:chirp/chirp.dart';
import 'package:connectrpc/connect.dart';
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

  test('sensitive headers masked, others verbatim', () async {
    final headers = Headers()
      ..add('authorization', 'Bearer secret-token')
      ..add('x-request-id', 'r1');
    final wrapped = loggerConnectInterceptor(.network)<String, String>(
      ok,
    );

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
