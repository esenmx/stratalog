# stratalog_firebase_auth

FirebaseAuth integration for [stratalog](https://pub.dev/packages/stratalog) — taps FirebaseAuth into stratalog's colored, contrast-verified log layers.

```dart
FirebaseAuthLogger(FirebaseAuth.instance).attach(); // after Firebase.initializeApp
```

Sign-in/out with uid and identity providers — OAuth2 sign-ins (Google, Apple, OIDC) surface as their canonical provider IDs — plus ID-token refreshes at `trace`. Emails are masked; display names and photo URLs never logged.

See the [stratalog README](https://github.com/esenmx/stratalog) for the layer taxonomy, theming, and crash-reporting setup.
