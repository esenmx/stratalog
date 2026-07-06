import 'package:checks/checks.dart';
import 'package:chirp/chirp.dart';
import 'package:grpc/grpc.dart';
import 'package:stratalog/stratalog.dart';
import 'package:stratalog_grpc/stratalog_grpc.dart';
import 'package:test/test.dart';

final class _CapturingWriter extends ChirpWriter {
  final records = <LogRecord>[];

  @override
  void write(LogRecord record) => records.add(record);
}

/// Hand-rolled echo service — no protoc: payloads are raw bytes.
final class _EchoService extends Service {
  _EchoService() {
    $addMethod(
      ServiceMethod<List<int>, List<int>>(
        'Echo',
        _echo,
        false,
        false,
        (bytes) => bytes,
        (value) => value,
      ),
    );
    $addMethod(
      ServiceMethod<List<int>, List<int>>(
        'Boom',
        _boom,
        false,
        false,
        (bytes) => bytes,
        (value) => value,
      ),
    );
  }

  @override
  String get $name => 'test.Echo';

  Future<List<int>> _echo(ServiceCall call, Future<List<int>> request) =>
      request;

  Future<List<int>> _boom(ServiceCall call, Future<List<int>> request) async {
    await request;
    throw const GrpcError.notFound('missing');
  }
}

final class _EchoClient extends Client {
  // ignore: matching_super_parameters -- Client's positional is `_channel`
  _EchoClient(ClientChannel super.channel, {super.interceptors});

  static final _echo = ClientMethod<List<int>, List<int>>(
    '/test.Echo/Echo',
    (value) => value,
    (bytes) => bytes,
  );
  static final _boom = ClientMethod<List<int>, List<int>>(
    '/test.Echo/Boom',
    (value) => value,
    (bytes) => bytes,
  );

  ResponseFuture<List<int>> echo(List<int> request, {CallOptions? options}) =>
      $createUnaryCall(_echo, request, options: options);

  ResponseFuture<List<int>> boom(List<int> request, {CallOptions? options}) =>
      $createUnaryCall(_boom, request, options: options);
}

void main() {
  late _CapturingWriter writer;
  late Server server;
  late ClientChannel channel;
  late _EchoClient client;

  setUp(() async {
    writer = _CapturingWriter();
    Chirp.root = ChirpLogger().addWriter(writer);

    server = Server.create(services: [_EchoService()]);
    await server.serve(address: 'localhost', port: 0);
    channel = ClientChannel(
      'localhost',
      port: server.port!,
      options: const ChannelOptions(
        credentials: ChannelCredentials.insecure(),
      ),
    );
    client = _EchoClient(
      channel,
      interceptors: [LoggerGrpcInterceptor(LogLayer.network)],
    );
  });

  tearDown(() async {
    await channel.shutdown();
    await server.shutdown();
    Chirp.root = null;
  });

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  test('unary success logs request and OK with duration', () async {
    final reply = await client.echo([1, 2, 3]);
    await settle();

    check(reply).deepEquals([1, 2, 3]);
    check(writer.records.map((r) => '${r.message}')).deepEquals([
      '→ /test.Echo/Echo',
      '← OK /test.Echo/Echo',
    ]);
    check(writer.records.last.data['duration_ms']).isA<int>();
  });

  test('failure logs status code at warning and still throws', () async {
    await check(client.boom([0])).throws<GrpcError>();
    await settle();

    final record = writer.records.last;
    check(record.level).equals(ChirpLogLevel.warning);
    check('${record.message}').equals('✗ NOT_FOUND /test.Echo/Boom');
    check(record.error).isA<GrpcError>();
  });

  test('sensitive metadata masked, others verbatim', () async {
    await client.echo(
      [0],
      options: CallOptions(
        metadata: {
          'Authorization': 'Bearer secret-token',
          'x-request-id': 'r1',
        },
      ),
    );
    await settle();

    final metadata =
        writer.records.first.data['metadata']! as Map<String, Object?>;
    check(metadata['authorization']).equals('***');
    check(metadata['x-request-id']).equals('r1');
    check(
      '${writer.records.first.data}',
    ).not((it) => it.contains('secret-token'));
  });
}
