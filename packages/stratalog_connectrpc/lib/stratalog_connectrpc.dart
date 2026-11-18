/// ConnectRPC integration for stratalog: `loggerConnectInterceptor`.
library;

export 'package:stratalog/redact.dart'
    show defaultHeaderAllowlist, defaultRedactKeys, defaultSensitiveHeaders;

export 'src/connect_interceptor.dart';
