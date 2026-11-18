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
      'set-cookie': 'sid=secret-session',
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
      {'error-code': 'geo.507', 'set-cookie': 'sid=secret-session'},
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
      $createStreamingCall(_boomStream, .value(request));

  ResponseStream<List<int>> fineStream(
    List<int> request, {
    CallOptions? options,
  }) => $createStreamingCall(_fineStream, .value(request), options: options);

  ResponseStream<List<int>> tickStream(List<int> request) =>
      $createStreamingCall(_tickStream, .value(request));

  // Mirrors the protoc-generated client-streaming stub shape: the streaming
  // interceptor seam, consumed through `.single`.
  ResponseFuture<List<int>> collect(Stream<List<int>> requests) =>
      $createStreamingCall(_collect, requests).single;

  ResponseFuture<List<int>> collectBoom(Stream<List<int>> requests) =>
      $createStreamingCall(_collectBoom, requests).single;
}

final class _RejectedCall<Q, R>(
  ClientMethod<Q, R> method,
  CallOptions options,
  final Object _error,
) extends ClientCall<Q, R> {
  this : super(method, const .empty(), options);

  @override
  Stream<R> get response => .error(_error);
}

final class _RejectingInterceptor(final Object _error)
    extends ClientInterceptor {
  @override
  ResponseStream<R> interceptStreaming<Q, R>(
    ClientMethod<Q, R> method,
    Stream<Q> requests,
    CallOptions options,
    ClientStreamingInvoker<Q, R> invoker,
  ) => ResponseStream(_RejectedCall(method, options, _error));
}

extension on Subject<LogRecord> {
  void withholds(String secret) => has(
    (r) => '${r.message} ${r.data} ${r.error}',
    'rendered record',
  ).not((it) => it.contains(secret));
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
      await check(responses.toList()).throws<GrpcError>(
        (it) => it
            .has((e) => e.trailers, 'trailers')
            .isNotNull()
            .containsKey('set-cookie'),
      );
      await settle();

      check(writer.records.map((r) => '${r.message}')).deepEquals([
        '⇄ /test.Stream/BoomStream',
        '✗ NOT_FOUND /test.Stream/BoomStream',
      ]);
      final record = writer.records.last;
      check(record.level).equals(.warning);
      check(record.data['error_code']).equals('geo.404');
      check(record).withholds('secret-session');
      check('${record.error}')
        ..contains('NOT_FOUND')
        ..contains('missing');
      check(record.error)
          .isA<GrpcError>()
          .has((e) => e.trailers, 'trailers')
          .isNotNull()
          .isEmpty();
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
      .fromIterable([
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
    await check(client.collectBoom(.value([0]))).throws<GrpcError>(
      (it) => it
          .has((e) => e.trailers, 'trailers')
          .isNotNull()
          .containsKey('set-cookie'),
    );
    await settle();

    check(writer.records.map((r) => '${r.message}')).deepEquals([
      '⇄ /test.Stream/CollectBoom',
      '✗ RESOURCE_EXHAUSTED /test.Stream/CollectBoom',
    ]);
    final record = writer.records.last;
    check(record.level).equals(.warning);
    check(record.data['error_code']).equals('geo.507');
    check(record).withholds('secret-session');
    check('${record.error}')
      ..contains('RESOURCE_EXHAUSTED')
      ..contains('overflow');
    check(record.error)
        .isA<GrpcError>()
        .has((e) => e.trailers, 'trailers')
        .isNotNull()
        .isEmpty();
  });

  test('non-ASCII sensitive value: the peer resets the stream, the value '
      'stays masked', () async {
    await check(
      client.fineStream(
        [0],
        options: CallOptions(
          metadata: {'authorization': 'Bearer sécret-token'},
        ),
      ).toList(),
    ).throws<GrpcError>();
    await settle();

    check(writer.records.map((r) => '${r.message}')).deepEquals([
      '⇄ /test.Stream/FineStream',
      '✗ UNKNOWN /test.Stream/FineStream',
    ]);
    check(writer.records.first.data['metadata'])
        .isA<Map<String, Object?>>()
        .deepEquals({'authorization': '***'});
    for (final record in writer.records) {
      check(record).withholds('sécret');
    }
  });

  test('control-character sensitive value: grpc trims it and sends, the value '
      'stays masked', () async {
    await client.fineStream(
      [0],
      options: CallOptions(
        metadata: {'authorization': 'Bearer secret-token\n'},
      ),
    ).toList();
    await settle();

    check(writer.records.map((r) => '${r.message}')).deepEquals([
      '⇄ /test.Stream/FineStream',
      '⇄ done /test.Stream/FineStream',
    ]);
    check(writer.records.first.data['metadata'])
        .isA<Map<String, Object?>>()
        .deepEquals({'authorization': '***'});
    for (final record in writer.records) {
      check(record).withholds('secret-token');
    }
  });

  test('a FormatException stream failure logs as its type alone', () async {
    const error = FormatException(
      'Invalid HTTP header field value: "Bearer secret-token"',
    );
    final rejecting = _StreamClient(
      channel,
      interceptors: [LoggerGrpcInterceptor(), _RejectingInterceptor(error)],
    );

    await check(rejecting.fineStream([0]).toList())
        .throws<FormatException>((it) => it.identicalTo(error));
    await settle();

    final record = writer.records.last;
    check('${record.message}').equals('✗ - /test.Stream/FineStream');
    check(record).withholds('secret-token');
    check(record.error).equals('FormatException');
  });

  test('cancelling client-streaming single logs cancelled at trace, never '
      'warning', () async {
    final controller = StreamController<List<int>>();
    final call = client.collect(controller.stream);
    await call.cancel();
    controller.close().ignore();
    await check(call).throws<GrpcError>();
    await settle();

    check(writer.records.map((r) => '${r.message}')).deepEquals([
      '⇄ /test.Stream/Collect',
      '⇄ cancelled /test.Stream/Collect',
    ]);
    check(writer.records.last.level).equals(.trace);
  });
}
