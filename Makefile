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

start-android-auto:
	# Forward port and connect to phone emulator via TCP
	# Requires: phone emulator with Google Play + Android Auto app installed
	# Note: API 37+ emulators may have a non-functional Android Auto stub
	# Use an emulator with Google Play Services (API 33-35 recommended)
	adb forward tcp:5277 tcp:5277
	~/Library/Android/sdk/extras/google/auto/desktop-head-unit -c ./dhu/landscape.ini

start-android-automotive:
	# Launch on Android Automotive OS emulator
	# Requires: Automotive emulator (e.g. Automotive_1408p_landscape_with_Google_Play)
	# The app auto-detects AAOS and uses CarAppActivity for the template UI
	adb -s $$(adb devices | grep emulator | head -1 | cut -f1) install -r build/app/outputs/flutter-apk/app-debug.apk
