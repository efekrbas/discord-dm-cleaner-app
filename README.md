# Discord DM Cleaner (Flutter)

Minimal Flutter port that provides a login-by-token screen, DM list display, and basic deletion flow.

Important: Using user tokens with the Discord API may violate their terms and can lead to account action. Use at your own risk.

Quick start:

1. Install Flutter: https://flutter.dev/docs/get-started/install
2. From this folder run:

```bash
flutter pub get
flutter run
```

Notes:
- The app uses the `http` package to call the Discord API directly with the provided token.
- Mobile (Android/iOS) or desktop targets should work; ensure networking is allowed on the target.
