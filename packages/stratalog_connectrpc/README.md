# stratalog_connectrpc

ConnectRPC integration for [stratalog](https://pub.dev/packages/stratalog) — taps ConnectRPC into stratalog's colored, contrast-verified log layers.

```dart
Transport(..., interceptors: [loggerConnectInterceptor(LogLayer.network)]);
```

Works with the Connect, gRPC, and gRPC-Web protocols alike: procedure, Connect code, duration, and header redaction. Failures log at `warning` with the `ConnectException` attached.

See the [stratalog README](https://github.com/esenmx/stratalog) for the layer taxonomy, theming, and crash-reporting setup.
