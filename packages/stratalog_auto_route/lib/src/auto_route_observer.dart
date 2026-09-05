import 'package:auto_route/auto_route.dart';
import 'package:flutter/widgets.dart';
import 'package:stratalog/stratalog.dart';

/// Central `auto_route` observability.
///
/// ```dart
/// MaterialApp.router(
///   routerConfig: router.config(
///     navigatorObservers: () => [AppRouterObserver()],
///   ),
/// )
/// ```
final class AppRouterObserver({
  /// Destination layer.
  final LogLayer logger = .route,
}) extends AutoRouterObserver {
  /// Logs every navigation event to [logger], typically `LogLayer.route`.
  this;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    logger.trace('push{${route.definition}}');
    super.didPush(route, previousRoute);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    logger.trace('pop{${previousRoute?.definition}}');
    super.didPop(route, previousRoute);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    logger.trace('remove{${route.definition}}');
    super.didRemove(route, previousRoute);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    logger.trace('replace{${newRoute?.definition}}');
    super.didReplace(newRoute: newRoute, oldRoute: oldRoute);
  }

  @override
  void didInitTabRoute(TabPageRoute route, TabPageRoute? previousRoute) {
    logger.trace('initTab{${previousRoute?.name} => ${route.name}}');
    super.didInitTabRoute(route, previousRoute);
  }

  @override
  void didChangeTabRoute(TabPageRoute route, TabPageRoute previousRoute) {
    logger.trace('changeTab{${previousRoute.name} => ${route.name}}');
    super.didChangeTabRoute(route, previousRoute);
  }
}

extension<T> on Route<T> {
  String get definition => '${settings.name}{${settings.arguments ?? ''}}';
}
