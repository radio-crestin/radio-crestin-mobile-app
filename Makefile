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

# Android Auto testing - requires DHU installed via Android Studio SDK Manager
# First: Enable Android Auto developer mode on phone, then "Start head unit server"
ANDROID_SDK_PATH ?= $(HOME)/Library/Android/sdk
android-auto-test:
	$(ANDROID_SDK_PATH)/platform-tools/adb forward tcp:5277 tcp:5277
	$(ANDROID_SDK_PATH)/extras/google/auto/desktop-head-unit
