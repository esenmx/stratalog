import 'dart:io';

/// True for `dart:io` transport errors whose `toString()` carries only an
/// address, OS/TLS status, or URL — never request bodies or header values.
///
/// Checked via real runtime types (rather than stringified `runtimeType`) so
/// `HandshakeException` and `CertificateException` (subtypes of
/// [TlsException]) remain recognised in `--obfuscate` release builds.
bool isSafeIoError(Object error) =>
    error is SocketException || error is TlsException;
