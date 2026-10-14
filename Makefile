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

ANDROID_APK         := $(DIST)/radio-crestin-android.apk
ANDROID_AAB         := $(DIST)/radio-crestin-android.aab
IOS_IPA             := $(DIST)/radio-crestin-ios.ipa
IOS_APPSTORE_IPA    := $(DIST)/radio-crestin-ios-appstore.ipa
IOS_ARCHIVE         := build/ios/archive/Runner.xcarchive
MACOS_DMG           := $(DIST)/radio-crestin-macos.dmg
WINDOWS_ZIP         := $(DIST)/radio-crestin-windows.zip
APPLE_TV_IPA        := $(DIST)/radio-crestin-tvos.ipa
RELEASE_NOTES       := $(DIST)/RELEASE_NOTES.md

# Store-upload credentials are read from 1Password (never committed).
# See README "Store uploads" for setup.
OP_VAULT            := radio-crestin-app
APPSTORE_KEY_FILE   := /tmp/radio-crestin-appstore-key.p8
PLAY_JSON_FILE      := /tmp/radio-crestin-play-key.json

# PostHog Error Tracking: iOS dSYMs, so native crashes symbolicate.
# Auth once per machine: posthog-cli --host $(POSTHOG_HOST) login
# (or export POSTHOG_CLI_API_KEY + POSTHOG_CLI_PROJECT_ID). See README.
POSTHOG_HOST        := https://eu.posthog.com
IOS_BUNDLE_ID       := com.radiocrestinsoftware.radioApp
IOS_DSYMS_DIR       := build/ios/archive/Runner.xcarchive/dSYMs
IOS_DSYMS_STAGE     := build/ios/posthog-dsyms

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
	@echo "  make release-ios-appstore  app-store IPA (for TestFlight) -> $(DIST)/"
	@echo "  make release-mac-platforms android + ios + macos + apple-tv"
	@echo "  make publish               create GH PRERELEASE for $(TAG), upload $(DIST)/*"
	@echo "  make promote               flip $(TAG) from prerelease -> latest (public)"
	@echo "  make release               bump + commit + build + tag + publish (prerelease)"
	@echo
	@echo "  make upload-testflight     send app-store IPA to TestFlight (API key: 1Password + fastlane)"
	@echo "  make upload-testflight-xcode  send the iOS archive to TestFlight as the Xcode account"
	@echo "  make upload-play-internal  send AAB to Play Store internal testing track"
	@echo "  make upload-stores         upload-testflight + upload-play-internal"
	@echo "  make release-stores        bump build + commit (no push) + app-store IPA + AAB + upload both"
	@echo "  make upload-dsyms-ios      iOS dSYMs -> PostHog (auto after release-ios*)"
	@echo
	@echo "  make deploy-ios            build +1, fresh app-store IPA -> TestFlight via Xcode account"
	@echo "  make deploy-android        build +1, fresh AAB -> Play internal testing, as a draft"
	@echo "  make deploy                build +1 once, then both (same +N on both stores)"
	@echo "                             after the upload, commit the new version (no push)"
	@echo "                             NO_BUMP=1 keeps the build number (retry, other platform)"
	@echo "                             (refuse uncommitted changes; ALLOW_DIRTY=1 skips)"
	@echo
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
	@$(MAKE) --no-print-directory upload-dsyms-ios \
	  || echo "WARNING: dSYM upload to PostHog failed — native iOS crashes won't symbolicate. Retry: make upload-dsyms-ios"

# ----- iOS (app-store IPA for TestFlight upload) -----------------------------
.PHONY: release-ios-appstore
release-ios-appstore: | $(DIST)
	flutter build ipa --release --export-method=app-store --no-tree-shake-icons
	@ipa="$$(ls -t build/ios/ipa/*.ipa 2>/dev/null | head -1)"; \
	  [ -n "$$ipa" ] || { echo "ERROR: app-store IPA not produced — check Xcode signing"; exit 1; }; \
	  cp "$$ipa" $(IOS_APPSTORE_IPA); \
	  ls -lh $(IOS_APPSTORE_IPA)
	@$(MAKE) --no-print-directory upload-dsyms-ios \
	  || echo "WARNING: dSYM upload to PostHog failed — native iOS crashes won't symbolicate. Retry: make upload-dsyms-ios"

# ----- iOS dSYMs -> PostHog Error Tracking -----------------------------------
# Runs after release-ios / release-ios-appstore; a failure there only warns,
# it never blocks a release. Uploads every dSYM in the archive that
# `flutter build ipa` just produced, tagged with the pubspec version + build.
# The archive repeats some dSYMs as "X 1.dSYM" copies (same UUID), which
# PostHog rejects, so one bundle per UUID is staged first.
.PHONY: upload-dsyms-ios
upload-dsyms-ios:
	@command -v posthog-cli >/dev/null || { echo "ERROR: posthog-cli required: brew install posthog/tap/posthog-cli, then: posthog-cli --host $(POSTHOG_HOST) login"; exit 1; }
	@[ -d "$(IOS_DSYMS_DIR)" ] || { echo "ERROR: no dSYMs in $(IOS_DSYMS_DIR) — run make release-ios-appstore first"; exit 1; }
	@scripts/stage_unique_dsyms.sh "$(IOS_DSYMS_DIR)" "$(IOS_DSYMS_STAGE)"
	posthog-cli --host $(POSTHOG_HOST) dsym upload \
	  --directory "$(IOS_DSYMS_STAGE)" \
	  --main-dsym Runner.app.dSYM \
	  --release-name $(IOS_BUNDLE_ID) \
	  --release-version $(VERSION) \
	  --build $(BUILD_NUM) \
	  --skip-on-conflict

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
	  -allowProvisioningUpdates \
	  archive
	xcodebuild -exportArchive \
	  -archivePath build/apple_tv/RadioCrestinTV.xcarchive \
	  -exportPath build/apple_tv/export \
	  -exportOptionsPlist apple_tv/ExportOptions.plist \
	  -allowProvisioningUpdates
	@cp build/apple_tv/export/*.ipa $(APPLE_TV_IPA)
	@ls -lh $(APPLE_TV_IPA)

# ----- Aggregate (Mac host) --------------------------------------------------
# Includes apple-tv. Requires apple_tv/ExportOptions.plist (committed to
# the repo with the team ID — adjust there if you change export method).
.PHONY: release-mac-platforms
release-mac-platforms: release-android release-ios release-macos release-apple-tv
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
# Created as a PRERELEASE by default — devs can pull it via the tag URL but
# it's not exposed at /releases/latest until `make promote` is run.
.PHONY: publish
publish: release-notes
	@command -v gh >/dev/null || { echo "ERROR: gh CLI required (brew install gh)"; exit 1; }
	@gh auth status >/dev/null 2>&1 || { echo "ERROR: gh not authenticated (run: gh auth login)"; exit 1; }
	@if ! gh release view $(TAG) -R $(GH_REPO) >/dev/null 2>&1; then \
	  gh release create $(TAG) -R $(GH_REPO) \
	    --title "Radio Crestin $(TAG)" \
	    --notes-file $(RELEASE_NOTES) \
	    --prerelease; \
	else \
	  echo "release $(TAG) already exists — uploading artifacts"; \
	fi
	@for f in $(ANDROID_APK) $(ANDROID_AAB) $(IOS_IPA) $(MACOS_DMG) $(WINDOWS_ZIP) $(APPLE_TV_IPA); do \
	  if [ -f "$$f" ]; then \
	    echo "uploading $$f"; \
	    gh release upload $(TAG) -R $(GH_REPO) "$$f" --clobber; \
	  else \
	    echo "skip (missing): $$f"; \
	  fi; \
	done
	@echo
	@echo "Prerelease (devs only): https://github.com/$(GH_REPO)/releases/tag/$(TAG)"
	@echo "Run 'make promote' to publish to /releases/latest."

# ----- Promote: flip prerelease off so /releases/latest serves this build ---
.PHONY: promote
promote:
	@command -v gh >/dev/null || { echo "ERROR: gh CLI required"; exit 1; }
	@gh release view $(TAG) -R $(GH_REPO) >/dev/null 2>&1 || { \
	  echo "ERROR: release $(TAG) not found — run 'make publish' first"; exit 1; }
	gh release edit $(TAG) -R $(GH_REPO) --prerelease=false --latest
	@echo "Promoted to latest: https://github.com/$(GH_REPO)/releases/latest"

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

# ----- One-shot store release (TestFlight + Play internal) -------------------
# Every store upload needs a higher build number than the last one, so this
# bumps it once for both stores (iOS and Android ship the same +N), commits
# the bump (not pushed — push when you choose), then builds and uploads.
# Steps re-run make so the builds see the bumped pubspec. If an upload fails
# after the bump, retry with `make upload-stores` (no second bump). The Apple
# TV app keeps its own build number in apple_tv/RadioCrestinTV/Info.plist.
.PHONY: release-stores commit-build-number
release-stores:
	@git diff --quiet -- pubspec.yaml || { \
	  echo "ERROR: pubspec.yaml has uncommitted changes — commit or stash them first"; \
	  exit 1; }
	$(MAKE) bump-build
	$(MAKE) commit-build-number
	$(MAKE) release-ios-appstore release-android
	$(MAKE) upload-stores
	@echo "Store release done: $$(grep '^version:' pubspec.yaml)"

commit-build-number:
	@cur="$(PUBSPEC_VERSION)"; branch="$$(git rev-parse --abbrev-ref HEAD)"; \
	  git add pubspec.yaml && \
	  git commit -m "[$$branch] - bumped build number to $$cur"

# ----- Store uploads (App Store TestFlight + Play Store internal) ----------
# Credentials are pulled from 1Password at upload time, written to /tmp,
# consumed by fastlane, and deleted on exit. Nothing lands in the repo.
#
# 1Password items expected in vault `$(OP_VAULT)`:
#   - appstore_connect_api_key.p8     (secure note: paste the .p8 contents)
#   - appstore_connect_key_id          (secure note: 10-char Key ID)
#   - appstore_connect_issuer_id       (secure note: UUID Issuer ID)
#   - play_service_account.json        (secure note: paste the JSON)
#
# See README "Store uploads" for how to generate these.
.PHONY: upload-testflight upload-play-internal upload-stores

upload-testflight: $(IOS_APPSTORE_IPA)
	@command -v op >/dev/null || { echo "ERROR: 1Password CLI required (brew install 1password-cli)"; exit 1; }
	@command -v bundle >/dev/null || { echo "ERROR: bundler required"; exit 1; }
	@op read "op://$(OP_VAULT)/appstore_connect_api_key.p8/notesPlain" > $(APPSTORE_KEY_FILE) 2>/dev/null \
	  || { echo "ERROR: 1Password item appstore_connect_api_key.p8 not found in $(OP_VAULT)"; exit 1; }
	@key_id="$$(op read 'op://$(OP_VAULT)/appstore_connect_key_id/notesPlain' 2>/dev/null)"; \
	 issuer="$$(op read 'op://$(OP_VAULT)/appstore_connect_issuer_id/notesPlain' 2>/dev/null)"; \
	 [ -n "$$key_id" ] && [ -n "$$issuer" ] || { \
	   echo "ERROR: missing appstore_connect_key_id or appstore_connect_issuer_id in $(OP_VAULT)"; \
	   rm -f $(APPSTORE_KEY_FILE); exit 1; }; \
	 trap "rm -f $(APPSTORE_KEY_FILE)" EXIT; \
	 cd ios && APPSTORE_CONNECT_KEY_ID="$$key_id" \
	   APPSTORE_CONNECT_ISSUER_ID="$$issuer" \
	   APPSTORE_CONNECT_KEY_PATH="$(APPSTORE_KEY_FILE)" \
	   bundle exec fastlane upload_testflight
	@rm -f $(APPSTORE_KEY_FILE)
	@echo "TestFlight: https://appstoreconnect.apple.com/teams/$(shell op read 'op://$(OP_VAULT)/appstore_connect_issuer_id/notesPlain' 2>/dev/null)/apps"

upload-play-internal: $(ANDROID_AAB)
	@command -v op >/dev/null || { echo "ERROR: 1Password CLI required"; exit 1; }
	@command -v bundle >/dev/null || { echo "ERROR: bundler required"; exit 1; }
	@op read "op://$(OP_VAULT)/play_service_account.json/notesPlain" > $(PLAY_JSON_FILE) 2>/dev/null \
	  || { echo "ERROR: 1Password item play_service_account.json not found in $(OP_VAULT)"; exit 1; }
	@trap "rm -f $(PLAY_JSON_FILE)" EXIT; \
	 cd android && PLAY_JSON_KEY_PATH="$(PLAY_JSON_FILE)" \
	   bundle exec fastlane upload_play_internal
	@rm -f $(PLAY_JSON_FILE)
	@echo "Play Console: https://play.google.com/console/u/0/developers/-/app-list"

upload-stores: upload-testflight upload-play-internal
	@echo "Both store uploads complete."

# Uploads the archive that `flutter build ipa` made (release-ios-appstore)
# to App Store Connect/TestFlight as the Apple ID signed in to Xcode, the
# way Xcode's Organizer does: no API key, 1Password or fastlane needed.
# Xcode signs it for the App Store on the way. It refuses an archive whose
# build number is not the one in pubspec.yaml, so a stale one never goes.
.PHONY: upload-testflight-xcode
upload-testflight-xcode:
	@[ -d "$(IOS_ARCHIVE)" ] || { \
	  echo "ERROR: no $(IOS_ARCHIVE) — run make release-ios-appstore first"; \
	  exit 1; }
	@want="$$(awk '/^version:/ {print $$2}' pubspec.yaml)"; \
	  props=":ApplicationProperties"; \
	  ver="$$(/usr/libexec/PlistBuddy -c "Print $$props:CFBundleShortVersionString" \
	    "$(IOS_ARCHIVE)/Info.plist")"; \
	  build="$$(/usr/libexec/PlistBuddy -c "Print $$props:CFBundleVersion" \
	    "$(IOS_ARCHIVE)/Info.plist")"; \
	  [ "$$ver+$$build" = "$$want" ] || { \
	    echo "ERROR: the archive is $$ver+$$build, pubspec.yaml says $$want"; \
	    echo "Rebuild it: make release-ios-appstore"; exit 1; }; \
	  echo "Uploading iOS $$want to App Store Connect as the Xcode account..."
	rm -rf build/ios/upload
	xcodebuild -exportArchive \
	  -archivePath "$(IOS_ARCHIVE)" \
	  -exportPath build/ios/upload \
	  -exportOptionsPlist ios/ExportOptionsUpload.plist \
	  -allowProvisioningUpdates

# ----- Store deploys (bump + build + upload, one command per platform) ------
# Each deploy bumps the build number (+1: every store upload needs a higher
# one), builds a fresh store artifact and uploads it, so an older one left
# in $(DIST)/ is never sent by mistake. `make deploy` bumps once, so both
# stores ship the same +N. NO_BUMP=1 skips the bump: to retry an upload
# that failed after its bump, or to ship the other platform with the +N
# the first one got. Once the upload went through, the new version in
# pubspec.yaml is committed (not pushed); a failed upload leaves it
# uncommitted for the NO_BUMP=1 retry. Deploys refuse uncommitted changes,
# so what ships matches a commit; the version line in pubspec.yaml (an
# earlier bump) is the one change allowed. ALLOW_DIRTY=1 skips that check.
.PHONY: deploy-ios deploy-android deploy check-clean-tree deploy-bump \
  deploy-commit

deploy-ios: check-clean-tree
	$(MAKE) deploy-bump
	$(MAKE) release-ios-appstore
	$(MAKE) upload-testflight-xcode
	@echo
	@echo "iOS $$(awk '/^version:/ {print $$2}' pubspec.yaml) is uploaded to App Store Connect."
	@echo "It shows up in TestFlight once Apple processes it (usually 5-15 min)."
	@echo "To ship it: App Store Connect -> the new App Store version ->"
	@echo "pick this build -> Submit for Review."
	@$(MAKE) --no-print-directory deploy-commit

deploy-android: check-clean-tree
	$(MAKE) deploy-bump
	$(MAKE) release-android
	$(MAKE) upload-play-internal
	@echo
	@echo "Android $$(awk '/^version:/ {print $$2}' pubspec.yaml) is a draft on Play internal testing."
	@echo "To ship it: Play Console -> Testing -> Internal testing -> roll out"
	@echo "the draft, then Promote release -> Production."
	@$(MAKE) --no-print-directory deploy-commit

# Checked and bumped once, up front: both stores ship the same +N, and the
# iOS build may rewrite tracked files (e.g. Podfile.lock), which must not
# stop the Android half. Committed once, after both uploads.
deploy: check-clean-tree
	$(MAKE) deploy-bump
	$(MAKE) deploy-ios DEPLOY_PREPARED=1
	$(MAKE) deploy-android DEPLOY_PREPARED=1
	@$(MAKE) --no-print-directory deploy-commit

deploy-bump:
	@if [ "$(DEPLOY_PREPARED)" = 1 ]; then exit 0; fi; \
	if [ "$(NO_BUMP)" = 1 ]; then \
	  echo "NO_BUMP=1: shipping $$(awk '/^version:/ {print $$2}' pubspec.yaml) as is"; \
	else \
	  $(MAKE) --no-print-directory bump-build; \
	fi

# Commits only pubspec.yaml, and only a version change: a NO_BUMP=1 run of
# a committed version has nothing to commit, and other edits in the file
# (possible with ALLOW_DIRTY=1) must not go in under this message.
deploy-commit:
	@if [ "$(DEPLOY_PREPARED)" = 1 ]; then exit 0; fi; \
	if git diff --quiet HEAD -- pubspec.yaml; then \
	  echo "The version in pubspec.yaml is already committed."; exit 0; fi; \
	if git diff -U0 HEAD -- pubspec.yaml | sed -n '/^@@/,$$p' \
	  | grep '^[-+]' | grep -qv '^[-+]version:'; then \
	  echo "pubspec.yaml has more than the version change: commit it yourself."; \
	  exit 0; fi; \
	msg="[$$(git rev-parse --abbrev-ref HEAD)] - bumped build number to $$(awk '/^version:/ {print $$2}' pubspec.yaml)"; \
	git commit -q -m "$$msg" -- pubspec.yaml && echo "Committed (not pushed): $$msg"

check-clean-tree:
	@if [ "$(DEPLOY_PREPARED)" = 1 ]; then exit 0; fi; \
	if [ "$(ALLOW_DIRTY)" = 1 ]; then \
	  echo "WARNING: ALLOW_DIRTY=1, uncommitted changes will ship"; exit 0; fi; \
	dirty="$$(git status --porcelain | grep -v ' pubspec.yaml$$')"; \
	pubspec="$$(git diff -U0 HEAD -- pubspec.yaml | sed -n '/^@@/,$$p' \
	  | grep '^[-+]' | grep -v '^[-+]version:')"; \
	if [ -n "$$dirty" ] || [ -n "$$pubspec" ]; then \
	  echo "ERROR: uncommitted changes would ship in this build:"; \
	  [ -z "$$dirty" ] || echo "$$dirty"; \
	  [ -z "$$pubspec" ] || echo " M pubspec.yaml (beyond the version line)"; \
	  echo "Commit or stash them first, or rerun with ALLOW_DIRTY=1."; \
	  exit 1; \
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
	  sed -i.bak "s/^version: .*/version: $$ver+$$new/" pubspec.yaml && rm -f pubspec.yaml.bak; \
	  grep '^version:' pubspec.yaml

bump-patch:
	@cur="$(PUBSPEC_VERSION)"; \
	  ver=$${cur%+*}; build=$${cur#*+}; \
	  newver=$$(echo "$$ver" | awk -F. '{print $$1 "." $$2 "." $$3+1}'); \
	  newbuild=$$((build+1)); \
	  sed -i.bak "s/^version: .*/version: $$newver+$$newbuild/" pubspec.yaml && rm -f pubspec.yaml.bak; \
	  grep '^version:' pubspec.yaml

bump-minor:
	@cur="$(PUBSPEC_VERSION)"; \
	  ver=$${cur%+*}; build=$${cur#*+}; \
	  newver=$$(echo "$$ver" | awk -F. '{print $$1 "." $$2+1 ".0"}'); \
	  newbuild=$$((build+1)); \
	  sed -i.bak "s/^version: .*/version: $$newver+$$newbuild/" pubspec.yaml && rm -f pubspec.yaml.bak; \
	  grep '^version:' pubspec.yaml
