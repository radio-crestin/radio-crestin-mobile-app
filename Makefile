install-deps:
	npm install -g get-graphql-schema

introspect-graphql:
	get-graphql-schema http://localhost:8080/v1/graphql > lib/schema.graphql

generate-graphql-types:
	dart run build_runner build

generate-launcher-icons:
	flutter pub run flutter_launcher_icons

generate-new-play-store-keystore:
	keytool -genkey -v -keystore ~/radio-crestin-app-keystore.jks -keyalg RSA -keysize 2048 -validity 10000 -alias upload

build-android-release:
	flutter build appbundle --release --no-tree-shake-icons

build-android-apk-release:
	flutter build apk --release --no-tree-shake-icons

start-android-auto-usb:
	# Connect your phone via USB (requires Android Auto app on phone)
	~/Library/Android/sdk/extras/google/auto/desktop-head-unit --usb -c ./dhu/landscape.ini

install-android-auto-emulator:
	# Install Android Auto APK on the emulator (bundled in dhu/ directory)
	# The Play Store shows AA as incompatible with emulators, so we sideload it
	adb -s $$(adb devices | grep emulator | head -1 | cut -f1) install-multiple \
		./dhu/android-auto-base.apk \
		./dhu/android-auto-split_config.arm64_v8a.apk \
		./dhu/android-auto-split_config.en.apk \
		./dhu/android-auto-split_config.xxhdpi.apk
	# Enable unknown sources so debug apps appear in Android Auto
	adb -s $$(adb devices | grep emulator | head -1 | cut -f1) shell settings put secure android_auto_unknown_sources 1

start-android-auto:
	# Forward port and connect to phone emulator via TCP
	# Requires: phone emulator with Google Play + Android Auto app installed
	# Note: API 37+ emulators may have a non-functional Android Auto stub
	# Use an emulator with Google Play Services (API 33-35 recommended)
	adb -s $$(adb devices | grep emulator | head -1 | cut -f1) forward tcp:5277 tcp:5277
	~/Library/Android/sdk/extras/google/auto/desktop-head-unit -c ./dhu/landscape.ini

start-carplay:
	# Launch CarPlay simulator (requires Xcode)
	# Opens the CarPlay Simulator from Xcode developer tools
	open /Applications/Xcode.app/Contents/Developer/Applications/Simulator.app
	@echo "In Simulator: I/O > External Displays > CarPlay"

start-android-automotive:
	# Launch on Android Automotive OS emulator
	# Requires: Automotive emulator (e.g. Automotive_1408p_landscape_with_Google_Play)
	# The app auto-detects AAOS and uses CarAppActivity for the template UI
	adb -s $$(adb devices | grep emulator | head -1 | cut -f1) install -r build/app/outputs/flutter-apk/app-debug.apk
