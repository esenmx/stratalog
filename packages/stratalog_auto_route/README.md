# stratalog_auto_route

auto_route integration for [stratalog](https://pub.dev/packages/stratalog) — taps auto_route into stratalog's colored, contrast-verified log layers.

```dart
router.config(navigatorObservers: () => [AppRouterObserver(LogLayer.route)]);
```

Pushes, pops, replaces, and tab changes with route names and arguments.

See the [stratalog README](https://github.com/esenmx/stratalog) for the layer taxonomy, theming, and crash-reporting setup.
