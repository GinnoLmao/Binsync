# Quick Start Guide

## Installation

### Prerequisites
1. Install Flutter SDK: https://flutter.dev/docs/get-started/install
2. Set up an IDE (VS Code or Android Studio)
3. Set up Android/iOS emulator or connect a physical device

### Setup Steps

```bash
# 1. Clone the repository
git clone https://github.com/DukeZyke/Binsync.git
cd Binsync

# 2. Install dependencies
flutter pub get

# 3. Check for any issues
flutter doctor

# 4. Run the app
flutter run
```

## First Time Setup

If you're new to Flutter development:

1. **Install Flutter**
   - Follow the official guide: https://docs.flutter.dev/get-started/install
   - Verify installation: `flutter doctor`

2. **Set up an Editor**
   - VS Code with Flutter extension (recommended)
   - Or Android Studio with Flutter plugin

3. **Set up Device**
   - Android: Set up Android Studio and create an AVD (Android Virtual Device)
   - iOS (Mac only): Install Xcode and set up iOS Simulator
   - Web: Chrome browser (included with Flutter)

## Running the App

### On Android Emulator
```bash
# Start emulator from Android Studio or command line
flutter emulators --launch <emulator_id>

# Run app
flutter run
```

### On iOS Simulator (Mac only)
```bash
# Open simulator
open -a Simulator

# Run app
flutter run
```

### On Web
```bash
flutter run -d chrome
```

### On Physical Device
```bash
# Enable USB debugging on Android device
# Connect device via USB
# Run app
flutter run
```

## App Features

Once the app is running, you can:

1. **View the Map**: OpenStreetMap loads with San Francisco as default location
2. **Add Markers**: Tap anywhere on the map to add a garbage bin marker
3. **Zoom**: Use + and - floating buttons to zoom in/out
4. **Reset**: Tap location icon in app bar to reset to default view
5. **Clear**: Tap clear button to remove all added markers

## Customization

### Change Default Location

Edit `lib/main.dart`:
```dart
final LatLng _initialCenter = LatLng(YOUR_LATITUDE, YOUR_LONGITUDE);
```

### Change App Name

Edit `pubspec.yaml`:
```yaml
name: your_app_name
description: Your app description
```

Also update:
- `android/app/src/main/AndroidManifest.xml` (android:label)
- `ios/Runner/Info.plist` (CFBundleDisplayName)

## Troubleshooting

### "flutter: command not found"
- Add Flutter to your PATH
- Restart terminal/IDE after installation

### "No devices found"
- Ensure emulator/simulator is running
- Check device connection: `flutter devices`

### Map tiles not loading
- Check internet connection
- On Android emulator, ensure it has internet access

### Build errors
```bash
flutter clean
flutter pub get
flutter run
```

## Next Steps

After getting the app running:

1. Read `DOCUMENTATION.md` for detailed architecture info
2. Explore `lib/main.dart` to understand the code
3. Modify marker colors and icons
4. Add your own features
5. Deploy to app stores

## Support

For issues or questions:
- Check Flutter documentation: https://docs.flutter.dev/
- flutter_map package: https://pub.dev/packages/flutter_map
- OpenStreetMap: https://www.openstreetmap.org/

## Development Commands

```bash
# Run tests
flutter test

# Analyze code
flutter analyze

# Format code
flutter format lib/

# Build APK (Android)
flutter build apk --release

# Build iOS (Mac only)
flutter build ios --release

# Build Web
flutter build web --release
```
