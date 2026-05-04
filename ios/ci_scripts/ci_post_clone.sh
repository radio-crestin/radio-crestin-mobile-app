#!/usr/bin/env bash
#
# Xcode Cloud post-clone script.
# Runs in $CI_WORKSPACE/ios/ci_scripts before xcodebuild.
# Prepares the Flutter side of the iOS build:
#   1. Installs Flutter at the version pinned in .fvmrc.
#   2. Runs `flutter pub get` so Generated.xcconfig is created.
#   3. Pre-caches the iOS engine to avoid mid-build downloads.
#   4. Runs `pod install` so Pods-Runner.*.xcconfig and the
#      *-input/output-files.xcfilelist files exist.

set -euxo pipefail

# Xcode Cloud sets $CI_WORKSPACE to the repo root and runs us from ios/ci_scripts.
REPO_ROOT="${CI_WORKSPACE:-$(cd "$(dirname "$0")/../.." && pwd)}"
cd "$REPO_ROOT"

FLUTTER_VERSION="$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(".fvmrc"))["flutter"])')"
FLUTTER_DIR="$HOME/flutter"

if [ ! -d "$FLUTTER_DIR" ]; then
  git clone --depth 1 --branch "$FLUTTER_VERSION" https://github.com/flutter/flutter.git "$FLUTTER_DIR"
fi
export PATH="$FLUTTER_DIR/bin:$PATH"

flutter --version
flutter config --no-analytics
flutter pub get
flutter precache --ios --no-android --no-linux --no-windows --no-macos --no-web

cd "$REPO_ROOT/ios"
pod install --repo-update
