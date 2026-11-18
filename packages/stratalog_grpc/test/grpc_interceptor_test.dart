import 'dart:async';

import 'package:checks/checks.dart';
import 'package:chirp/chirp.dart';
import 'package:grpc/grpc.dart';
import 'package:protobuf/protobuf.dart';
import 'package:protobuf/well_known_types/google/protobuf/struct.pb.dart';
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

/// Hand-rolled proto — no protoc: credential-like fields at the top level, in
/// a nested message, in a repeated message, as map-field keys and in a Struct.
final class _Credentials extends GeneratedMessage {
  new();

  factory fromBuffer(List<int> bytes) => _Credentials()..mergeFromBuffer(bytes);

  factory fromJson(Map<String, Object?> json) =>
      _Credentials()..mergeFromProto3Json(json);

  static final BuilderInfo _info =
      BuilderInfo('test.Credentials', createEmptyInstance: _Credentials.new)
        ..aOS(1, 'user')
        ..aOS(2, 'password')
        ..aOS(3, 'newPassword', protoName: 'new_password')
        ..aOS(4, 'apiKey', protoName: 'api_key')
        ..aOM<_Credentials>(5, 'inner', subBuilder: _Credentials.new)
        ..pPM<_Credentials>(6, 'history', subBuilder: _Credentials.new)
        ..m<String, String>(
          7,
          'labels',
          entryClassName: 'test.Credentials.LabelsEntry',
          keyFieldType: PbFieldType.OS,
          valueFieldType: PbFieldType.OS,
          packageName: const PackageName('test'),
        )
        ..aOM<Struct>(8, 'extra', subBuilder: Struct.new)
        ..hasRequiredFields = false;

  @override
  BuilderInfo get info_ => _info;

  @override
  _Credentials createEmptyInstance() => _Credentials();

  @override
  _Credentials clone() => _Credentials()..mergeFromMessage(this);
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
    $addMethod(
      ServiceMethod<_Credentials, _Credentials>(
        'EchoCredentials',
        _echoCredentials,
        false,
        false,
        _Credentials.fromBuffer,
        (value) => value.writeToBuffer(),
      ),
    );
  }

  @override
  String get $name => 'test.Echo';

  Future<List<int>> _echo(ServiceCall call, Future<List<int>> request) =>
      request;

  Future<List<int>> _boom(ServiceCall call, Future<List<int>> request) async {
    final bytes = await request;
    if (bytes case [1]) {
      final auth = call.clientMetadata?['authorization'] ?? '';
      throw GrpcError.unauthenticated('invalid token $auth');
    }
    throw const GrpcError.custom(StatusCode.notFound, 'missing', null, null, {
      'error-code': 'geo.404',
      'set-cookie': 'sid=secret-session',
    });
  }

  Future<_BigMessage> _echoBig(ServiceCall call, Future<_BigMessage> request) =>
      request;

  Future<_Credentials> _echoCredentials(
    ServiceCall call,
    Future<_Credentials> request,
  ) => request;
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
  static final _echoCredentials = ClientMethod<_Credentials, _Credentials>(
    '/test.Echo/EchoCredentials',
    (value) => value.writeToBuffer(),
    _Credentials.fromBuffer,
  );

  ResponseFuture<List<int>> echo(List<int> request, {CallOptions? options}) =>
      $createUnaryCall(_echo, request, options: options);

  ResponseFuture<List<int>> boom(List<int> request, {CallOptions? options}) =>
      $createUnaryCall(_boom, request, options: options);

  ResponseFuture<_BigMessage> echoBig(_BigMessage request) =>
      $createUnaryCall(_echoBig, request);

  ResponseFuture<_Credentials> echoCredentials(_Credentials request) =>
      $createUnaryCall(_echoCredentials, request);
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
  ResponseFuture<R> interceptUnary<Q, R>(
    ClientMethod<Q, R> method,
    Q request,
    CallOptions options,
    ClientUnaryInvoker<Q, R> invoker,
  ) => ResponseFuture(_RejectedCall(method, options, _error));
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

  test('failure attaches a GrpcError stripped to code and message', () async {
    await check(client.boom([0])).throws<GrpcError>(
      (it) => it
          .has((e) => e.trailers, 'trailers')
          .isNotNull()
          .containsKey('set-cookie'),
    );
    await settle();

    final record = writer.records.last;
    check('${record.message} ${record.data} ${record.error}')
        .not((it) => it.contains('secret-session'));
    check('${record.error}')
      ..contains('NOT_FOUND')
      ..contains('missing');
    check(record.error).isA<GrpcError>()
      ..has((e) => e.trailers, 'trailers').isNotNull().isEmpty()
      ..has((e) => e.details, 'details').isNull()
      ..has((e) => e.rawResponse, 'rawResponse').isNull();
  });

  test('large message lands in record data verbatim when logBodies is true — '
      'no clipping', () async {
    final bodyClient = _EchoClient(
      channel,
      interceptors: [LoggerGrpcInterceptor(logBodies: true)],
    );
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

    final reply = await bodyClient.echoBig(message);
    await settle();

    check(reply.text).length.equals(5000);
    check(writer.records.first.data['request_body']! as Map<String, Object?>)
        .deepEquals(expectedBody());
    check(writer.records.last.data['response_body']! as Map<String, Object?>)
        .deepEquals(expectedBody());
  });

  test('logBodies defaults to false and pins the release shape — no body keys '
      'ever', () async {
    check(LoggerGrpcInterceptor().logBodies).isFalse();

    await client.echoBig(_BigMessage()..text = 'user-payload');
    await check(client.boom([0])).throws<GrpcError>();
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
    check(
      writer.records.map((r) => '${r.message} ${r.data} ${r.error}').join('\n'),
    ).not((it) => it.contains('user-payload'));
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

  test('sensitive metadata masked by default, unlisted dropped, allowlisted '
      'kept', () async {
    await client.echo(
      [0],
      options: CallOptions(
        metadata: {
          'Authorization': 'Bearer secret-token',
          'x-request-id': 'r1',
          'x-internal-envelope': 'noise',
        },
      ),
    );
    await settle();

    final metadata =
        writer.records.first.data['metadata']! as Map<String, Object?>;
    check(metadata['authorization']).equals('***');
    check(metadata['x-request-id']).equals('r1');
    check(metadata).not((it) => it.containsKey('x-internal-envelope'));
    check('${writer.records.first.data}')
        .not((it) => it.contains('secret-token'));
  });

  test('custom sensitiveMetadata and metadataAllowlist match regardless of '
      'caller casing', () async {
    final customClient = _EchoClient(
      channel,
      interceptors: [
        LoggerGrpcInterceptor(
          sensitiveMetadata: {'X-Firebase-AppCheck'},
          metadataAllowlist: {'X-Trace-Id'},
        ),
      ],
    );
    await customClient.echo(
      [0],
      options: CallOptions(
        metadata: {
          'x-firebase-appcheck': 'secret-appcheck',
          'x-trace-id': 'tr-42',
        },
      ),
    );
    await settle();

    final metadata =
        writer.records.first.data['metadata']! as Map<String, Object?>;
    check(metadata['x-firebase-appcheck']).equals('***');
    check(metadata['x-trace-id']).equals('tr-42');
  });

  test('non-ASCII sensitive value: the peer resets the stream, the value '
      'stays masked', () async {
    await check(
      client.echo(
        [0],
        options: CallOptions(
          metadata: {'authorization': 'Bearer sécret-token'},
        ),
      ),
    ).throws<GrpcError>();
    await settle();

    check(writer.records.map((r) => '${r.message}'))
        .deepEquals(['→ /test.Echo/Echo', '✗ UNKNOWN /test.Echo/Echo']);
    check(writer.records.first.data['metadata'])
        .isA<Map<String, Object?>>()
        .deepEquals({'authorization': '***'});
    for (final record in writer.records) {
      check(record).withholds('sécret');
    }
  });

  test('control-character sensitive value: grpc trims it and sends, the value '
      'stays masked', () async {
    await client.echo(
      [0],
      options: CallOptions(
        metadata: {'authorization': 'Bearer secret-token\n'},
      ),
    );
    await settle();

    check(writer.records.map((r) => '${r.message}'))
        .deepEquals(['→ /test.Echo/Echo', '← OK /test.Echo/Echo']);
    check(writer.records.first.data['metadata'])
        .isA<Map<String, Object?>>()
        .deepEquals({'authorization': '***'});
    for (final record in writer.records) {
      check(record).withholds('secret-token');
    }
  });

  test('FormatException failure is attached as its type alone, even for a '
      'value the logger never saw — the caller keeps the original', () async {
    const error = FormatException(
      'Invalid HTTP header field value: "Bearer secret-token"',
    );
    final rejecting = _EchoClient(
      channel,
      interceptors: [LoggerGrpcInterceptor(), _RejectingInterceptor(error)],
    );

    await check(rejecting.echo([0]))
        .throws<FormatException>((it) => it.identicalTo(error));
    await settle();

    final record = writer.records.last;
    check('${record.message}').equals('✗ - /test.Echo/Echo');
    check(record).withholds('secret-token');
    check(record.error).equals('FormatException');
  });

  test('other non-GrpcError failure is attached as its first line, withheld '
      'values masked longest first before the cut', () async {
    final error = StateError('rejected "Bearer secret\n-token"');
    final rejecting = _EchoClient(
      channel,
      interceptors: [LoggerGrpcInterceptor(), _RejectingInterceptor(error)],
    );

    await check(
      rejecting.echo(
        [0],
        options: CallOptions(
          metadata: {
            'x-api-key': 'Bearer secret',
            'authorization': 'Bearer secret\n-token',
          },
        ),
      ),
    ).throws<StateError>((it) => it.identicalTo(error));
    await settle();

    final record = writer.records.last;
    check(record).withholds('secret');
    check(record.error).equals('StateError: Bad state: rejected "***"');
  });

  test('a server status keeps its text when it contains an unlisted metadata '
      'value', () async {
    await check(
      client.boom([0], options: CallOptions(metadata: {'x-flag': 'ss'})),
    ).throws<GrpcError>();
    await settle();

    check(writer.records.last.error)
        .isA<GrpcError>()
        .has((e) => e.message, 'message')
        .equals('missing');
  });

  test('a call-setup failure keeps its reason, the sensitive value it echoes '
      'masked — the caller keeps the original', () async {
    await check(
      client.echo(
        [0],
        options: CallOptions(
          metadata: {'authorization': 'Bearer secret-token'},
          providers: [
            (metadata, uri) =>
                throw StateError('refresh failed for "Bearer secret-token"'),
          ],
        ),
      ),
    ).throws<GrpcError>(
      (it) => it
          .has((e) => e.message, 'message')
          .isNotNull()
          .contains('secret-token'),
    );
    await settle();

    final record = writer.records.last;
    check(record).withholds('secret-token');
    check(record.error)
        .isA<GrpcError>()
        .has((e) => e.message, 'message')
        .equals('Error making call: Bad state: refresh failed for "***"');
  });

  test('call-setup FormatException or ArgumentError from MetadataProvider '
      'withholds unseen token and strips multiline source', () async {
    for (final (throwError, want) in <(Never Function(), String)>[
      (
        () => throw ArgumentError.value(
          'Bearer provider-secret',
          'value',
          'Contains invalid characters',
        ),
        'Error making call: ArgumentError',
      ),
      (
        () => throw const FormatException(
          'Invalid HTTP header field value',
          'Bearer provider-secret\nextra-line-secret',
        ),
        'Error making call: FormatException',
      ),
    ]) {
      writer.records.clear();
      await check(
        client.echo([
          0,
        ], options: CallOptions(providers: [(metadata, uri) => throwError()])),
      ).throws<GrpcError>();
      await settle();

      final record = writer.records.last;
      check(record).withholds('provider-secret');
      check(record).withholds('extra-line-secret');
      check(record.error)
          .isA<GrpcError>()
          .has((e) => e.message, 'message')
          .equals(want);
    }
  });

  test('peer status masks echoed sensitive metadata token', () async {
    await check(
      client.boom(
        [1],
        options: CallOptions(
          metadata: {'authorization': 'Bearer echoed-peer-secret'},
        ),
      ),
    ).throws<GrpcError>(
      (it) => it
          .has((e) => e.message, 'message')
          .isNotNull()
          .contains('echoed-peer-secret'),
    );
    await settle();

    final record = writer.records.last;
    check(record).withholds('echoed-peer-secret');
    check(record.error)
        .isA<GrpcError>()
        .has((e) => e.message, 'message')
        .equals('invalid token ***');
  });

  test('short sensitive metadata leaves peer status intact', () async {
    await check(
      client.boom([0], options: CallOptions(metadata: {'x-api-key': 'ss'})),
    ).throws<GrpcError>();
    await settle();

    check(writer.records.last.error)
        .isA<GrpcError>()
        .has((e) => e.message, 'message')
        .equals('missing');
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

  group('logged bodies with logBodies on:', () {
    final credentials = <String, Object?>{
      'user': 'ada',
      'password': 'hunter2',
      'inner': {
        'user': 'bob',
        'newPassword': 'n-secret',
        'inner': {'user': 'cy', 'apiKey': 'k-secret'},
      },
      'history': [
        {'user': 'h1', 'password': 'p-secret'},
        {'user': 'h2', 'apiKey': 'k2-secret'},
      ],
      'labels': {
        'new_password': 'l1-secret',
        'NEW-PASSWORD': 'l2-secret',
        'region': 'eu',
      },
      'extra': {
        'clientSecret': 's-secret',
        'nested': {'pin': '0000', 'ok': true},
        'cards': [
          {'cvv': '999', 'brand': 'visa'},
        ],
        'secret': {'deep': 'whole-value'},
      },
    };
    final defaultsMasked = <String, Object?>{
      'user': 'ada',
      'password': '***',
      'inner': {
        'user': 'bob',
        'newPassword': '***',
        'inner': {'user': 'cy', 'apiKey': '***'},
      },
      'history': [
        {'user': 'h1', 'password': '***'},
        {'user': 'h2', 'apiKey': '***'},
      ],
      'labels': {'new_password': '***', 'NEW-PASSWORD': '***', 'region': 'eu'},
      'extra': {
        'clientSecret': '***',
        'nested': {'pin': '***', 'ok': true},
        'cards': [
          {'cvv': '***', 'brand': 'visa'},
        ],
        'secret': '***',
      },
    };
    final newPasswordMasked = <String, Object?>{
      ...credentials,
      'inner': {
        'user': 'bob',
        'newPassword': '***',
        'inner': {'user': 'cy', 'apiKey': 'k-secret'},
      },
      'labels': {'new_password': '***', 'NEW-PASSWORD': '***', 'region': 'eu'},
    };
    Future<void> sendCredentials(_EchoClient client) =>
        client.echoCredentials(.fromJson(credentials));
    Future<void> sendBig(_EchoClient client) =>
        client.echoBig(_BigMessage()..text = 'hi');
    Future<void> sendBytes(_EchoClient client) => client.echo([1, 2, 3]);
    Future<void> sendUnserializable(_EchoClient client) =>
        client.echoCredentials(
          _Credentials()..setField(8, Struct()..fields['kindless'] = Value()),
        );

    for (final (name, tap, send, want) in [
      (
        'default keys masked at any depth',
        LoggerGrpcInterceptor(logBodies: true),
        sendCredentials,
        defaultsMasked,
      ),
      (
        'keys stay masked with maskSensitiveValues off',
        LoggerGrpcInterceptor(logBodies: true, maskSensitiveValues: false),
        sendCredentials,
        defaultsMasked,
      ),
      (
        'a custom key matches ignoring case, _ and -',
        LoggerGrpcInterceptor(logBodies: true, redactKeys: {'NEW-PASSWORD'}),
        sendCredentials,
        newPasswordMasked,
      ),
      (
        'an empty redactKeys logs verbatim',
        LoggerGrpcInterceptor(logBodies: true, redactKeys: {}),
        sendCredentials,
        credentials,
      ),
      (
        'a matched method path drops the body',
        LoggerGrpcInterceptor(
          logBodies: true,
          redactBodyPaths: {'Echo/EchoCred'},
        ),
        sendCredentials,
        '*** redacted body ***',
      ),
      (
        'a service prefix drops a non-protobuf body',
        LoggerGrpcInterceptor(
          logBodies: true,
          redactBodyPaths: {'/test.Echo/'},
        ),
        sendBytes,
        '*** redacted body ***',
      ),
      (
        'an unmatched method path keeps the body',
        LoggerGrpcInterceptor(
          logBodies: true,
          redactBodyPaths: {'/test.Echo/EchoCredentials'},
        ),
        sendBig,
        {'text': 'hi'},
      ),
      (
        'a body proto3 JSON rejects logs a placeholder, the call goes through',
        LoggerGrpcInterceptor(logBodies: true),
        sendUnserializable,
        '<unloggable body: ArgumentError>',
      ),
    ]) {
      test('$name — request and response', () async {
        final tapped = _EchoClient(channel, interceptors: [tap]);
        await send(tapped);
        await settle();

        check(writer.records.map((r) => r.data['request_body']).nonNulls)
            .deepEquals([want]);
        check(writer.records.map((r) => r.data['response_body']).nonNulls)
            .deepEquals([want]);
      });
    }
  });
}
