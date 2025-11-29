# NoTube Mobile

## ✨ Feature Overview

- **Cross‑platform Flutter app** mirroring the NoTube Chrome extension functionality.
- **Firebase Auth & Firestore sync** for seamless storage of curated and user‑added alternatives.
- **Offline caching** ensures the app works without network connectivity.
- **AI‑generated descriptions** for custom sites via a Cloudflare worker (Groq API).
- **Robust sync logic** using Firestore transactions to avoid race conditions.
- **Shared library (`notube_shared`)** provides common models and default alternatives.

## 🛠️ Implementation Highlights

- State management with **Riverpod** and immutable data classes via **freezed**.
- **Firestore transactions** guarantee atomic updates when merging local and cloud data.
- Edge‑secure **Cloudflare worker** proxies Groq API calls, keeping keys out of the client.
- **Unit & widget tests** integrated via `flutter_test` for core sync and UI components.

## 🚀 Quick Start

```bash
# Install dependencies
flutter pub get

# Run analysis (ensures code quality)
flutter analyze

# Launch the app (optional)
flutter run
```

*The app is ready to be built and deployed to iOS/Android.*
