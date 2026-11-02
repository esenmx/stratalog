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

  /// Route `settings.arguments` `toString()`s beyond this length are
  /// ellipsized so large route argument objects never flood the console.
  /// Set `null` to disable.
  final int? maxArgumentLength = 200,
}) extends AutoRouterObserver {
  /// Logs every navigation event to [logger], typically `LogLayer.route`.
  this;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    logger.trace('push{${_describe(route)}}');
    super.didPush(route, previousRoute);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    final target = previousRoute == null
        ? _describe(route)
        : '${_describe(route)} => ${_describe(previousRoute)}';
    logger.trace('pop{$target}');
    super.didPop(route, previousRoute);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    logger.trace('remove{${_describe(route)}}');
    super.didRemove(route, previousRoute);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    final target = switch ((oldRoute, newRoute)) {
      (final oldR?, final newR?) => '${_describe(oldR)} => ${_describe(newR)}',
      (null, final newR?) => _describe(newR),
      (final oldR?, null) => _describe(oldR),
      (null, null) => '',
    };
    logger.trace('replace{$target}');
    super.didReplace(newRoute: newRoute, oldRoute: oldRoute);
  }

  @override
  void didInitTabRoute(TabPageRoute route, TabPageRoute? previousRoute) {
    final transition = previousRoute == null
        ? route.name
        : '${previousRoute.name} => ${route.name}';
    logger.trace('initTab{$transition}');
    super.didInitTabRoute(route, previousRoute);
  }

  @override
  void didChangeTabRoute(TabPageRoute route, TabPageRoute previousRoute) {
    logger.trace('changeTab{${previousRoute.name} => ${route.name}}');
    super.didChangeTabRoute(route, previousRoute);
  }

  String _describe(Route<dynamic> route) {
    final name = route.settings.name ?? '${route.runtimeType}';
    final rawArgs = route.settings.arguments;
    if (rawArgs == null) return '$name{}';
    final max = maxArgumentLength;
    final args = max == null ? '$rawArgs' : clipString('$rawArgs', max);
    return '$name{$args}';
  }
}
