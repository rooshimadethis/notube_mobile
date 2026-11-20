# NoTube Mobile

## ✨ Feature Overview

- **Cross‑platform Flutter app** mirroring the NoTube Chrome extension functionality.
- **Firebase Auth & Firestore sync** for seamless storage of curated and user‑added alternatives.
- **Offline caching** ensures the app works without network connectivity.
- **AI‑generated descriptions** for custom sites via a Cloudflare worker (Groq API).
- **Robust sync logic** using Firestore transactions to avoid race conditions.
- **Shared library (`notube_shared`)** provides common models and default alternatives.
- **Reading list** opens with up to 12 mixed picks from RSS and Atom feeds. Use **More picks** for another batch or **All articles** for the full timeline from followed sources.
- **Discover** lets you browse unfollowed publishers from the bundled OPML catalog, preview their articles, and follow them to add their posts to **Read**. **Sources → Add source** accepts a direct feed or a website that advertises its feeds. Sources and article read history are stored on the device.
- The [Kagi Small Web directory](https://github.com/kagisearch/smallweb) supplies a daily batch of up to five independent publishers in **Discover**. NoTube checks the feeds and keeps the last batch available offline.
- NoTube defaults to a high-contrast light theme. The **Dark mode** switch in **Settings** saves the choice on the device.
- **Gratitude Journal** is a toggleable prompt on the **Saved sites** tab.

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
