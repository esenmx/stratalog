import 'package:chirp/chirp.dart';

/// Pre-defined top-level logging domains ("layers").
///
/// Each layer names a *concern*, not a library, and the set is deliberately
/// non-overlapping — one crisp home per record:
///
/// - [app] — bootstrap, config, DI wiring, business logic; the fallback when
///   nothing narrower fits.
/// - [state] — state-management transitions (Riverpod/Provider/bloc observer
///   output): provider lifecycles, mutations.
/// - [route] — navigation: pushes/pops, tab switches, deep links, guards.
/// - [ui] — presentation: widget/render issues, media loading, animations.
/// - [network] — HTTP/WebSocket traffic and connectivity of *requests*.
/// - [storage] — local persistence: database, prefs, secure storage, files,
///   caches.
/// - [auth] — identity: sign-in/out, token refresh, session expiry.
/// - [platform] — the Flutter↔OS boundary: method channels, plugins,
///   permissions, app lifecycle, notifications. (There is intentionally no
///   separate `lifecycle` layer — an `AppLifecycleState` change *is* an OS
///   signal; likewise background-task *scheduling* logs here while the work a
///   task performs logs to its own domain.)
/// - [analytics] — instrumentation: events dispatched, crash-report
///   forwarding decisions.
///
/// Layers resolve against the *current* `Chirp.root` on every access, so
/// replacing the root (tests, reconfiguration) never strands them — unlike a
/// `static final` child, which binds to whichever root existed at first
/// touch.
abstract final class LogLayer {
  /// Bootstrap, config, DI wiring, business logic; the fallback layer.
  static ChirpLogger get app => layer('App');

  /// State-management transitions (provider lifecycles, mutations).
  static ChirpLogger get state => layer('State');

  /// Navigation: pushes/pops, tab switches, deep links, guards.
  static ChirpLogger get route => layer('Route');

  /// Presentation: widget/render issues, media loading, animations.
  static ChirpLogger get ui => layer('UI');

  /// HTTP/WebSocket traffic.
  static ChirpLogger get network => layer('Network');

  /// Local persistence: database, prefs, secure storage, files, caches.
  static ChirpLogger get storage => layer('Storage');

  /// Identity: sign-in/out, token refresh, session expiry.
  static ChirpLogger get auth => layer('Auth');

  /// The Flutter↔OS boundary: channels, plugins, permissions, lifecycle.
  static ChirpLogger get platform => layer('Platform');

  /// Instrumentation: events dispatched, crash-report forwarding.
  static ChirpLogger get analytics => layer('Analytics');

  static ChirpLogger? _cachedRoot;
  static final Map<String, ChirpLogger> _cache = {};

  /// Returns the layer named [name] under the current root, creating and
  /// caching it on first access. Use for project-specific layers
  /// (`LogLayer.layer('Payments')`) — unlisted names get a stable
  /// contrast-verified color from `LogPalette.hashPool`.
  static ChirpLogger layer(String name) {
    final ChirpLogger root;
    try {
      root = Chirp.root;
      // ignore: avoid_catching_errors -- rethrown with a package-level hint
    } on StateError {
      throw StateError(
        'Chirp.root is not configured. '
        'Call configureLogging() before accessing LogLayer.',
      );
    }
    if (!identical(root, _cachedRoot)) {
      _cache.clear();
      _cachedRoot = root;
    }
    return _cache.putIfAbsent(name, () => root.child(name: name));
  }
}
