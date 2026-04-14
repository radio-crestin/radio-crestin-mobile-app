# Android Auto Debugging with DHU (Desktop Head Unit)

## Prerequisites

- Android Studio with SDK installed
- DHU installed: `sdkmanager "extras;google;auto"`
- An Android emulator with **Google Play** (API 33-35 recommended, API 37+ has broken AA stubs)

## One-time Setup

### 1. Create an emulator

Create a phone AVD with Google Play system image (e.g. Pixel 7 Pro, API 35):

```bash
sdkmanager "system-images;android-35;google_apis_playstore;arm64-v8a"
avdmanager create avd -n "Pixel_7_Pro_AA" -k "system-images;android-35;google_apis_playstore;arm64-v8a" -d "pixel_7_pro"
```

### 2. Boot the emulator and sign in to Google

Launch the emulator and sign in to a Google account (needed for Google Play Services).

### 3. Install Android Auto on the emulator

The Play Store marks Android Auto as incompatible with emulators, so we bundle the APK splits in this directory for sideloading:

```bash
make install-android-auto-emulator
```

This installs Android Auto and enables "unknown sources" so debug-signed apps appear in the AA launcher.

### 4. Enable Developer Mode in Android Auto

On the emulator:
1. Open **Settings > Connected devices > Connection preferences > Android Auto**
2. Scroll to the bottom and **tap the version number repeatedly** until developer mode is enabled

## Running

### Step 1: Start the head unit server

On the emulator, open Android Auto settings:
- Tap the **3-dot menu** (top right) > **"Start head unit server"**

> You must redo this after every emulator cold boot.

### Step 2: Install and run the app

```bash
flutter run -d emulator-5554
```

### Step 3: Launch the DHU

```bash
make start-android-auto
```

This forwards port 5277 from the emulator and launches the Desktop Head Unit with the landscape config.

The DHU window should connect and show the Android Auto interface. Open the app launcher (grid icon) to find Radio Crestin.

## Troubleshooting

| Problem | Solution |
|---------|----------|
| DHU says "waiting for phone" | Head unit server not running. Restart it from AA settings > 3-dot menu. |
| App not in DHU launcher | Run `adb -s emulator-5554 shell settings put secure android_auto_unknown_sources 1` and restart AA. |
| `adb forward` targets wrong device | Multiple devices connected. The Makefile auto-selects the first emulator. Disconnect physical device or use `-s emulator-5554` explicitly. |
| AA stub version (1.2.x-stub) | The pre-installed AA is a stub. Run `make install-android-auto-emulator` to sideload the full version. |
| Emulator doesn't have Google Play | Recreate with `google_apis_playstore` system image. Plain `google_apis` images lack Play Services. |

## Files in this directory

- `landscape.ini` / `portrait.ini` - DHU display configuration
- `android-auto-base.apk` + `split_config.*.apk` - Android Auto v16.6 APK splits for sideloading
- `README.md` - This file

## Reference

- [Running Android Auto on an Emulator](https://helw.net/2026/03/07/running-android-auto-on-an-emulator/)
- [Google DHU Documentation](https://developer.android.com/training/cars/testing)
