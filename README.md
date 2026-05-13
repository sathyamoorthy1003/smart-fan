# Smart Fan 🌀

A Flutter + ESP32 IoT smart fan controller with Firebase cloud synchronization.

## Features
- **Auto Mode** — PIR motion-based fan speed control
- **Manual / Travel / Office / Night Modes** — preset speed profiles
- **Mist Control** — 3-level mist (OFF → LOW → ALL) via MIST+ / MIST- commands
- **Swing Control** — manual multi-point swing (LEFT ↔ CENTER ↔ RIGHT)
- **Light Toggle** — remote light on/off
- **Real-time sync** — Firebase Firestore streams live sensor data (temperature, PIR, uptime)
- **Theme switching** — Light mode (day) & Night mode (dark) auto-switches based on fan mode

## Project Structure
```
fan/
├── smart/              # ESP32 Arduino firmware (.ino)
└── smart_fan_app/      # Flutter mobile app
    ├── lib/
    │   ├── main.dart               # App entry, auth gate, theme
    │   └── screens/
    │       ├── dashboard_screen.dart   # Main control UI
    │       └── pairing_screen.dart     # Device pairing UI
    └── android/                    # Android platform files
```

## Tech Stack
- **Firmware** — Arduino (ESP32), WiFi, Firebase REST API
- **App** — Flutter 3.x, Dart
- **Backend** — Firebase Firestore (real-time), Firebase Auth (anonymous)
- **Renderer** — Skia (Impeller disabled for compatibility)

## Setup
1. Flash `smart/smart.ino` to your ESP32 with your WiFi + Firebase credentials
2. Run `flutter pub get` inside `smart_fan_app/`
3. Add your `google-services.json` to `smart_fan_app/android/app/`
4. Run `flutter run` or build APK with `flutter build apk`
