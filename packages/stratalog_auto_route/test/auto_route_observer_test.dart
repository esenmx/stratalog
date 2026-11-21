import 'package:auto_route/auto_route.dart';
import 'package:checks/checks.dart';
import 'package:chirp/chirp.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stratalog_auto_route/stratalog_auto_route.dart';

final class _TestRoute extends PageRouteBuilder<void> {
  new({String? name, Object? arguments})
    : super(
        settings: RouteSettings(name: name, arguments: arguments),
        pageBuilder: (context, animation, secondaryAnimation) =>
            const SizedBox.shrink(),
      );
}

TabPageRoute _tab(String name, {int index = 0}) => TabPageRoute(
  routeInfo: RouteMatch(
    config: AutoRoute(page: PageInfo(name, builder: (_) => const SizedBox())),
    segments: const [],
    stringMatch: '/$name',
    key: ValueKey(name),
  ),
  index: index,
);

void main() {
  late List<LogRecord> records;
  late AppRouterObserver observer;

  setUp(() {
    records = [];
    Chirp.root = ChirpLogger().addWriter(DelegatedChirpWriter(records.add));
    observer = AppRouterObserver();
  });

  tearDown(() => Chirp.root = null);

  Iterable<String> messages() => records.map((r) => '${r.message}');

  test('push, pop, remove, and replace format named and unnamed routes', () {
    final home = _TestRoute(name: 'HomeRoute');
    final detail = _TestRoute(name: 'DetailRoute', arguments: 'id: 42');
    final dialog = _TestRoute();

    observer
      ..didPush(home, null)
      ..didPush(detail, home)
      ..didPop(detail, home)
      ..didPop(home, null)
      ..didRemove(dialog, home)
      ..didReplace(oldRoute: home, newRoute: detail);

    check(messages()).deepEquals([
      'push{HomeRoute{}}',
      'push{DetailRoute{id: 42}}',
      'pop{DetailRoute{id: 42} => HomeRoute{}}',
      'pop{HomeRoute{}}',
      'remove{_TestRoute{}}',
      'replace{HomeRoute{} => DetailRoute{id: 42}}',
    ]);
  });

  test('replace with a missing side logs only the present route', () {
    observer
      ..didReplace(newRoute: _TestRoute(name: 'DetailRoute'))
      ..didReplace(oldRoute: _TestRoute(name: 'HomeRoute'))
      ..didReplace();

    check(messages()).deepEquals([
      'replace{DetailRoute{}}',
      'replace{HomeRoute{}}',
      'replace{}',
    ]);
  });

  test('tab init and change omit null previousRoute on initial mount', () {
    final feed = _tab('FeedRoute');
    final profile = _tab('ProfileRoute', index: 1);

    observer
      ..didInitTabRoute(feed, null)
      ..didChangeTabRoute(profile, feed);

    check(messages()).deepEquals([
      'initTab{FeedRoute}',
      'changeTab{FeedRoute => ProfileRoute}',
    ]);
  });

  test('tab init after a previous tab logs the transition', () {
    observer.didInitTabRoute(_tab('ProfileRoute', index: 1), _tab('FeedRoute'));

    check(messages().single).equals('initTab{FeedRoute => ProfileRoute}');
  });

  test('oversized route arguments are clipped by maxArgumentLength', () {
    AppRouterObserver(maxArgumentLength: 8)
        .didPush(_TestRoute(name: 'DetailRoute', arguments: 'x' * 40), null);

    check(messages().single).equals('push{DetailRoute{xxxxxxxx…(+32 chars)}}');
  });
}
