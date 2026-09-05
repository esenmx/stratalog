import 'dart:async';

import 'package:checks/checks.dart';
import 'package:chirp/chirp.dart';
import 'package:grpc/grpc.dart';
import 'package:stratalog_grpc/stratalog_grpc.dart';
import 'package:test/test.dart';

final class _CapturingWriter extends ChirpWriter {
  final records = <LogRecord>[];

  @override
  void write(LogRecord record) => records.add(record);
}

final class _StreamService extends Service {
  new() {
    $addMethod(
      ServiceMethod<List<int>, List<int>>(
        'BoomStream',
        _boomStream,
        false,
        true,
        (bytes) => bytes,
        (value) => value,
      ),
    );
    $addMethod(
      ServiceMethod<List<int>, List<int>>(
        'FineStream',
        _fineStream,
        false,
        true,
        (bytes) => bytes,
        (value) => value,
      ),
    );
    $addMethod(
      ServiceMethod<List<int>, List<int>>(
        'TickStream',
        _tickStream,
        false,
        true,
        (bytes) => bytes,
        (value) => value,
      ),
    );
    $addMethod(
      ServiceMethod<List<int>, List<int>>(
        'Collect',
        _collect,
        true,
        false,
        (bytes) => bytes,
        (value) => value,
      ),
    );
    $addMethod(
      ServiceMethod<List<int>, List<int>>(
        'CollectBoom',
        _collectBoom,
        true,
        false,
        (bytes) => bytes,
        (value) => value,
      ),
    );
  }

  @override
  String get $name => 'test.Stream';

  Stream<List<int>> _boomStream(
    ServiceCall call,
    Future<List<int>> request,
  ) async* {
    await request;
    yield [1];
    throw const GrpcError.custom(StatusCode.notFound, 'missing', null, null, {
      'error-code': 'geo.404',
    });
  }

  Stream<List<int>> _fineStream(
    ServiceCall call,
    Future<List<int>> request,
  ) async* {
    await request;
    yield [1];
    yield [2];
  }

  Stream<List<int>> _tickStream(
    ServiceCall call,
    Future<List<int>> request,
  ) async* {
    await request;
    var tick = 0;
    while (true) {
      yield [tick++];
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  Future<List<int>> _collect(
    ServiceCall call,
    Stream<List<int>> requests,
  ) async => [await requests.length];

  Future<List<int>> _collectBoom(
    ServiceCall call,
    Stream<List<int>> requests,
  ) async {
    await requests.drain<void>();
    throw const GrpcError.custom(
      StatusCode.resourceExhausted,
      'overflow',
      null,
      null,
      {'error-code': 'geo.507'},
    );
  }
}

final class _StreamClient(
  // ignore: matching_super_parameters -- Client's positional is `_channel`
  ClientChannel super.channel, {
  super.interceptors,
}) extends Client {
  static ClientMethod<List<int>, List<int>> _method(String name) =>
      ClientMethod('/test.Stream/$name', (value) => value, (bytes) => bytes);

  static final ClientMethod<List<int>, List<int>> _boomStream = _method(
    'BoomStream',
  );
  static final ClientMethod<List<int>, List<int>> _fineStream = _method(
    'FineStream',
  );
  static final ClientMethod<List<int>, List<int>> _tickStream = _method(
    'TickStream',
  );
  static final ClientMethod<List<int>, List<int>> _collect = _method('Collect');
  static final ClientMethod<List<int>, List<int>> _collectBoom = _method(
    'CollectBoom',
  );

  ResponseStream<List<int>> boomStream(List<int> request) =>
      $createStreamingCall(_boomStream, Stream.value(request));

  ResponseStream<List<int>> fineStream(List<int> request) =>
      $createStreamingCall(_fineStream, Stream.value(request));

  ResponseStream<List<int>> tickStream(List<int> request) =>
      $createStreamingCall(_tickStream, Stream.value(request));

  // Mirrors the protoc-generated client-streaming stub shape: the streaming
  // interceptor seam, consumed through `.single`.
  ResponseFuture<List<int>> collect(Stream<List<int>> requests) =>
      $createStreamingCall(_collect, requests).single;

  ResponseFuture<List<int>> collectBoom(Stream<List<int>> requests) =>
      $createStreamingCall(_collectBoom, requests).single;
}

void main() {
  late _CapturingWriter writer;
  late Server server;
  late ClientChannel channel;
  late _StreamClient client;

  setUp(() async {
    writer = _CapturingWriter();
    Chirp.root = ChirpLogger().addWriter(writer);

    server = .create(services: [_StreamService()]);
    await server.serve(address: 'localhost', port: 0);
    channel = ClientChannel(
      'localhost',
      port: server.port!,
      options: const ChannelOptions(credentials: .insecure()),
    );
    client = _StreamClient(channel, interceptors: [LoggerGrpcInterceptor()]);
  });

  tearDown(() async {
    await channel.shutdown();
    await server.shutdown();
    Chirp.root = null;
  });

  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 50));

  test(
    'failed stream logs a warning with status, not the success done line',
    () async {
      final responses = client.boomStream([0]);
      await check(responses.toList()).throws<GrpcError>();
      await settle();

      check(writer.records.map((r) => '${r.message}')).deepEquals([
        '⇄ /test.Stream/BoomStream',
        '✗ NOT_FOUND /test.Stream/BoomStream',
      ]);
      final record = writer.records.last;
      check(record.level).equals(.warning);
      check(record.error).isA<GrpcError>();
      check(record.data['error_code']).equals('geo.404');
    },
  );

  test('clean stream logs the done line exactly once', () async {
    final values = await client.fineStream([0]).toList();
    await settle();

    check(values).deepEquals([
      [1],
      [2],
    ]);
    check(writer.records.map((r) => '${r.message}')).deepEquals([
      '⇄ /test.Stream/FineStream',
      '⇄ done /test.Stream/FineStream',
    ]);
    check(writer.records.last.data['duration_ms']).isA<int>();
  });

  test('subscription cancel logs a cancelled line, never done', () async {
    await for (final value in client.tickStream([0])) {
      check(value).deepEquals([0]);
      break;
    }
    await settle();

    check(writer.records.map((r) => '${r.message}')).deepEquals([
      '⇄ /test.Stream/TickStream',
      '⇄ cancelled /test.Stream/TickStream',
    ]);
    check(writer.records.last.level).equals(.trace);
  });

  test('call cancel logs a cancelled line once — the CANCELLED error still '
      'reaches the caller unlogged', () async {
    final responses = client.tickStream([0]);
    final errors = <Object>[];
    final subscription = responses.listen(
      null,
      onError: errors.add,
      cancelOnError: false,
    );
    await responses.headers;
    await responses.cancel();
    await settle();
    await subscription.cancel();

    check(errors).length.equals(1);
    check(errors.single)
        .isA<GrpcError>()
        .has((e) => e.code, 'code')
        .equals(StatusCode.cancelled);
    check(writer.records.map((r) => '${r.message}')).deepEquals([
      '⇄ /test.Stream/TickStream',
      '⇄ cancelled /test.Stream/TickStream',
    ]);
  });

  test('client-streaming single logs the done line once', () async {
    final reply = await client.collect(
      Stream.fromIterable([
        [1],
        [2],
        [3],
      ]),
    );
    await settle();

    check(reply).deepEquals([3]);
    check(writer.records.map((r) => '${r.message}'))
        .deepEquals(['⇄ /test.Stream/Collect', '⇄ done /test.Stream/Collect']);
  });

  test('client-streaming single logs the failure once with status', () async {
    await check(client.collectBoom(Stream.value([0]))).throws<GrpcError>();
    await settle();

    check(writer.records.map((r) => '${r.message}')).deepEquals([
      '⇄ /test.Stream/CollectBoom',
      '✗ RESOURCE_EXHAUSTED /test.Stream/CollectBoom',
    ]);
    final record = writer.records.last;
    check(record.level).equals(.warning);
    check(record.data['error_code']).equals('geo.507');
  });
}
