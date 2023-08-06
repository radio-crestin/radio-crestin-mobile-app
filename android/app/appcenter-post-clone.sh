#!/usr/bin/env bash
# Place this script in project/android/app/appcenter-post-clone.sh
# Original file stored at
# https://github.com/microsoft/appcenter/blob/master/sample-build-scripts/flutter/android-build/appcenter-post-clone.sh

cd ..

# fail if any command fails
set -e
# debug log
set -x

cd ..
git clone -b stable https://github.com/flutter/flutter.git
export PATH=`pwd`/flutter/bin:$PATH

flutter channel stable
#flutter doctor --android-licenses

echo "Installed flutter to `pwd`/flutter"

echo "$GOOGLE_SERVICES_JSON" > android/app/google-services.json

# build APK
flutter build apk --release

# copy the APK where AppCenter will find it
mkdir -p android/app/build/outputs/apk/; mv build/app/outputs/flutter-apk/app-release.apk $_

# build bundle (AAB)
if [ "$BUILD_AAB" = "true" ] ; then
    flutter build appbundle --release

    # copy the AAB where AppCenter will find it
    mkdir -p android/app/build/outputs/bundle/; mv build/app/outputs/bundle/release/app-release.aab $_
fi