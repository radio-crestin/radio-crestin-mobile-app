SHELL := /bin/bash

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

# ============================================================================
# Local release pipeline — no CI, all signing on this machine.
#
# Two-host model:
#   On macOS:   make release-mac-platforms   (android + ios + macos + apple-tv)
#   On Windows: make release-windows         (Windows EXE zip)
# Then from either machine: make publish
#
# Stable artifact names enable the public download URL pattern:
#   https://github.com/<repo>/releases/latest/download/<filename>
# ============================================================================

DIST            ?= dist
PUBSPEC_VERSION := $(shell awk '/^version:/ {print $$2}' pubspec.yaml)
VERSION         := $(word 1,$(subst +, ,$(PUBSPEC_VERSION)))
BUILD_NUM       := $(word 2,$(subst +, ,$(PUBSPEC_VERSION)))
TAG             ?= v$(VERSION)
GH_REPO         ?= radio-crestin/radio-crestin-mobile-app

ANDROID_APK     := $(DIST)/radio-crestin-android.apk
ANDROID_AAB     := $(DIST)/radio-crestin-android.aab
IOS_IPA         := $(DIST)/radio-crestin-ios.ipa
MACOS_DMG       := $(DIST)/radio-crestin-macos.dmg
WINDOWS_ZIP     := $(DIST)/radio-crestin-windows.zip
APPLE_TV_IPA    := $(DIST)/radio-crestin-tvos.ipa
RELEASE_NOTES   := $(DIST)/RELEASE_NOTES.md

.PHONY: release-help print-version
release-help:
	@echo "Local release flow (no CI, no secrets in repo):"
	@echo
	@echo "  make print-version         show current pubspec version + tag"
	@echo "  make bump-build            1.5.0+77 -> 1.5.0+78"
	@echo "  make bump-patch            1.5.0+77 -> 1.5.1+78"
	@echo "  make bump-minor            1.5.0+77 -> 1.6.0+78"
	@echo
	@echo "  make release-android       APK + AAB        -> $(DIST)/"
	@echo "  make release-ios           ad-hoc IPA       -> $(DIST)/  (Xcode signing)"
	@echo "  make release-macos         unsigned DMG     -> $(DIST)/"
	@echo "  make release-apple-tv      tvOS IPA         -> $(DIST)/  (Xcode signing)"
	@echo "  make release-windows       EXE zip          -> $(DIST)/  (Windows host)"
	@echo
	@echo "  make release-mac-platforms android + ios + macos  (no apple-tv)"
	@echo "  make release-mac-platforms-with-tv   adds apple-tv  (needs ExportOptions.plist)"
	@echo "  make publish               create GH release for $(TAG), upload $(DIST)/*"
	@echo "  make release               bump + commit + build + tag + publish (Mac one-shot)"
	@echo "  make latest-links          print /releases/latest/download/* URLs"
	@echo "  make clean-release         remove $(DIST)/ + flutter clean"

print-version:
	@echo "version=$(VERSION)  build=$(BUILD_NUM)  tag=$(TAG)"

$(DIST):
	@mkdir -p $(DIST)

# ----- Android ---------------------------------------------------------------
.PHONY: release-android
release-android: | $(DIST)
	flutter build apk --release --no-tree-shake-icons
	flutter build appbundle --release --no-tree-shake-icons
	cp build/app/outputs/flutter-apk/app-release.apk $(ANDROID_APK)
	cp build/app/outputs/bundle/release/app-release.aab $(ANDROID_AAB)
	@ls -lh $(ANDROID_APK) $(ANDROID_AAB)

# ----- iOS (ad-hoc IPA for GitHub Release distribution) ----------------------
.PHONY: release-ios
release-ios: | $(DIST)
	flutter build ipa --release --export-method=ad-hoc --no-tree-shake-icons
	@ipa="$$(ls -t build/ios/ipa/*.ipa 2>/dev/null | head -1)"; \
	  [ -n "$$ipa" ] || { echo "ERROR: no IPA produced — check Xcode signing config"; exit 1; }; \
	  cp "$$ipa" $(IOS_IPA); \
	  ls -lh $(IOS_IPA)

# ----- macOS DMG -------------------------------------------------------------
# TODO: codesign + xcrun notarytool to avoid Gatekeeper warning on download.
.PHONY: release-macos
release-macos: | $(DIST)
	flutter build macos --release
	@app="$$(ls -d build/macos/Build/Products/Release/*.app 2>/dev/null | head -1)"; \
	  [ -n "$$app" ] || { echo "ERROR: macOS .app not found in build/macos/Build/Products/Release"; exit 1; }; \
	  rm -f $(MACOS_DMG); \
	  hdiutil create -volname "Radio Crestin" -srcfolder "$$app" \
	    -format UDZO -ov $(MACOS_DMG)
	@ls -lh $(MACOS_DMG)

# ----- Windows (run on a Windows host with Flutter desktop enabled) ---------
.PHONY: release-windows
release-windows: | $(DIST)
	@case "$$(uname -s 2>/dev/null || echo Windows)" in \
	  MINGW*|MSYS*|CYGWIN*|Windows*) ;; \
	  *) echo "ERROR: release-windows must run on a Windows host (Flutter cannot cross-build .exe)"; exit 1 ;; \
	esac
	flutter build windows --release
	@cd build/windows/x64/runner && rm -f "../../../../$(WINDOWS_ZIP)" && \
	  powershell -NoProfile -Command "Compress-Archive -Path Release\\* -DestinationPath '../../../../$(WINDOWS_ZIP)' -Force"
	@ls -lh $(WINDOWS_ZIP)

# ----- Apple TV (native SwiftUI, separate Xcode project) --------------------
# Requires apple_tv/ExportOptions.plist (see README).
.PHONY: release-apple-tv
release-apple-tv: | $(DIST)
	@[ -f apple_tv/ExportOptions.plist ] || { \
	  echo "ERROR: apple_tv/ExportOptions.plist missing. See README — Apple TV release."; \
	  exit 1; }
	xcodebuild -project apple_tv/RadioCrestinTV.xcodeproj \
	  -scheme RadioCrestinTV -configuration Release \
	  -destination "generic/platform=tvOS" \
	  -archivePath build/apple_tv/RadioCrestinTV.xcarchive \
	  archive
	xcodebuild -exportArchive \
	  -archivePath build/apple_tv/RadioCrestinTV.xcarchive \
	  -exportPath build/apple_tv/export \
	  -exportOptionsPlist apple_tv/ExportOptions.plist
	@cp build/apple_tv/export/*.ipa $(APPLE_TV_IPA)
	@ls -lh $(APPLE_TV_IPA)

# ----- Aggregate (Mac host) --------------------------------------------------
# Default does not include apple-tv (needs apple_tv/ExportOptions.plist
# and a different signing context). Run `make release-apple-tv` separately
# when the tvOS app needs to ship.
.PHONY: release-mac-platforms release-mac-platforms-with-tv
release-mac-platforms: release-android release-ios release-macos
	@ls -la $(DIST)

release-mac-platforms-with-tv: release-mac-platforms release-apple-tv
	@ls -la $(DIST)

# ----- Release notes ---------------------------------------------------------
$(RELEASE_NOTES): | $(DIST)
	@last=$$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null || true); \
	  { \
	    if [ -n "$$last" ] && [ "$$last" != "$(TAG)" ]; then \
	      printf "## Changes since %s\n\n" "$$last"; \
	      git log --pretty='- %s' "$$last"..HEAD; \
	    else \
	      printf "## Changes\n\n"; \
	      git log --pretty='- %s' -50; \
	    fi; \
	    printf "\n\n## Downloads\n\n"; \
	    base="https://github.com/$(GH_REPO)/releases/download/$(TAG)"; \
	    printf -- "- Android APK: %s/%s\n"   "$$base" "$$(basename $(ANDROID_APK))"; \
	    printf -- "- Android AAB: %s/%s\n"   "$$base" "$$(basename $(ANDROID_AAB))"; \
	    printf -- "- iOS IPA: %s/%s\n"       "$$base" "$$(basename $(IOS_IPA))"; \
	    printf -- "- macOS DMG: %s/%s\n"     "$$base" "$$(basename $(MACOS_DMG))"; \
	    printf -- "- Windows zip: %s/%s\n"   "$$base" "$$(basename $(WINDOWS_ZIP))"; \
	    printf -- "- Apple TV IPA: %s/%s\n"  "$$base" "$$(basename $(APPLE_TV_IPA))"; \
	  } > $(RELEASE_NOTES)
	@cat $(RELEASE_NOTES)

.PHONY: release-notes
release-notes: $(RELEASE_NOTES)

# ----- Tag + push (idempotent) ----------------------------------------------
.PHONY: tag-release
tag-release:
	@if git rev-parse --verify -q $(TAG) >/dev/null; then \
	  echo "tag $(TAG) already exists, skipping"; \
	else \
	  git tag -a $(TAG) -m "Release $(TAG)" && git push origin $(TAG); \
	fi

# ----- Publish: create or reuse GH release, upload anything in $(DIST) ------
.PHONY: publish
publish: release-notes
	@command -v gh >/dev/null || { echo "ERROR: gh CLI required (brew install gh)"; exit 1; }
	@gh auth status >/dev/null 2>&1 || { echo "ERROR: gh not authenticated (run: gh auth login)"; exit 1; }
	@if ! gh release view $(TAG) -R $(GH_REPO) >/dev/null 2>&1; then \
	  gh release create $(TAG) -R $(GH_REPO) \
	    --title "Radio Crestin $(TAG)" \
	    --notes-file $(RELEASE_NOTES); \
	else \
	  echo "release $(TAG) already exists — uploading artifacts"; \
	fi
	@for f in $(ANDROID_APK) $(ANDROID_AAB) $(IOS_IPA) $(MACOS_DMG) $(WINDOWS_ZIP) $(APPLE_TV_IPA); do \
	  if [ -f "$$f" ]; then \
	    echo "↑ $$f"; \
	    gh release upload $(TAG) -R $(GH_REPO) "$$f" --clobber; \
	  else \
	    echo "skip (missing): $$f"; \
	  fi; \
	done
	@echo
	@echo "Published: https://github.com/$(GH_REPO)/releases/tag/$(TAG)"

# ----- One-shot Mac release --------------------------------------------------
# Each step re-runs make so PUBSPEC_VERSION re-evaluates after bump-build,
# and the version commit lands BEFORE tag-release so the tag points at the
# right pubspec — otherwise the tag would still reference 1.5.0+77 while the
# built APK is 1.5.0+78.
.PHONY: release commit-version
release:
	$(MAKE) bump-build
	$(MAKE) commit-version
	$(MAKE) release-mac-platforms
	$(MAKE) tag-release
	$(MAKE) publish
	@echo "Release done"

commit-version:
	@if git diff --quiet -- pubspec.yaml; then \
	  echo "pubspec.yaml unchanged, skipping version commit"; \
	else \
	  cur="$(PUBSPEC_VERSION)"; \
	  git add pubspec.yaml && \
	  git commit -m "chore: release v$${cur%+*} ($$cur)" && \
	  git push origin HEAD; \
	fi

# ----- Cleanup ---------------------------------------------------------------
.PHONY: clean-dist clean-release
clean-dist:
	rm -rf $(DIST)

clean-release: clean-dist
	rm -rf build/macos build/ios/ipa build/apple_tv build/windows
	flutter clean

# ----- Latest-release links (for README, share copy, etc.) ------------------
.PHONY: latest-links
latest-links:
	@base="https://github.com/$(GH_REPO)/releases/latest/download"; \
	  echo "Android APK:   $$base/$$(basename $(ANDROID_APK))"; \
	  echo "Android AAB:   $$base/$$(basename $(ANDROID_AAB))"; \
	  echo "iOS IPA:       $$base/$$(basename $(IOS_IPA))"; \
	  echo "macOS DMG:     $$base/$$(basename $(MACOS_DMG))"; \
	  echo "Windows zip:   $$base/$$(basename $(WINDOWS_ZIP))"; \
	  echo "Apple TV IPA:  $$base/$$(basename $(APPLE_TV_IPA))"; \
	  echo "Release page:  https://github.com/$(GH_REPO)/releases/latest"

# ----- Version bumps ---------------------------------------------------------
.PHONY: bump-build bump-patch bump-minor
bump-build:
	@cur="$(PUBSPEC_VERSION)"; \
	  ver=$${cur%+*}; build=$${cur#*+}; new=$$((build+1)); \
	  sed -i.bak -E "s/^version: $$cur$$/version: $$ver+$$new/" pubspec.yaml && rm -f pubspec.yaml.bak; \
	  echo "version: $$ver+$$new"

bump-patch:
	@cur="$(PUBSPEC_VERSION)"; \
	  ver=$${cur%+*}; build=$${cur#*+}; \
	  newver=$$(echo "$$ver" | awk -F. '{print $$1 "." $$2 "." $$3+1}'); \
	  newbuild=$$((build+1)); \
	  sed -i.bak -E "s/^version: $$cur$$/version: $$newver+$$newbuild/" pubspec.yaml && rm -f pubspec.yaml.bak; \
	  echo "version: $$newver+$$newbuild"

bump-minor:
	@cur="$(PUBSPEC_VERSION)"; \
	  ver=$${cur%+*}; build=$${cur#*+}; \
	  newver=$$(echo "$$ver" | awk -F. '{print $$1 "." $$2+1 ".0"}'); \
	  newbuild=$$((build+1)); \
	  sed -i.bak -E "s/^version: $$cur$$/version: $$newver+$$newbuild/" pubspec.yaml && rm -f pubspec.yaml.bak; \
	  echo "version: $$newver+$$newbuild"
