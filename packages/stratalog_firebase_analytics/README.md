# stratalog_firebase_analytics

FirebaseAnalytics integration for [stratalog](https://pub.dev/packages/stratalog).

```dart
final analytics = LoggerAnalytics(FirebaseAnalytics.instance);
await analytics.logEvent(name: 'checkout_started');
```

A facade rather than an observer — FirebaseAnalytics exposes no stream of dispatched events, so mirroring happens on the way in. Wraps `logEvent`, `logScreenView`, `setUserId` (presence-only, never the value), and `setUserProperty`; everything else stays reachable via `.analytics`.

See the [stratalog README](https://github.com/esenmx/stratalog) for the layer taxonomy and theming.
