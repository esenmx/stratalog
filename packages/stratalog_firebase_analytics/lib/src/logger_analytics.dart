import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:stratalog/stratalog.dart';

/// Logging facade over [FirebaseAnalytics] — route your instrumentation
/// through it so every dispatched event also lands in the Analytics log
/// layer:
///
/// ```dart
/// final analytics = LoggerAnalytics(FirebaseAnalytics.instance);
/// await analytics.logEvent(name: 'checkout_started', parameters: {...});
/// ```
///
/// A facade (instead of an observer) because FirebaseAnalytics exposes no
/// stream of dispatched events to tap — mirroring has to happen on the way
/// in. Only the high-traffic surface is wrapped; anything else stays
/// reachable via [analytics].
final class LoggerAnalytics {
  /// Mirrors calls on [analytics] to [logger], typically
  /// `LogLayer.analytics`.
  const LoggerAnalytics(this.analytics, {this.logger = LogLayer.analytics});

  /// The wrapped instance — escape hatch for the unwrapped API surface.
  final FirebaseAnalytics analytics;

  /// Destination layer.
  final LogLayer logger;

  /// Mirrors [FirebaseAnalytics.logEvent].
  Future<void> logEvent({
    required String name,
    Map<String, Object>? parameters,
    AnalyticsCallOptions? callOptions,
  }) {
    logger.trace('event: $name', data: parameters);
    return analytics.logEvent(
      name: name,
      parameters: parameters,
      callOptions: callOptions,
    );
  }

  /// Mirrors [FirebaseAnalytics.logScreenView].
  Future<void> logScreenView({
    String? screenName,
    String? screenClass,
    Map<String, Object>? parameters,
  }) {
    logger.trace('screen: ${screenName ?? screenClass}', data: parameters);
    return analytics.logScreenView(
      screenName: screenName,
      screenClass: screenClass,
      parameters: parameters,
    );
  }

  /// Mirrors [FirebaseAnalytics.setUserId].
  Future<void> setUserId(String? id) {
    logger.trace(id == null ? 'user id cleared' : 'user id set');
    return analytics.setUserId(id: id);
  }

  /// Mirrors [FirebaseAnalytics.setUserProperty].
  Future<void> setUserProperty({required String name, String? value}) {
    logger.trace('user property: $name', data: {'value': value});
    return analytics.setUserProperty(name: name, value: value);
  }
}
