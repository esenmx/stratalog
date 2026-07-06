# stratalog_grpc

gRPC integration for [stratalog](https://pub.dev/packages/stratalog) — taps gRPC into stratalog's colored, contrast-verified log layers.

```dart
FooServiceClient(channel, interceptors: [LoggerGrpcInterceptor(LogLayer.network)]);
```

Unary and streaming calls with method path, status code, duration, and metadata redaction. Failures log at `warning` with the `GrpcError` attached.

See the [stratalog README](https://github.com/esenmx/stratalog) for the layer taxonomy, theming, and crash-reporting setup.
