# Maestro Mobile Testing: Setup & Best Practices

Maestro is a powerful, low-code automation tool for mobile apps. This guide captures practical lessons and best practices for setting up robust automation flows.

## 1. Quick Installation
To install Maestro on macOS:
```bash
curl -Ls "https://get.maestro.mobile.dev" | bash
export PATH="$PATH":"$HOME/.maestro/bin"
```
*Note: Add the export line to your `~/.zshrc` or `~/.bash_profile` to make the command available in every terminal session.*

## 2. Prerequisites (The "Gotchas")
*   **Active Device**: Maestro does **not** launch your emulator/simulator automatically. You must have one running.
*   **Device Status**: ADB can sometimes report devices as `offline`. A quick fix is:
    ```bash
    adb kill-server && adb start-server
    ```
*   **App Installation**: Maestro's `launchApp` command requires the app to already be installed on the device. For Flutter:
    1. Build the debug APK: `flutter build apk --debug`
    2. Install it: `adb install build/app/outputs/flutter-apk/app-debug.apk`

## 3. Robust Test Structure
A reliable test file (`.yaml`) handles app state and launch quirks gracefully.

### Basic Template
```yaml
appId: com.your.package.name
---
# 1. Launch with redundancy
- launchApp:
    clearState: true # Start fresh if possible
# - launchApp # Sometimes a second launch command helps if the first times out

# 2. Wait for stability
- waitForAnimationToEnd

# 3. Handle random popups (conditional flows)
- runFlow:
    when:
      visible: "Unlock Premium" # Example popup text
    commands:
      - tapOn: "No thanks"

# 4. Assert initial state
- assertVisible: "Home Screen Title"
```

## 4. Best Practices for Element Selection
*   **Regex for Dynamic Text**: Some widgets (like Flutter's `BottomNavigationBar`) add modifiers like "Tab 1 of 2" to labels. Use regex to stay flexible:
    ```yaml
    - tapOn: "Scroller.*" # Matches "Scroller" and "Scroller Tab 2 of 2"
    ```
*   **Explicit Gesture Coordinates**: Defaults like `direction: RIGHT` can be inconsistent across screen sizes or widget boundaries (like `Dismissible`). Use percentage-based coordinates for precision:
    ```yaml
    - swipe:
        start: 5%, 25% # Precise start (x, y)
        end: 95%, 25%   # Precise end (x, y)
    ```
*   **Wait for Content Load**: Don't just wait for animations; assert that your data has loaded before swiping or clicking:
    ```yaml
    - assertVisible: ".*ARTICLES AVAILABLE" # Check for a header that only appears after API success
    ```
*   **Key-Based Assertions**: Use `Key` in Flutter to mark internal states (like an "already read" icon) so you can verify transformations:
    *   *Flutter*: `Icon(Icons.check, key: Key('icon_read'))`
    *   *Maestro*: `assertVisible: { id: "icon_read" }`

## 5. Troubleshooting Launch & Execution
If `maestro test` fails to interacting with your app:
1.  **Manual Launch**: Open the app manually on the device first, then comment out `- launchApp` in your YAML to test interaction flows in isolation.
2.  **Force Stop & Clear**: Sometimes state persistence causes issues. Clear it via ADB before running:
    ```bash
    adb shell am force-stop <your.app.id> && adb shell pm clear <your.app.id>
    ```
6.  **Multiple Devices**: If multiple emulators are running, ADB and Maestro might get confused. Specify the device target:
    ```bash
    adb -s emulator-5554 <command>
    ```

### Debugging Artifacts
By default, Maestro saves screenshots and logs in `~/.maestro/tests/`. You can customize this location for easier access:
```bash
maestro test flow.yaml --test-output-dir ./maestro_artifacts
```

## 6. Project Checklist for New Apps
- [ ] Determine **App ID** (found in `android/app/build.gradle.kts` as `applicationId`).
- [ ] Start Emulator (e.g., `emulator -avd My_Device`).
- [ ] Build & Install Debug binary.
- [ ] Add explicit `Key`s to critical UI elements (BottomTabs, Action Buttons) for reliable testing.
- [ ] Create a `maestro/` directory and write your flows.
