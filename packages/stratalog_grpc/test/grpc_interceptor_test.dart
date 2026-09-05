import 'dart:async';

import 'package:checks/checks.dart';
import 'package:chirp/chirp.dart';
import 'package:grpc/grpc.dart';
import 'package:protobuf/protobuf.dart';
import 'package:stratalog_grpc/stratalog_grpc.dart';
import 'package:test/test.dart';

final class _CapturingWriter extends ChirpWriter {
  final records = <LogRecord>[];

  @override
  void write(LogRecord record) => records.add(record);
}

/// Throws on outcome records only — the ingress `→` log runs synchronously
/// inside the caller's invocation and would fail the call itself.
final class _ExplodingWriter extends ChirpWriter {
  @override
  void write(LogRecord record) {
    if ('${record.message}'.startsWith('→')) return;
    throw StateError('sink down');
  }
}

/// Hand-rolled proto — no protoc: a string field plus a repeated field, big
/// enough to expose any producer-side clipping.
final class _BigMessage extends GeneratedMessage {
  new();

  factory fromBuffer(List<int> bytes) => _BigMessage()..mergeFromBuffer(bytes);

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

/// Hand-rolled echo service — no protoc: payloads are raw bytes.
final class _EchoService extends Service {
  new() {
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
    $addMethod(
      ServiceMethod<_BigMessage, _BigMessage>(
        'EchoBig',
        _echoBig,
        false,
        false,
        _BigMessage.fromBuffer,
        (value) => value.writeToBuffer(),
      ),
    );
  }

  @override
  String get $name => 'test.Echo';

  Future<List<int>> _echo(ServiceCall call, Future<List<int>> request) =>
      request;

  Future<List<int>> _boom(ServiceCall call, Future<List<int>> request) async {
    await request;
    throw const GrpcError.custom(StatusCode.notFound, 'missing', null, null, {
      'error-code': 'geo.404',
    });
  }

  Future<_BigMessage> _echoBig(ServiceCall call, Future<_BigMessage> request) =>
      request;
}

final class _EchoClient(
  // ignore: matching_super_parameters -- Client's positional is `_channel`
  ClientChannel super.channel, {
  super.interceptors,
}) extends Client {
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
  static final _echoBig = ClientMethod<_BigMessage, _BigMessage>(
    '/test.Echo/EchoBig',
    (value) => value.writeToBuffer(),
    _BigMessage.fromBuffer,
  );

  ResponseFuture<List<int>> echo(List<int> request, {CallOptions? options}) =>
      $createUnaryCall(_echo, request, options: options);

  ResponseFuture<List<int>> boom(List<int> request, {CallOptions? options}) =>
      $createUnaryCall(_boom, request, options: options);

  ResponseFuture<_BigMessage> echoBig(_BigMessage request) =>
      $createUnaryCall(_echoBig, request);
}

void main() {
  late _CapturingWriter writer;
  late Server server;
  late ClientChannel channel;
  late _EchoClient client;

  setUp(() async {
    writer = _CapturingWriter();
    Chirp.root = ChirpLogger().addWriter(writer);

    server = .create(services: [_EchoService()]);
    await server.serve(address: 'localhost', port: 0);
    channel = ClientChannel(
      'localhost',
      port: server.port!,
      options: const ChannelOptions(credentials: .insecure()),
    );
    client = _EchoClient(channel, interceptors: [LoggerGrpcInterceptor()]);
  });

  tearDown(() async {
    await channel.shutdown();
    await server.shutdown();
    Chirp.root = null;
  });

  Future<void> settle() => Future<void>.delayed(.zero);

  test('unary success logs request and OK with duration', () async {
    final reply = await client.echo([1, 2, 3]);
    await settle();

    check(reply).deepEquals([1, 2, 3]);
    check(writer.records.map((r) => '${r.message}'))
        .deepEquals(['→ /test.Echo/Echo', '← OK /test.Echo/Echo']);
    check(writer.records.last.data['duration_ms']).isA<int>();
  });

  test('throwing writer in the unary side listener never reaches the zone — '
      'caller still gets the reply', () async {
    Chirp.root = ChirpLogger().addWriter(_ExplodingWriter());
    final zoneErrors = <Object>[];

    // The side-listener future is created inside this guarded zone; under
    // `unawaited` its error would surface here as an unhandled zone error.
    final reply = await runZonedGuarded(
      () => client.echo([7]),
      (error, _) => zoneErrors.add(error),
    )!;
    await settle();

    check(reply).deepEquals([7]);
    check(zoneErrors).isEmpty();
  });

  test('failure logs status, error-code trailer, and still throws', () async {
    await check(client.boom([0])).throws<GrpcError>();
    await settle();

    final record = writer.records.last;
    check(record.level).equals(.warning);
    check('${record.message}').equals('✗ NOT_FOUND /test.Echo/Boom');
    check(record.error).isA<GrpcError>();
    check(record.data['error_code']).equals('geo.404');
    check(record.data['duration_ms']).isA<int>();
  });

  test('large message lands in record data verbatim — no clipping', () async {
    final message = _BigMessage()
      ..text = 'a' * 5000
      ..items.addAll(List.generate(150, (i) => 'item_$i'));
    // Fresh expected copy per assertion — comparing the logged body against
    // the instance handed to the client would pass even if the producer
    // clipped it in place.
    Map<String, Object?> expectedBody() => {
      'text': 'a' * 5000,
      'items': List.generate(150, (i) => 'item_$i'),
    };

    final reply = await client.echoBig(message);
    await settle();

    check(reply.text).length.equals(5000);
    check(writer.records.first.data['request_body']! as Map<String, Object?>)
        .deepEquals(expectedBody());
    check(writer.records.last.data['response_body']! as Map<String, Object?>)
        .deepEquals(expectedBody());
  });

  test('logBodies false pins the release shape — no body keys ever', () async {
    final quiet = _EchoClient(
      channel,
      interceptors: [LoggerGrpcInterceptor(logBodies: false)],
    );

    await quiet.echoBig(_BigMessage()..text = 'user-payload');
    await check(quiet.boom([0])).throws<GrpcError>();
    await settle();

    check(writer.records.map((r) => '${r.message}')).deepEquals([
      '→ /test.Echo/EchoBig',
      '← OK /test.Echo/EchoBig',
      '→ /test.Echo/Boom',
      '✗ NOT_FOUND /test.Echo/Boom',
    ]);
    // The release contract: only method path, status, error-code trailer,
    // duration, and metadata — a future tap change reintroducing body dumps
    // must fail here.
    final keys = writer.records.expand((r) => r.data.keys).toSet();
    check(keys.difference({'metadata', 'duration_ms', 'error_code'})).isEmpty();
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

  test('sensitive metadata masked by default, others verbatim', () async {
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
    check('${writer.records.first.data}')
        .not((it) => it.contains('secret-token'));
  });

  test('sensitive metadata verbatim when opted out', () async {
    final unmaskedClient = _EchoClient(
      channel,
      interceptors: [LoggerGrpcInterceptor(maskSensitiveValues: false)],
    );
    await unmaskedClient.echo(
      [0],
      options: CallOptions(metadata: {'authorization': 'Bearer secret-token'}),
    );
    await settle();

    final metadata =
        writer.records.first.data['metadata']! as Map<String, Object?>;
    check(metadata['authorization']).equals('Bearer secret-token');
  });
}
